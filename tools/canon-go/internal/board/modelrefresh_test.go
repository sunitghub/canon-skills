package board

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
)

// Protects Admin > Model Tiers > Refresh (t-d40b): what a docs page or a Models API yields, how it becomes a proposal against the registry,
// and that Apply adds before it retires.

const docsPage = `<html><style>.x{}</style><table>
<tr><td>Claude Haiku 5.6</td><td><code>claude-haiku-5-6</code></td><td>From $0.10 / input MTok</td><td>$0.50 / output MTok</td></tr>
<tr><td>Claude Sonnet 5.5</td><td>claude-sonnet-5-5</td><td>$2 input</td><td>$10 output</td></tr>
<tr><td>old</td><td>claude-haiku-4-5-20251001</td><td>$1</td><td>$5</td></tr>
<tr><td>alias</td><td>claude-haiku-latest</td></tr></table></html>`

func TestParseDocsPage(t *testing.T) {
	got := map[string]found{}
	for _, f := range parseDocsPage("anthropic", docsPage) {
		got[f.ID] = f
	}
	h := got["claude-haiku-5-6"]
	if h.Name != "Claude Haiku 5.6" || !h.PriceKnow || !h.From || h.In != 0.10 || h.Out != 0.50 {
		t.Errorf("haiku 5.6: %+v", h)
	}
	s := got["claude-sonnet-5-5"]
	if s.In != 2 || s.Out != 10 || s.From || !s.PriceKnow {
		t.Errorf("sonnet 5.5: %+v", s)
	}
	if _, ok := got["claude-haiku-latest"]; ok {
		t.Error("a -latest alias is not a model id")
	}
	if _, ok := got["claude-haiku-4-5-20251001"]; !ok {
		t.Error("a dated id should be read")
	}
	oa := parseDocsPage("openai", `<p>gpt-6.2-sol $2 and $10</p><p>gpt-6-luna $0.1 $0.5</p>`)
	if len(oa) != 2 || oa[0].ID != "gpt-6.2-sol" || oa[0].Name != "GPT-6.2 Sol" || oa[1].In != 0.1 {
		t.Errorf("openai page: %+v", oa)
	}
}

func TestParseModelsAPI(t *testing.T) {
	got, err := parseModelsAPI("anthropic", []byte(`{"data":[{"id":"claude-haiku-5-6","display_name":"Claude Haiku 5.6"},{"id":"claude-sonnet-5-5"},{"id":"not-a-claude"},{"id":"claude-x"}]}`))
	if err != nil || len(got) != 2 || got[0].Name != "Claude Haiku 5.6" || got[1].Name != "Claude Sonnet 5.5" {
		t.Errorf("%+v %v", got, err)
	}
	if _, err := parseModelsAPI("openai", []byte(`<html>`)); err == nil {
		t.Error("a page that is not JSON should be refused")
	}
}

func TestLineAndVersion(t *testing.T) {
	for id, want := range map[string]string{
		"claude-sonnet-5-5": "sonnet 5.5", "claude-haiku-4-5-20251001": "haiku 4.5", "claude-opus-5": "opus 5",
		"gpt-6.1-sol": "sol 6.1", "gpt-6-luna": "luna 6", "gpt-6-sol": "sol 6",
	} {
		line, ver, ok := lineAndVersion(id)
		var parts []string
		for _, v := range ver {
			parts = append(parts, fmt.Sprint(v))
		}
		if !ok || line+" "+strings.Join(parts, ".") != want {
			t.Errorf("%s -> %s %v %v", id, line, ver, ok)
		}
	}
	if _, _, ok := lineAndVersion("claude-fable"); ok {
		t.Error("an id without a version has no line")
	}
}

// the registry used below: Sonnet 5 holds the eval default and `sonnet`; Sonnet 5.5 is present too; Haiku 4.5 holds `haiku`; OpenAI has Sol 6 and Luna.
func proposalDoc() map[string]any {
	var doc map[string]any
	_ = json.Unmarshal([]byte(`{
	 "defaults": {"eval": {"anthropic": "claude-sonnet-5", "openai": "gpt-6-luna"}, "light": {"anthropic": "claude-haiku-4-5-20251001", "openai": "gpt-6-luna"}},
	 "models": {
	  "anthropic": [
	   {"id": "claude-opus-5-5", "name": "Claude Opus 5.5", "alias": "opus"},
	   {"id": "claude-sonnet-5", "name": "Claude Sonnet 5", "alias": "sonnet"}, {"id": "claude-sonnet-5-5", "name": "Claude Sonnet 5.5"},
	   {"id": "claude-haiku-4-5-20251001", "name": "Claude Haiku 4.5", "alias": "haiku"}],
	  "openai": [{"id": "gpt-6-sol", "name": "GPT-6 Sol"}, {"id": "gpt-6-luna", "name": "GPT-6 Luna"}]}}`), &doc)
	return doc
}

func TestBuildProposal(t *testing.T) {
	finds := []found{
		{Provider: "anthropic", ID: "claude-haiku-5-6", Name: "Claude Haiku 5.6", In: 0.1, Out: 0.5, PriceKnow: true, From: true},
		{Provider: "anthropic", ID: "claude-sonnet-5-5", Name: "Claude Sonnet 5.5"}, // already in the registry
		{Provider: "anthropic", ID: "claude-fable-5-1", Name: "Claude Fable 5.1"},   // a line the registry does not have: never mapped
		{Provider: "anthropic", ID: "claude-sonnet-4-5", Name: "Claude Sonnet 4.5"}, // lower than every active Sonnet: replaces nothing
		{Provider: "openai", ID: "gpt-6.1-sol", Name: "GPT-6.1 Sol"},                // same family, higher version
		{Provider: "openai", ID: "gpt-6.1-nova", Name: "GPT-6.1 Nova"},              // a new family: not mapped to Sol or Luna
	}
	p := buildProposal(proposalDoc(), finds)
	by := map[string]proposalEntry{}
	for _, e := range p.Add {
		by[e.ID] = e
	}
	if len(p.Add) != 5 || by["claude-sonnet-5-5"].ID != "" {
		t.Errorf("only models the registry lacks are offered: %v", p.Add)
	}
	if h := by["claude-haiku-5-6"]; h.Replaces != "claude-haiku-4-5-20251001" || h.Gate || !h.From || !h.PriceKnow {
		t.Errorf("haiku 5.6 should replace Haiku 4.5 with a flagged price: %+v", h)
	}
	if by["claude-fable-5-1"].Replaces != "" || by["claude-sonnet-4-5"].Replaces != "" || by["gpt-6.1-nova"].Replaces != "" {
		t.Errorf("no match is never mapped: %+v", p.Add)
	}
	if s := by["gpt-6.1-sol"]; s.Replaces != "gpt-6-sol" {
		t.Errorf("sol 6.1 should replace sol 6: %+v", s)
	}
	// the registry already holds Sonnet 5 and 5.5: offered for retirement, and it changes the gate model
	if len(p.Retire) != 1 || p.Retire[0].Old != "claude-sonnet-5" || p.Retire[0].New != "claude-sonnet-5-5" || !p.Retire[0].Gate {
		t.Errorf("retire: %+v", p.Retire)
	}
	if strings.Join(p.Current, ",") != "Claude Haiku 4.5,Claude Opus 5.5,Claude Sonnet 5.5,GPT-6 Luna,GPT-6 Sol" {
		t.Errorf("current: %v", p.Current)
	}
	// a replacement that would change the gate model is flagged on its add row too
	doc := proposalDoc()
	e := buildProposal(doc, []found{{Provider: "anthropic", ID: "claude-sonnet-5-6", Name: "Claude Sonnet 5.6"}}).Add[0]
	if e.Replaces != "claude-sonnet-5-5" || e.Gate {
		t.Errorf("5.6 replaces the highest lower active one, 5.5, which is not the default: %+v", e)
	}
}

func TestApplyProposalAddsBeforeItRetires(t *testing.T) {
	doc := proposalDoc()
	add := map[string]any{"id": "claude-sonnet-5-6", "provider": "anthropic", "name": "Claude Sonnet 5.6", "input_price": 2.0, "output_price": 10.0}
	// retiring Sonnet 5 in favour of a model added in the same apply works only because the add comes first
	if err := applyProposal(doc, []map[string]any{add}, [][2]string{{"claude-sonnet-5", "claude-sonnet-5-6"}}); err != nil {
		t.Fatal(err)
	}
	if entry(t, doc, "claude-sonnet-5-6")["alias"] != "sonnet" || defaultOf(doc, "eval", "anthropic") != "claude-sonnet-5-6" || entry(t, doc, "claude-sonnet-5")["legacy"] != true {
		t.Errorf("alias, default and legacy flag: %v", doc)
	}
	if !modelTiersValid(doc) {
		t.Error("the applied registry must be valid")
	}
	for name, bad := range map[string][]map[string]any{
		"an id already in the registry": {{"id": "claude-opus-5-5", "provider": "anthropic", "name": "x"}},
		"an id with a path":             {{"id": "../x", "provider": "anthropic", "name": "x"}},
		"an unknown provider":           {{"id": "m-1", "provider": "acme", "name": "x"}},
		"a negative price":              {{"id": "m-2", "provider": "openai", "name": "x", "input_price": -1.0}},
	} {
		if err := applyProposal(proposalDoc(), bad, nil); err == nil {
			t.Errorf("%s should be refused", name)
		}
	}
	if err := applyProposal(proposalDoc(), nil, [][2]string{{"claude-sonnet-5", "nope"}}); err == nil {
		t.Error("a retire onto a model that does not exist should be refused")
	}
}

// A saved source is an https address of a known kind and provider; a Models API source can only be the provider's own host.
func TestModelSourcesValidation(t *testing.T) {
	ok := func(src string) bool {
		var doc map[string]any
		_ = json.Unmarshal([]byte(`{"defaults":{},"models":{"anthropic":[],"openai":[]},"sources":[`+src+`]}`), &doc)
		return modelTiersValid(doc)
	}
	if !ok(`{"url":"https://example.com/models","kind":"docs","provider":"openai"}`) || !ok(`{"url":"https://api.anthropic.com/v1/models","kind":"api","provider":"anthropic"}`) {
		t.Error("good sources were refused")
	}
	for _, bad := range []string{
		`{"url":"http://example.com/","kind":"docs","provider":"openai"}`,
		`{"url":"https://127.0.0.1/","kind":"docs","provider":"openai"}`,
		`{"url":"https://example.com/","kind":"scrape","provider":"openai"}`,
		`{"url":"https://example.com/","kind":"docs","provider":"acme"}`,
		`{"url":"https://evil.example/v1/models","kind":"api","provider":"anthropic"}`,
		`{"url":"https://api.openai.com/v1/models","kind":"api","provider":"anthropic"}`,
	} {
		if ok(bad) {
			t.Errorf("should be refused: %s", bad)
		}
	}
}

// The refresh reads only saved sources, reports a refusal as one line, skips a Models API source without its key, and never lets a key out.
func TestRefreshSourcesNeverLeaksAKey(t *testing.T) {
	const key = "sk-test-secret-1234567890"
	t.Setenv("ANTHROPIC_API_KEY", key)
	t.Setenv("OPENAI_API_KEY", "")
	var gotKey, gotVer string
	o := stub(t, func(w http.ResponseWriter, r *http.Request) {
		gotKey, gotVer = r.Header.Get("x-api-key"), r.Header.Get("anthropic-version")
		if r.URL.Path == "/redir" {
			http.Redirect(w, r, "https://ok.test/elsewhere", http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"data":[{"id":"claude-haiku-5-6","display_name":"Claude Haiku 5.6"}]}`)
	})
	doc := proposalDoc()
	doc["sources"] = []any{
		map[string]any{"url": "https://ok.test/v1/models", "kind": "api", "provider": "anthropic"},
		map[string]any{"url": "https://ok.test/v1/models", "kind": "api", "provider": "openai"}, // no OPENAI_API_KEY: skipped
		map[string]any{"url": "https://evil.test/models", "kind": "docs", "provider": "openai"}, // resolves private: refused
		map[string]any{"url": "https://ok.test/redir", "kind": "api", "provider": "anthropic"},  // a redirect on a keyed request: refused
	}
	res, st := refreshSources(doc, -1, o)
	if gotKey != key || gotVer == "" {
		t.Errorf("the key should go to the API source: %q %q", gotKey, gotVer)
	}
	if st[1].OK || st[2].OK || st[3].OK || !st[0].OK {
		t.Errorf("only the source that was read is ok: %+v", st)
	}
	if st[0].Status != "checked just now" || st[0].Found != 1 || st[1].Status != "key not set" || !strings.Contains(st[2].Status, "refused: ") || !strings.Contains(st[3].Status, "carries a key") {
		t.Errorf("statuses: %+v", st)
	}
	body, _ := json.Marshal(map[string]any{"proposal": res["proposal"], "sources": st})
	if strings.Contains(string(body), key) {
		t.Errorf("the key appears in the response: %s", body)
	}
	if strings.Contains(redactKey("failed with "+key), key) {
		t.Error("redactKey should remove the key")
	}
	if p := res["proposal"].(proposal); len(p.Add) != 1 || p.Add[0].ID != "claude-haiku-5-6" || p.Add[0].Replaces != "claude-haiku-4-5-20251001" {
		t.Errorf("proposal: %+v", p)
	}
	// one source by index
	_, only := refreshSources(doc, 2, o)
	if len(only) != 1 || only[0].Index != 2 {
		t.Errorf("a single refresh: %+v", only)
	}
	_ = os.Getenv
}
