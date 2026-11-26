package board

// Protects the board's two parsers of files a person writes (t-c2de, the fuzz slice from t-ca0e): parseTicket behind
// every ticket route, and the theme loader behind the theme picker. Neither may panic, and each refusal is a reason.

import (
	"os"
	"path/filepath"
	"testing"
)

// The documented example (docs/custom-themes.md) and a ticket in the shape tkt writes.
const fuzzTheme = `{"name": "Example Dark", "mode": "dark", "colors": {"bg": "#1f2430", "surface": "#272d3a", "border": "#3a4252", "text": "#eef1f6", "body": "#c4cad6", "muted": "#a3abba", "accent": "#5aa9e6", "ok": "#6cc070", "warn": "#e6b450", "bad": "#ef6b73", "info": "#79b8ff", "term": "#171b24"}}`

const fuzzTicket = "---\nid: t-abcd\nstatus: open\ncreated: 2026-11-24T00:00:00Z\ntype: feature\npriority: 1\neval_override: false\neval_fail_count: 0\ntags: [go]\n---\n# A title\n\n## Problem\ntext\n"

func FuzzParseTicket(f *testing.F) {
	for _, s := range []string{fuzzTicket, "---\npriority: p2\n---\n", "---\n", "", "---\nstatus: \"open\"\n---\nbody"} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		p := filepath.Join(t.TempDir(), "t-abcd.md")
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Fatal(err)
		}
		_, _ = parseTicket(p)
	})
}

func FuzzTheme(f *testing.F) {
	for _, s := range []string{fuzzTheme, "{}", "[[[[[[[[[[]]]]]]]]]]", `{"name": 1, "mode": "dark", "colors": {}}`, "1e999", "\xef\xbb\xbf{}"} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "x.json"), data, 0o600); err != nil {
			t.Fatal(err)
		}
		th, reason := themeRead(d, "x.json")
		if (reason == "") == (th.Name == "") {
			t.Fatalf("theme %+v with reason %q: want exactly one", th, reason)
		}
	})
}
