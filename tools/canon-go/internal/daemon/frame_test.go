package daemon

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// t-9a49: /cockpit and /relay are framed only by loopback pages, refuse a cross-site load, never start a session on
// load, and the cockpit posts only to a loopback parent origin taken from the Referer.
func TestCockpitFramePolicy(t *testing.T) {
	s := newServer(config{token: "boot", projectRoot: t.TempDir(), stateDir: t.TempDir()})
	h := s.handler()
	get := func(path, site, referer string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "http://127.0.0.1:8455"+path, nil)
		if site != "" {
			req.Header.Set("Sec-Fetch-Site", site)
		}
		if referer != "" {
			req.Header.Set("Referer", referer)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	for _, p := range []string{"/cockpit?ticket=t-abcd&embed=1", "/relay"} {
		if rec := get(p, "cross-site", ""); rec.Code != http.StatusForbidden || strings.Contains(rec.Body.String(), "boot") {
			t.Fatalf("%s cross-site: %d, want 403 without the page", p, rec.Code)
		}
		for _, site := range []string{"same-site", "same-origin", "none", ""} {
			rec := get(p, site, "")
			if rec.Code != 200 {
				t.Fatalf("%s Sec-Fetch-Site=%q: %d, want 200", p, site, rec.Code)
			}
			if got := rec.Header().Get("Content-Security-Policy"); got != "frame-ancestors http://127.0.0.1:* http://localhost:*" {
				t.Fatalf("%s CSP = %q", p, got)
			}
		}
	}

	page := get("/cockpit?ticket=t-abcd&embed=1&autostart=1", "same-site", "http://127.0.0.1:8423/").Body.String()
	if strings.Contains(page, "__COCKPIT_") || strings.Contains(page, "AUTOSTART") || strings.Contains(page, "autostart=1") {
		t.Fatal("the cockpit page still carries an autostart path or an unfilled placeholder")
	}
	if !strings.Contains(page, `var PARENT = "http://127.0.0.1:8423";`) {
		t.Fatal("a loopback Referer's origin must be the post target")
	}
	if strings.Contains(page, `"*")`) {
		t.Fatal(`the cockpit page still posts to "*"`)
	}
	for _, ref := range []string{"", "https://evil.example/x", "http://127.0.0.1.evil.example/", "http://localhost:8423.evil/", "file:///tmp/x.html", "not a url"} {
		p := get("/cockpit?ticket=t-abcd", "same-site", ref).Body.String()
		if !strings.Contains(p, `var PARENT = "";`) {
			t.Fatalf("Referer %q must give no post target", ref)
		}
	}
	if p := get("/cockpit", "same-site", "http://localhost/board?x=1").Body.String(); !strings.Contains(p, `var PARENT = "http://localhost";`) {
		t.Fatal("http://localhost without a port is a loopback parent")
	}
}

// t-1917: in the board's pane (embed=1) the Agents list owns the session's state and End session ends it, so the page header keeps only
// the picker, Start, the folder, the meter and the font size: Kill and the state are hidden, and the meter and folder are set by the
// board's pane-info message as text, never as markup. Standalone, Kill and the state stay.
func TestCockpitPaneHeader(t *testing.T) {
	s := newServer(config{token: "boot", projectRoot: t.TempDir(), stateDir: t.TempDir()})
	req := httptest.NewRequest("GET", "http://127.0.0.1:8455/cockpit?ticket=t-abcd&embed=1", nil)
	req.Header.Set("Sec-Fetch-Site", "same-site")
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, req)
	page := rec.Body.String()
	for _, want := range []string{
		"body.embed .btn-kill, body.embed .status{display:none}", // hidden in the board's pane only
		"body.embed .model{display:none}",                        // the page's placeholder model text never shows in the pane
		`textContent = "\u25B6 Run agent"`,                       // a scratch session says Run agent, not Run sprint
		`▶ Run sprint</button>`,                                  // a ticket session keeps Run sprint
		`id="killBtn"`, `id="statusText"`,                        // still there for the standalone page
		`id="paneMeter"`, `id="paneCwd"`, `d.type === "pane-info"`,
		"pt.textContent = typeof d.cwd", `id="paneCwdText"`, "direction:rtl", "color:var(--text)",
		// t-45b1: two rows: labelled fields from the board's separate values (text nodes only), the folder alone on the second row
		`add("Cache",`, `add("LLM calls",`, `add("Tool calls",`, `add("Subagents",`,
		"header{display:flex;flex-wrap:wrap", ".paneinfo.cwd{flex:1 1 100%;order:99",
	} {
		if !strings.Contains(page, want) {
			t.Fatalf("the cockpit page lacks %q", want)
		}
	}
	// t-4358: the agent picker reads Claude Code, Copilot CLI, Pi; Claude Code is first, so it stays the default. Prod path: Run sprint's picker.
	sel := page[strings.Index(page, `<select id="agentSel"`):]
	sel = sel[:strings.Index(sel, "</select>")]
	c, cp, pi := strings.Index(sel, `<option value="claude">Claude Code</option>`), strings.Index(sel, `<option value="copilot">Copilot CLI</option>`), strings.Index(sel, `<option value="pi">Pi</option>`)
	if c < 0 || cp < 0 || pi < 0 || !(c < cp && cp < pi) || strings.Contains(sel, "selected") {
		t.Fatalf("agent picker order: claude %d, copilot %d, pi %d (want Claude Code, Copilot CLI, Pi, Claude Code first): %s", c, cp, pi, sel)
	}
	if strings.Contains(page, `add("Model"`) || strings.Contains(page, "modelName(") { // t-3df9: the harness shows its model, the card the stage
		t.Fatal("the pane header still shows a Model field")
	}
	i := strings.Index(page, `d.type === "pane-info"`)
	if strings.Contains(page[i:i+1800], "innerHTML") { // t-45b1: the handler grew; still text only
		t.Fatal("pane-info must set text, never markup")
	}
}
