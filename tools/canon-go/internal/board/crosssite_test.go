package board

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// t-dfa1: a page on another site can fire blind GETs at the board's polled routes (each runs git or builds the tickets
// reply). handle refuses them before any work; header-less clients and the board's own pages still get their answer.
// Prod path: every /api route the board and the Cockpit poll.
func TestCrossSiteAPIRefused(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	get := func(path string, hdr map[string]string) int {
		req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8423"+path, nil)
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		handle(w, req)
		return w.Code
	}
	refused := []string{"/api/tickets", "/api/git", "/api/project-stats?project=x", "/api/admin/model-tiers", "/api/projects", "/api/v1/sessions", "/api/pipeline"}
	for _, p := range refused {
		if c := get(p, map[string]string{"Sec-Fetch-Site": "cross-site"}); c != http.StatusForbidden {
			t.Errorf("%s cross-site = %d, want 403", p, c)
		}
		if c := get(p, map[string]string{"Origin": "http://evil.example"}); c != http.StatusForbidden {
			t.Errorf("%s foreign Origin = %d, want 403", p, c)
		}
	}
	for _, hdr := range []map[string]string{
		nil,
		{"Sec-Fetch-Site": "same-origin", "Origin": "http://127.0.0.1:8423"},
		{"Sec-Fetch-Site": "same-site", "Origin": "http://localhost:8899"},
		{"Sec-Fetch-Site": "none"},
	} {
		for _, p := range []string{"/api/projects", "/api/admin/model-tiers"} {
			if c := get(p, hdr); c != http.StatusOK {
				t.Errorf("%s with %v = %d, want 200", p, hdr, c)
			}
		}
	}
	if c := get("/static/nope.js", map[string]string{"Sec-Fetch-Site": "cross-site"}); c == http.StatusForbidden {
		t.Errorf("a static file is not an /api route: got 403")
	}
}
