package artifact

// Protects the validator behind `sprint validate` and pre-gate against crash inputs (t-c2de, the fuzz slice from t-ca0e).
// Seeds are the well-formed fixtures and their broken variants, so CI needs no .tickets/.

import (
	"strings"
	"testing"
)

func seeds(f *testing.F, add func(name, body string)) {
	f.Helper()
	for _, name := range Files {
		add(name, valid[name])
	}
	for _, r := range refusals {
		add(r.file, strings.Replace(valid[r.file], r.old, r.new, 1))
	}
}

func FuzzValidate(f *testing.F) {
	seeds(f, func(name, body string) {
		for i, n := range Files {
			if n == name {
				f.Add(uint8(i), []byte(body))
			}
		}
	})
	f.Fuzz(func(t *testing.T, kind uint8, data []byte) {
		name := Files[int(kind)%len(Files)]
		n := len(lines(data))
		for _, fd := range Check(name, data, "t-abcd") {
			if _, ok := ruleByID[fd.Rule]; !ok || fd.Line < 1 || fd.Line > n {
				t.Fatalf("%s: bad finding %+v (lines %d)", name, fd, n)
			}
		}
	})
}

func FuzzFrontmatter(f *testing.F) {
	seeds(f, func(name, body string) {
		if name == "ticket.md" {
			f.Add([]byte(body))
		}
	})
	f.Fuzz(func(t *testing.T, data []byte) {
		ls := lines(data)
		fs, end := Frontmatter(ls)
		if end > len(ls) || (end == 0 && fs != nil) {
			t.Fatalf("end %d of %d lines with %d fields", end, len(ls), len(fs))
		}
		for _, fd := range fs {
			if fd.Line < 2 || fd.Line >= end || fd.Key == "" {
				t.Fatalf("field %+v outside the block ending at %d", fd, end)
			}
		}
	})
}
