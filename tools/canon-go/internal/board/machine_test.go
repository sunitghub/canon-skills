package board

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"canon/internal/events"
	"canon/internal/machine"
)

// t-c542: the board writes machine.seen only when this host's facts change. Prod path: board start (Run), Tower's
// By machine table and the ticket's Machines node read it.
func TestNoteMachineSeenOncePerChange(t *testing.T) {
	home := t.TempDir()
	if !noteMachineSeen(home) {
		t.Fatal("first start on a machine wrote no machine.seen")
	}
	if noteMachineSeen(home) {
		t.Fatal("a restart on an unchanged machine wrote a second machine.seen")
	}
	ev, ok := events.Latest(home, "machine.seen", "", nil)
	if !ok || ev.Data["host"] != machine.Host() || ev.Data["cpus"] != machine.Get().CPUs || ev.Host != machine.Host() {
		t.Fatalf("machine.seen = %+v %v", ev, ok)
	}
	changed := factsData(machine.Get())
	changed["ram_gb"] = "1"
	if err := events.Emit(home, "machine.seen", "board", "", changed); err != nil {
		t.Fatal(err)
	}
	if !noteMachineSeen(home) {
		t.Fatal("facts that differ from the newest machine.seen wrote none")
	}
	other := factsData(machine.Get())
	other["host"] = "another-box"
	events.Emit(home, "machine.seen", "board", "", other)
	if noteMachineSeen(home) {
		t.Fatal("another host's newer machine.seen made this host write again")
	}
}

// t-c542: `canon-go machine` is what evidence.sh puts in each log header; it never prints the hostname (t-a83a).
func TestMachineCLI(t *testing.T) {
	var out, errb bytes.Buffer
	if code := machineCLI(nil, &out, &errb); code != 0 || strings.TrimSpace(out.String()) != machine.Get().Line() {
		t.Fatalf("machine = %d %q, want %q", code, out.String(), machine.Get().Line())
	}
	out.Reset()
	if code := machineCLI([]string{"--json"}, &out, &errb); code != 0 {
		t.Fatalf("machine --json = %d", code)
	}
	var m map[string]string
	if err := json.Unmarshal(out.Bytes(), &m); err != nil || m["os"] != machine.Get().OS || m["cpus"] != machine.Get().CPUs {
		t.Fatalf("machine --json = %q (%v)", out.String(), err)
	}
	if _, has := m["host"]; has || strings.Contains(out.String(), machine.Host()) {
		t.Fatalf("machine --json carries the hostname: %q", out.String())
	}
	if code := machineCLI([]string{"--bogus"}, &out, &errb); code != 2 {
		t.Fatalf("an unknown flag = %d, want 2", code)
	}
}

func machinesGet(t *testing.T, target string) (int, []ticketMachine) {
	t.Helper()
	rec := httptest.NewRecorder()
	handle(rec, httptest.NewRequest("GET", "http://127.0.0.1"+target, nil))
	var out struct{ Machines []ticketMachine }
	if rec.Code == http.StatusOK {
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("bad JSON: %v %s", err, rec.Body.String())
		}
	}
	return rec.Code, out.Machines
}

// t-c542: GET /api/ticket-machines is the ticket modal's Machines node. Rows come from this project's events for the ticket
// (each line's host, joined with that host's newest machine.seen; a worktree in <root>-worktrees/ counts, another project
// does not) and from the evidence headers: cloud always, local only when no event named a host. A new event shows up on
// the next read (the day index is keyed on size and mtime).
func TestTicketMachinesRoute(t *testing.T) {
	root := resolvedOrAbs(setupTestProject(t))
	home := events.Home()
	os.RemoveAll(filepath.Join(home, "events"))
	t.Cleanup(func() { os.RemoveAll(filepath.Join(home, "events")) })
	for _, bad := range []string{"../x", "t-..%2Fx", "t-a%2Fb", "T-ABCD", "", "x-abcd"} {
		if code, _ := machinesGet(t, "/api/ticket-machines?ticket="+bad); code != http.StatusBadRequest {
			t.Fatalf("id %q = %d, want 400", bad, code)
		}
	}
	if code, rows := machinesGet(t, "/api/ticket-machines?ticket=t-board-spec-1793"); code != http.StatusOK || rows == nil {
		t.Fatalf("a long ticket id = %d %v, want 200 and a list", code, rows)
	}
	ev := filepath.Join(ticketsDirForRoot(root), "t-aaaa", "evidence")
	writeFile(t, filepath.Join(ev, "test-sh.log"), "HEAD abc 2026-11-02T10:00:00Z\n$ scripts/test.sh\n# on macOS 26.1, Darwin 25.1.0, arm64, 10 cores, 32 GB; bash 3.2.57\nok\n")
	writeFile(t, filepath.Join(ev, "cloud", "test-sh.log"), "HEAD abc 2026-11-02T10:00:00Z\n$ scripts/test.sh\n# on Linux 6.18.44-fc-v185 x86_64; bash 5.2.21\nok\n")
	writeFile(t, filepath.Join(ev, "notes.txt"), "HEAD x\n$ y\n# on Fake OS; bash 1.0\n")

	// no events yet: the local and the cloud evidence machines
	code, rows := machinesGet(t, "/api/ticket-machines?ticket=t-aaaa")
	if code != http.StatusOK || len(rows) != 2 {
		t.Fatalf("evidence only = %d %+v, want the two .log machines", code, rows)
	}
	lines := rows[0].Line + "|" + rows[1].Line
	if !strings.Contains(lines, "macOS 26.1") || !strings.Contains(lines, "Linux 6.18.44-fc-v185 x86_64") {
		t.Fatalf("evidence rows = %+v", rows)
	}
	for _, r := range rows {
		if r.Host != "" || r.Source != "evidence" || (strings.HasPrefix(r.Line, "Linux") != (r.Where == "cloud")) {
			t.Fatalf("evidence row %+v: no host, source evidence, cloud only under evidence/cloud/", r)
		}
	}

	noteMachineSeen(home)
	wt := filepath.Join(filepath.Dir(root), filepath.Base(root)+"-worktrees", "feat-x")
	events.Emit(home, "sprint.started", "sprint", root, map[string]string{"ticket": "t-aaaa"})
	events.Emit(home, "gate.finished", "subagent-log", wt, map[string]string{"ticket": "t-aaaa", "role": "evaluator"})
	events.Emit(home, "gate.finished", "subagent-log", "/somewhere/else", map[string]string{"ticket": "t-aaaa", "role": "evaluator"})
	events.Emit(home, "sprint.started", "sprint", root, map[string]string{"ticket": "t-bbbb"})
	_, rows = machinesGet(t, "/api/ticket-machines?ticket=t-aaaa")
	if len(rows) != 2 || rows[0].Source != "events" || rows[0].Host != machine.Host() || rows[0].Count != 2 {
		t.Fatalf("with events = %+v, want this host (2 events: root and its worktree, not another project) then the cloud evidence", rows)
	}
	if rows[0].Facts["cpus"] != machine.Get().CPUs || rows[0].Facts["os"] != machine.Get().OS || rows[0].Line != machine.Get().Line() {
		t.Fatalf("the host row lacks its machine.seen facts: %+v", rows[0])
	}
	if rows[1].Where != "cloud" {
		t.Fatalf("second row = %+v, want the cloud evidence (local evidence is dropped once a host is known)", rows[1])
	}
	events.Emit(home, "ticket.closed", "tkt", root, map[string]string{"ticket": "t-aaaa"})
	if _, rows = machinesGet(t, "/api/ticket-machines?ticket=t-aaaa"); rows[0].Count != 3 {
		t.Fatalf("a new event did not reach the next read (stale day index): %+v", rows[0])
	}
	if _, rows = machinesGet(t, "/api/ticket-machines?ticket=t-cccc"); rows == nil || len(rows) != 0 {
		t.Fatalf("a ticket nothing ran for = %+v, want an empty list", rows)
	}
}
