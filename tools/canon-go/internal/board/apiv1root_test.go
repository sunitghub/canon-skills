package board

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// Protects `?root=` on GET /api/v1/events, /api/v1/events/stream and /api/v1/sprint/<id> (t-9f86): `canon events` and `canon sprint` run in
// any project send that project's folder, so they answer for it and not for the folder the board started in (an empty list on the
// Windows VM, 2026-11-20). root is client input: it must be absolute, in any of the forms a client sends, and never paired with project.

func TestAPIv1RootScopesEventsToThatProject(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj)+f.line(2, "/elsewhere/app")+f.line(3, "C:/Users/agentops/ToDo-Demo")+f.line(4, "/elsewhere/app-two"))
	ids := func(target string) string {
		t.Helper()
		w := v1Get(t, "GET", target, "")
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", target, w.Code, w.Body)
		}
		var out []string
		for _, e := range v1Body(t, w)["events"].([]any) {
			out = append(out, strings.TrimLeft(e.(map[string]any)["id"].(string), "0"))
		}
		return strings.Join(out, ",")
	}
	if got := ids("/api/v1/events"); got != "1" {
		t.Errorf("no root keeps the board's own project: %q", got)
	}
	if got := ids("/api/v1/events?root=" + url.QueryEscape("/elsewhere/app")); got != "2" {
		t.Errorf("root=/elsewhere/app: %q (a sibling folder that shares the prefix must not count)", got)
	}
	// the Windows forms of one folder all name it: the client's C:/…, Git Bash's /c/…, a backslash path, another case
	for _, form := range []string{"C:/Users/agentops/ToDo-Demo", "/c/Users/agentops/ToDo-Demo", `C:\Users\agentops\ToDo-Demo`, "c:/users/AGENTOPS/todo-demo"} {
		if got := ids("/api/v1/events?root=" + url.QueryEscape(form)); got != "3" {
			t.Errorf("root=%q: %q", form, got)
		}
	}
	if got := ids("/api/v1/events?root=" + url.QueryEscape("/no/events/here")); got != "" {
		t.Errorf("a folder with no events: %q", got)
	}
}

func TestAPIv1RootRefusesBadRoots(t *testing.T) {
	f := newEvFix(t)
	for _, q := range []string{"root=", "root=relative/dir", "root=.", "root=" + url.QueryEscape("/x\x01y"), "root=" + url.QueryEscape("/x\x7fy"),
		"root=" + url.QueryEscape("/x") + "&project=p1", "root=C:relative"} {
		for _, route := range []string{"/api/v1/events?", "/api/v1/sprint/t-aaaa?"} {
			w := v1Get(t, "GET", route+q, "")
			if w.Code != 400 || !strings.Contains(w.Body.String(), "bad root") || strings.Contains(w.Body.String(), `"events"`) {
				t.Errorf("%s%s: %d %s", route, q, w.Code, w.Body)
			}
		}
		// the stream over a real connection with a short deadline: a missing guard opens a 200 stream that would never end (reviewer)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		req, _ := http.NewRequestWithContext(ctx, "GET", f.srv.URL+"/api/v1/events/stream?"+q, nil)
		req.Host = "127.0.0.1:8423"
		resp, err := http.DefaultClient.Do(req)
		if err != nil || resp.StatusCode != 400 {
			code := 0
			if resp != nil {
				code = resp.StatusCode
			}
			t.Errorf("stream %s: status %d, %v", q, code, err)
		}
		if resp != nil {
			resp.Body.Close()
		}
		cancel()
	}
}

func TestAPIv1RootScopesTheSprintRouteAndTheStream(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", `{"schema":1,"id":"00000000000000a1","ts":"2026-11-10T09:00:00.000Z","kind":"sprint.started","source":"sprint","project":"/elsewhere/app","data":{"ticket":"t-aaaa"}}`+"\n")
	if b := v1Body(t, v1Get(t, "GET", "/api/v1/sprint/t-aaaa", "")); len(b["events"].([]any)) != 0 {
		t.Errorf("no root: another project's sprint was served: %v", b)
	}
	b := v1Body(t, v1Get(t, "GET", "/api/v1/sprint/t-aaaa?root="+url.QueryEscape("/elsewhere/app"), ""))
	if evs := b["events"].([]any); len(evs) != 1 || evs[0].(map[string]any)["kind"] != "sprint.started" {
		t.Errorf("root=/elsewhere/app: %v", b)
	}
	snap := v1Body(t, v1Get(t, "GET", "/api/v1/events?root="+url.QueryEscape("/elsewhere/app"), ""))
	s := f.get("/api/v1/events/stream?root="+url.QueryEscape("/elsewhere/app")+"&cursor="+url.QueryEscape(snap["cursor"].(string)), nil)
	if s.StatusCode != 200 {
		t.Fatalf("stream with root: %d", s.StatusCode)
	}
	f.append("2026-11-10", f.line(7, f.proj)+f.line(8, "/elsewhere/app"))
	if got := newSSE(s).next(t, 1); frameIDs(got) != "8" {
		t.Errorf("the stream with root= served %v, want only /elsewhere/app's event 8", got)
	}
}
