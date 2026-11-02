// skillshealth.go — t-6541: the Projects card's skill problems and its Refresh. The check is skills.sh's own (`status --json`,
// tools/skills/display.sh skill_problems); the board only runs it, never re-implements it, and caches the answer until AGENTS.md
// or either skills folder changes. Refresh runs `skills.sh refresh <root>` the way the Project tab's add runs `skills.sh add`.
package board

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// runSkillsSh runs skills.sh with fixed arguments in root: bash from PATH (Git Bash on Windows), stdin closed, the given extra
// environment, killed after timeout. unsupported is true when bash or skills.sh is missing, or the run was killed.
func runSkillsSh(root string, timeout time.Duration, env []string, args ...string) (out []byte, unsupported bool, err error) {
	bash, berr := exec.LookPath("bash")
	if berr != nil || !exists(skillsShPath()) {
		return nil, true, fmt.Errorf("bash or skills.sh is not available")
	}
	cmd := exec.Command(bash, append([]string{skillsShPath()}, args...)...)
	cmd.Dir = root
	cmd.Stdin = nil
	cmd.Env = append(os.Environ(), env...)
	timedOut := false
	timer := time.AfterFunc(timeout, func() {
		timedOut = true
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	})
	out, err = cmd.CombinedOutput()
	timer.Stop()
	if err != nil {
		if _, isExit := err.(*exec.ExitError); !isExit || timedOut {
			return out, true, err
		}
	}
	return out, false, err
}

type skillsHealthEntry struct {
	key string
	res map[string]any
}

var (
	skillsHealthMu    sync.Mutex
	skillsHealthCache = map[string]skillsHealthEntry{}
)

// skillsHealthKey changes when AGENTS.md, either skills folder (or the link it is) or the install's skills folder changes.
func skillsHealthKey(root string) string {
	var b strings.Builder
	for _, p := range []string{filepath.Join(root, "AGENTS.md"), filepath.Join(root, ".claude", "skills"), filepath.Join(root, ".agents", "skills"),
		filepath.Join(toolsDir, "..", "skills")} {
		for _, stat := range []func(string) (os.FileInfo, error){os.Lstat, os.Stat} { // review: the link itself and, through it, its target
			if fi, err := stat(p); err == nil {
				fmt.Fprintf(&b, "%s:%d:%d|", p, fi.Size(), fi.ModTime().UnixNano())
			} else {
				fmt.Fprintf(&b, "%s:-|", p)
			}
		}
	}
	return b.String()
}

// skillsHealth is {"ok":true,"skills":[{"name","problems":[...]}],"issues":N}, or {"ok":false,"error"} when the check could not
// run or answered something else: a failed check is never "healthy".
func skillsHealth(root string) map[string]any {
	key := skillsHealthKey(root)
	skillsHealthMu.Lock()
	if e, ok := skillsHealthCache[root]; ok && e.key == key {
		skillsHealthMu.Unlock()
		return e.res
	}
	skillsHealthMu.Unlock()
	out, unsupported, err := runSkillsSh(root, 30*time.Second, []string{"SKILLS_SH_NO_TTY=1"}, "status", "--json", root)
	if unsupported || err != nil {
		return map[string]any{"ok": false, "error": "could not check this project's skills: " + strings.TrimSpace(lastLines(string(out), 3))}
	}
	var parsed struct {
		Skills []struct {
			Name     string   `json:"name"`
			Problems []string `json:"problems"`
		} `json:"skills"`
		Issues int `json:"issues"`
	}
	line := strings.TrimSpace(lastLines(string(out), 1))
	if json.Unmarshal([]byte(line), &parsed) != nil || parsed.Skills == nil {
		return map[string]any{"ok": false, "error": "skills.sh status --json gave no answer the board can read"}
	}
	res := map[string]any{"ok": true, "skills": parsed.Skills, "issues": parsed.Issues}
	skillsHealthMu.Lock()
	skillsHealthCache[root] = skillsHealthEntry{key, res}
	skillsHealthMu.Unlock()
	return res
}

// skillsRefresh runs `skills.sh refresh <root>` (fixed argument list, a registry-resolved root, the board's non-interactive
// defaults) and returns its output's last lines; the health cache for root is dropped either way.
func skillsRefresh(root string) map[string]any {
	out, unsupported, err := runSkillsSh(root, 120*time.Second, []string{"SKILLS_SH_ASSUME_YES=1", "SKILLS_SH_NO_TTY=1"}, "refresh", root)
	skillsHealthMu.Lock()
	delete(skillsHealthCache, root)
	skillsHealthMu.Unlock()
	tail := strings.TrimSpace(lastLines(string(out), 12))
	switch {
	case unsupported:
		return map[string]any{"ok": false, "unsupported": true, "error": "skills.sh could not run here", "cmd": fmt.Sprintf("%s refresh %s", skillsShPath(), root), "output": tail}
	case err != nil:
		return map[string]any{"ok": false, "error": "skills.sh refresh failed", "output": tail}
	}
	return map[string]any{"ok": true, "output": tail}
}

// lastLines is the last n lines of s.
func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
