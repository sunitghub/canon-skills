package term

import "testing"

// Protects the Console's su and launch hand-off on Windows: the Git bash they start is the one tools/tkt.cmd would pick.
func TestFindGitBash(t *testing.T) {
	env := map[string]string{"ProgramFiles": `C:\Program Files`, "ProgramFiles(x86)": `C:\Program Files (x86)`, "LocalAppData": `C:\Users\u\AppData\Local`}
	get := func(k string) string { return env[k] }
	has := func(paths ...string) func(string) bool {
		return func(p string) bool {
			for _, x := range paths {
				if p == x {
					return true
				}
			}
			return false
		}
	}
	none := func() []string { return nil }
	for _, c := range []struct {
		name  string
		exist func(string) bool
		where func() []string
		want  string
	}{
		{"Program Files bin first", has(`C:\Program Files\Git\bin\bash.exe`, `C:\Program Files\Git\usr\bin\bash.exe`, `C:\Users\u\AppData\Local\Programs\Git\bin\bash.exe`), none, `C:\Program Files\Git\bin\bash.exe`},
		{"usr\\bin when bin is missing", has(`C:\Program Files\Git\usr\bin\bash.exe`), none, `C:\Program Files\Git\usr\bin\bash.exe`},
		{"x86 before the per-user install", has(`C:\Program Files (x86)\Git\bin\bash.exe`, `C:\Users\u\AppData\Local\Programs\Git\bin\bash.exe`), none, `C:\Program Files (x86)\Git\bin\bash.exe`},
		{"per-user install", has(`C:\Users\u\AppData\Local\Programs\Git\bin\bash.exe`), none, `C:\Users\u\AppData\Local\Programs\Git\bin\bash.exe`},
		{"where finds a Git folder elsewhere", has(), func() []string { return []string{`C:\Windows\System32\bash.exe`, `D:\Tools\Git\usr\bin\bash.exe`} }, `D:\Tools\Git\usr\bin\bash.exe`},
		{"WSL's System32 bash is refused", has(), func() []string { return []string{`C:\Windows\System32\bash.exe`} }, ""},
		{"a Git folder that is not bash.exe is refused", has(), func() []string { return []string{`D:\Git\bin\git.exe`} }, ""},
		{"nothing found", has(), none, ""},
	} {
		if got := findGitBash(get, c.exist, c.where); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
	if got := findGitBash(func(string) string { return "" }, has(), none); got != "" {
		t.Errorf("no environment at all: got %q", got)
	}
}
