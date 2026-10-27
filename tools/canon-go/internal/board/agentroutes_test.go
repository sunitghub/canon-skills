package board

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// t-d42a: the two board routes that start an agent refuse a request without a loopback Origin header
// (originOK alone lets an empty Origin through), and the headless run also needs an explicit confirm.
func postAgentRoute(path, origin, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	handlePost(w, req)
	return w
}

func TestAgentRoutesRefuseMissingOrigin(t *testing.T) {
	for _, path := range []string{"/api/skill-eval/run", "/api/ticket/t-ab12/headless-run"} {
		if w := postAgentRoute(path, "", `{"base_ref":"main","confirm":true,"confirm_cost":true}`); w.Code != http.StatusForbidden {
			t.Errorf("%s with no Origin = %d, want 403", path, w.Code)
		}
		if w := postAgentRoute(path, "http://evil.example", `{"base_ref":"main","confirm":true}`); w.Code != http.StatusForbidden {
			t.Errorf("%s with a foreign Origin = %d, want 403", path, w.Code)
		}
	}
}

func TestHeadlessRunNeedsConfirm(t *testing.T) {
	w := postAgentRoute("/api/ticket/t-ab12/headless-run", "http://127.0.0.1:1234", `{"base_ref":"main"}`)
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "confirm required") {
		t.Fatalf("no confirm = %d %s, want 400 confirm required", w.Code, w.Body.String())
	}
	headlessRunsMu.Lock()
	_, started := headlessRuns["t-ab12"]
	headlessRunsMu.Unlock()
	if started {
		t.Fatal("a run was started without confirm")
	}
}
