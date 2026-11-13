package daemon

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// t-dfa1: the daemon's reads (/sessions walks transcripts, /changes runs git) refuse a page on another site, which sends
// no Origin on a no-cors GET. Prod path: the Cockpit's /sessions and /changes polls.
func TestCrossSiteRefused(t *testing.T) {
	s := newServer(config{token: "boot", projectRoot: t.TempDir(), stateDir: t.TempDir()})
	h := s.handler()
	get := func(path, site string) int {
		req := httptest.NewRequest("GET", "http://127.0.0.1:8455"+path, nil)
		if site != "" {
			req.Header.Set("Sec-Fetch-Site", site)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	// The sandboxed preview iframe's own subresources are cross-site to the browser; the path's token is their gate.
	req := httptest.NewRequest("GET", "http://127.0.0.1:8455/session/abcd/preview/tok/app.js", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if strings.Contains(rec.Body.String(), "cross-site") {
		t.Errorf("a preview subresource was refused by the cross-site check: %d %s", rec.Code, rec.Body.String())
	}
	for _, p := range []string{"/sessions", "/changes"} {
		if c := get(p, "cross-site"); c != http.StatusForbidden {
			t.Errorf("%s cross-site = %d, want 403", p, c)
		}
		for _, site := range []string{"", "same-origin", "same-site", "none"} {
			if c := get(p, site); c == http.StatusForbidden {
				t.Errorf("%s Sec-Fetch-Site=%q = 403, want it served", p, site)
			}
		}
	}
}
