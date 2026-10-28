package board

// Admin > Logging routes (t-1bd5): the activity log's state, Keep for and compress settings, Verify, Export, Show in folder and Delete.
// None of them takes a path from the page. Every write needs a loopback Origin (an empty one is refused: a stray local `curl` has none),
// and Delete and a Keep for that would remove days need an explicit confirm. Pruning stays on maintenance's schedule: nothing here
// removes a day because of a retention change.

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"canon/internal/events"
	"canon/internal/settings"
)

const loggingPrefix = "/api/admin/logging"

// retentionOptions are the Keep for choices, in the order the page lists them.
var retentionOptions = []int{30, 90, 365}

// revealFolder opens dir in the system's file manager. A variable so a test can see the call without launching one.
var revealFolder = func(dir string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("explorer.exe", dir) // explorer exits 1 even when it opened the folder: starting it is the success
	case "darwin":
		cmd = exec.Command("open", dir)
	default:
		cmd = exec.Command("xdg-open", dir)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
}

// displayDir is the events folder as the page shows it: the home folder abbreviated to ~, with the OS's own separator.
func displayDir(home string) string {
	dir := filepath.Join(home, "events")
	if uh, err := os.UserHomeDir(); err == nil && uh != "" {
		if rel, err := filepath.Rel(uh, dir); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
			return "~" + string(filepath.Separator) + rel
		}
	}
	return dir
}

func loggingState() (map[string]any, int) {
	home := events.Home()
	keep := settings.RetentionDays(home)
	st := map[string]any{
		"ok": true, "retention_days": keep, "retention_options": retentionOptions, "retention_default": settings.RetentionDefault,
		"compress": settings.CompressOn(home), "dir": displayDir(home),
	}
	if _, err := settings.InstallSet(home).Load(); err != nil {
		st["settings_error"] = err.Error() // a malformed settings file: the page says so, and 30 days applies meanwhile
	}
	info, err := events.Stat(home)
	if err != nil {
		st["ok"] = false
		st["error"] = "the activity log folder cannot be read"
		return st, http.StatusInternalServerError
	}
	st["days"], st["files"], st["bytes"], st["oldest"], st["newest"] = info.Days, info.Files, info.Bytes, info.Oldest, info.Newest
	return st, http.StatusOK
}

func validRetention(n int) bool {
	for _, o := range retentionOptions {
		if o == n {
			return true
		}
	}
	return false
}

// handleLoggingGet answers the read routes. It returns false for a path that is not one of them.
func handleLoggingGet(w http.ResponseWriter, r *http.Request, path string) bool {
	switch path {
	case loggingPrefix:
		st, code := loggingState()
		sendJSONStatus(w, st, code)
	case loggingPrefix + "/verify":
		results, ok := events.Verify(events.Home(), time.Now().UTC())
		counts := map[string]int{"intact": 0, "broken": 0, "missing": 0, "unsealed": 0}
		for _, d := range results {
			counts[d.Result]++
		}
		summary := verifySummary(ok, results, counts) // before the cut below, so a broken day past the cap still shows
		if len(results) > 2000 {
			results = results[:2000]
		}
		rows := make([]map[string]string, 0, len(results))
		for _, d := range results {
			rows = append(rows, map[string]string{"day": d.Day, "result": d.Result, "why": d.Why})
		}
		sendJSON(w, map[string]any{"ok": true, "intact": ok, "counts": counts, "results": rows, "summary": summary})
	case loggingPrefix + "/export":
		exportLog(w)
	default:
		return false
	}
	return true
}

// verifySummary is the badge text: what a seal does and does not show, never "authenticated".
func verifySummary(ok bool, results []events.DayResult, counts map[string]int) string {
	if !ok {
		for _, d := range results {
			if d.Result == "broken" || d.Result == "missing" {
				return "Broken: " + d.Day + " " + d.Result
			}
		}
	}
	if counts["intact"] == 0 && counts["unsealed"] == 0 {
		return "No activity log yet"
	}
	if counts["intact"] == 0 {
		return fmt.Sprintf("%d day%s not sealed yet", counts["unsealed"], plural(counts["unsealed"]))
	}
	s := fmt.Sprintf("%d day%s sealed, all intact", counts["intact"], plural(counts["intact"]))
	if counts["unsealed"] > 0 {
		s += fmt.Sprintf("; %d not sealed yet", counts["unsealed"])
	}
	return s
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func exportLog(w http.ResponseWriter) {
	home := events.Home()
	if err := events.ExportCheck(home); err != nil { // sizes are checked before the download starts, so a refusal is a clean error
		code := http.StatusInternalServerError
		if errors.Is(err, events.ErrExportTooBig) {
			code = http.StatusRequestEntityTooLarge
		}
		sendJSONStatus(w, map[string]any{"ok": false, "error": err.Error()}, code)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Content-Disposition", `attachment; filename="canon-activity-log.jsonl"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	events.ExportStream(w, home) // a failure now ends the stream early; the check already read every file
}

// handleLoggingPost answers the write routes.
func handleLoggingPost(w http.ResponseWriter, r *http.Request, path string, payload map[string]any) bool {
	if path != loggingPrefix && path != loggingPrefix+"/delete" && path != loggingPrefix+"/reveal" {
		return false
	}
	if !agentOriginOK(r) {
		http.Error(w, "logging changes need a loopback Origin", http.StatusForbidden)
		return true
	}
	switch path {
	case loggingPrefix:
		saveLogging(w, r, payload)
	case loggingPrefix + "/delete":
		deleteLog(w, payload)
	case loggingPrefix + "/reveal":
		home := events.Home()
		dir := filepath.Join(home, "events")
		if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
			sendJSONStatus(w, map[string]any{"ok": false, "error": "there is no activity log folder yet"}, http.StatusNotFound)
			return true
		}
		if err := revealFolder(dir); err != nil {
			sendJSONStatus(w, map[string]any{"ok": false, "error": "could not open the folder"}, http.StatusInternalServerError)
			return true
		}
		sendJSON(w, map[string]any{"ok": true})
	}
	return true
}

func saveLogging(w http.ResponseWriter, r *http.Request, payload map[string]any) {
	bad := func(msg string) { sendJSONStatus(w, map[string]any{"ok": false, "error": msg}, http.StatusBadRequest) }
	for k := range payload {
		if k != "retention_days" && k != "compress" && k != "confirm_remove" {
			bad("unknown field " + k)
			return
		}
	}
	home := events.Home()
	if home == "" {
		bad("no CANON_HOME and no home folder")
		return
	}
	_, hasKeep := payload["retention_days"]
	cv, hasCompress := payload["compress"]
	if !hasKeep && !hasCompress {
		bad("nothing to change")
		return
	}
	set := settings.InstallSet(home)
	before, err := set.Load()
	if err != nil {
		sendJSONStatus(w, map[string]any{"ok": false, "error": err.Error()}, http.StatusBadRequest)
		return
	}
	var newKeep int
	if hasKeep {
		f, isNum := payload["retention_days"].(float64)
		if !isNum || f != float64(int(f)) || !validRetention(int(f)) {
			bad("retention_days must be 30, 90 or 365")
			return
		}
		newKeep = int(f)
		cur := settings.RetentionDays(home)
		if confirm, _ := payload["confirm_remove"].(bool); newKeep < cur && !confirm {
			if d, f := events.WouldRemove(home, newKeep, time.Now().UTC()); f > 0 {
				sendJSONStatus(w, map[string]any{
					"ok": false, "needs_confirm": true, "would_remove_days": d, "would_remove_files": f,
					"error": fmt.Sprintf("keeping %d days would remove %d day%s at the next maintenance: send confirm_remove to accept", newKeep, d, plural(d)),
				}, http.StatusConflict)
				return
			}
		}
	}
	if hasCompress {
		if _, isBool := cv.(bool); !isBool {
			bad("compress must be true or false")
			return
		}
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		sendJSONStatus(w, map[string]any{"ok": false, "error": "cannot create the canon folder"}, http.StatusInternalServerError)
		return
	}
	if hasKeep {
		if _, err := set.SetLocal(settings.RetentionKey, newKeep); err != nil {
			sendJSONStatus(w, map[string]any{"ok": false, "error": err.Error()}, http.StatusBadRequest)
			return
		}
		emitSetting(r, settings.RetentionKey, fmt.Sprint(before.Values[settings.RetentionKey].V), fmt.Sprint(newKeep))
	}
	if hasCompress {
		if _, err := set.SetLocal(settings.CompressKey, cv); err != nil {
			sendJSONStatus(w, map[string]any{"ok": false, "error": err.Error()}, http.StatusBadRequest)
			return
		}
		emitSetting(r, settings.CompressKey, fmt.Sprint(before.Values[settings.CompressKey].V), fmt.Sprint(cv))
	}
	st, code := loggingState()
	sendJSONStatus(w, st, code)
}

func deleteLog(w http.ResponseWriter, payload map[string]any) {
	if c, _ := payload["confirm"].(string); c != "delete" {
		sendJSONStatus(w, map[string]any{"ok": false, "error": `send {"confirm":"delete"}`}, http.StatusBadRequest)
		return
	}
	home := events.Home()
	c, err := events.Clear(home)
	if errors.Is(err, events.ErrBusy) {
		sendJSONStatus(w, map[string]any{"ok": false, "error": "canon is sealing or pruning the log right now: try again in a moment"}, http.StatusConflict)
		return
	}
	if c.Files > 0 { // the fresh log starts with the record that it was deleted, and by whom
		events.EmitActor(home, "log.deleted", "board", "user", "", map[string]string{"from": c.From, "to": c.To, "files": fmt.Sprint(c.Files)})
	}
	if err != nil {
		sendJSONStatus(w, map[string]any{"ok": false, "removed": c.Files, "failed": c.Failed, "error": err.Error()}, http.StatusInternalServerError)
		return
	}
	sendJSON(w, map[string]any{"ok": true, "removed": c.Files})
}
