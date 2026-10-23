package board

import (
	"net/http/httptest"
	"testing"
)

// t-9a49: every board response refuses framing by another site.
func TestBoardRefusesForeignFraming(t *testing.T) {
	for _, path := range []string{"/", "/api/no-such-route"} {
		rec := httptest.NewRecorder()
		handle(rec, httptest.NewRequest("GET", "http://127.0.0.1:8423"+path, nil))
		if got := rec.Header().Get("X-Frame-Options"); got != "SAMEORIGIN" {
			t.Fatalf("%s X-Frame-Options = %q", path, got)
		}
		csp := rec.Header().Values("Content-Security-Policy")
		if len(csp) == 0 || csp[0] != "frame-ancestors 'self'" {
			t.Fatalf("%s CSP = %q, want frame-ancestors 'self' first", path, csp)
		}
	}
}
