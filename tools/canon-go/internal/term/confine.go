package term

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// maxFile is the largest file cat shows.
const maxFile = 1 << 20

// confine resolves arg against root and returns the real path, or an error when it leaves the project or names something
// the prompt never shows. Symlinks are resolved first, so a link pointing out of the project is refused by where it
// lands, not by what it is called.
func confine(root, arg string) (string, error) {
	if strings.ContainsRune(arg, 0) {
		return "", errors.New("not allowed")
	}
	rootReal, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", errors.New("the project folder is not readable")
	}
	p := arg
	if !filepath.IsAbs(p) {
		p = filepath.Join(rootReal, p)
	}
	real, err := filepath.EvalSymlinks(filepath.Clean(p))
	if err != nil {
		return "", errors.New(cleanErr(err))
	}
	rel, err := filepath.Rel(rootReal, real)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", errors.New("outside this project")
	}
	if rel != "." {
		for _, part := range strings.Split(rel, string(filepath.Separator)) {
			if part == ".git" {
				return "", errors.New("the .git folder is never shown")
			}
			if strings.HasPrefix(part, ".env") {
				return "", errors.New(".env files are never shown")
			}
		}
	}
	return real, nil
}

// readFile returns the text of a regular, text file inside the project and its base name.
func readFile(root, arg string) (string, string, error) {
	real, err := confine(root, arg)
	if err != nil {
		return "", "", err
	}
	f, err := os.Open(real)
	if err != nil {
		return "", "", errors.New(cleanErr(err))
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "", "", errors.New(cleanErr(err))
	}
	if !fi.Mode().IsRegular() {
		return "", "", errors.New("not a regular file")
	}
	if fi.Size() > maxFile {
		return "", "", fmt.Errorf("file is over %d MB", maxFile>>20)
	}
	b, err := io.ReadAll(io.LimitReader(f, maxFile+1))
	if err != nil {
		return "", "", errors.New(cleanErr(err))
	}
	if len(b) > maxFile {
		return "", "", fmt.Errorf("file is over %d MB", maxFile>>20)
	}
	head := b
	if len(head) > 8000 {
		head = head[:8000]
	}
	for _, c := range head {
		if c == 0 {
			return "", "", errors.New("binary file")
		}
	}
	return string(b), filepath.Base(real), nil
}

// Visible makes text safe to send to a terminal: newline and tab stay; every other control character (ESC, CR, the C1
// range, DEL) is replaced by a visible symbol, so file content cannot move the cursor, set the title or draw a fake prompt.
func Visible(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '\n' || r == '\t':
			b.WriteRune(r)
		case r < 0x20:
			b.WriteRune(0x2400 + r) // the Control Pictures block: ESC becomes U+241B
		case r == 0x7f:
			b.WriteRune(0x2421)
		case r >= 0x80 && r <= 0x9f:
			b.WriteRune('�')
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
