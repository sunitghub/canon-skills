package board

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Protects the X-Cockpit-Daemon header of /api/v1/sessions (t-27bc): an empty list is "no sessions" only when the daemon really answered. A
// daemon that is down, unhealthy, erroring or sending a body that is not a list gives the same empty list, and the page that reads
// it as "this session is gone" would drop the tab of a session that is still running. cockpitSessionsAnswer is what the route sends.
func TestCockpitSessionsAnswerSaysWhetherTheDaemonAnswered(t *testing.T) {
	serve := func(sessions http.HandlerFunc) string {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
		mux.HandleFunc("/sessions", sessions)
		srv := httptest.NewServer(mux)
		t.Cleanup(srv.Close)
		return strings.TrimPrefix(srv.URL, "http://")
	}
	point := func(addr string) {
		dir := filepath.Join(t.TempDir(), "ck") // the board reads a daemon.json only from a private (0700) folder
		os.Mkdir(dir, 0o700)
		os.WriteFile(filepath.Join(dir, "daemon.json"), []byte(`{"addr":"`+addr+`","pid":"1"}`), 0o600)
		t.Setenv("COCKPIT_STATE_DIR", dir)
	}
	cases := []struct {
		name string
		addr string
		want bool
		rows int
	}{
		{"a list with a session", serve(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(`[{"session":"s1","ticket":"t-aaaa"}]`)) }), true, 1},
		{"a genuinely empty list", serve(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(`[]`)) }), true, 0},
		{"an error status with a list body", serve(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500); w.Write([]byte(`[{"session":"s1","ticket":"t-aaaa"}]`)) }), false, 0},
		{"a body that is not a list", serve(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(`{"error":"x"}`)) }), false, 0},
		{"null", serve(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(`null`)) }), false, 0},
		{"no daemon at all", "127.0.0.1:1", false, 0},
	}
	for _, c := range cases {
		point(c.addr)
		rows, up := cockpitSessionsAnswer()
		if up != c.want || len(rows) != c.rows || rows == nil {
			t.Errorf("%s: rows=%d up=%v (nil %v), want rows=%d up=%v and a non-nil slice", c.name, len(rows), up, rows == nil, c.rows, c.want)
		}
	}
}
