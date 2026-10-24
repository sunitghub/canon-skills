package term

import (
	"bytes"
	"time"

	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/formatters"
	"github.com/alecthomas/chroma/v2/lexers"
	"github.com/alecthomas/chroma/v2/styles"
)

// highlightLimit bounds how long a lexer may run; on a timeout the file is shown plain.
const highlightLimit = 2 * time.Second

// Highlight returns src with terminal colours chosen by the file name's language, or src unchanged when the language
// is unknown, the lexer fails, or it takes too long. src must already be passed through Visible: chroma adds only its
// own colour codes.
func Highlight(name, src string) string {
	lexer := lexers.Match(name)
	if lexer == nil {
		return src
	}
	lexer = chroma.Coalesce(lexer)
	done := make(chan string, 1)
	go func() {
		it, err := lexer.Tokenise(nil, src)
		if err != nil {
			done <- src
			return
		}
		var buf bytes.Buffer
		if err := formatters.TTY256.Format(&buf, styles.Get("monokai"), it); err != nil {
			done <- src
			return
		}
		done <- buf.String()
	}()
	select {
	case out := <-done:
		return out
	case <-time.After(highlightLimit):
		return src
	}
}
