package board

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Second pass over t-d40b's Go code, written from the mutation sweep's survivors: each test names what a changed line would have let through.

func TestFetchURLEarlyRefusalsAndPorts(t *testing.T) {
	for _, raw := range []string{"https://127.0.0.1/", "https://[::1]/", "https://10.0.0.1/x", "https://169.254.169.254/"} {
		if _, err := checkFetchURL(raw); err == nil || err.Error() != "a private, loopback or link-local address is refused" {
			t.Errorf("%s: %v", raw, err)
		}
	}
	for _, raw := range []string{"https://8.8.8.8/", "https://ok.test:443/x", "https://ok.test/"} {
		if _, err := checkFetchURL(raw); err != nil {
			t.Errorf("%s should pass the URL check: %v", raw, err)
		}
	}
	if _, err := checkFetchURL("https://exa mple.com/"); err == nil || err.Error() != "not a valid address" {
		t.Errorf("an unparseable address: %v", err)
	}
}

func TestFetchDefaultTimeoutAndEdgePaths(t *testing.T) {
	old := fetchTimeout
	fetchTimeout = 300 * time.Millisecond
	defer func() { fetchTimeout = old }()
	slow := stub(t, func(w http.ResponseWriter, r *http.Request) { time.Sleep(2 * time.Second) })
	slow.timeout = 0 // no override: the package default applies
	start := time.Now()
	if _, err := guardedGet(context.Background(), "https://ok.test/", slow); err == nil || time.Since(start) > 1500*time.Millisecond {
		t.Errorf("the default timeout should apply: %v after %v", err, time.Since(start))
	}
	// a literal public IP in the URL is dialled as it is (the resolver is not asked)
	ok := stub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("hi"))
	})
	ok.resolve = func(context.Context, string) ([]net.IP, error) {
		return nil, errors.New("the resolver must not be asked for a literal IP")
	}
	if b, err := guardedGet(context.Background(), "https://8.8.8.8/", ok); err != nil || string(b) != "hi" {
		t.Errorf("a literal public IP: %q %v", b, err)
	}
	// a resolver that fails, and one that answers with nothing, are errors
	none := stub(t, func(w http.ResponseWriter, r *http.Request) {})
	if _, err := guardedGet(context.Background(), "https://nohost.test/", none); err == nil || !strings.Contains(err.Error(), "no such host") {
		t.Errorf("a failing resolver: %v", err)
	}
	none.resolve = resolveTo(map[string][]string{"empty.test": {}})
	if _, err := guardedGet(context.Background(), "https://empty.test/", none); err == nil || !strings.Contains(err.Error(), "no such host") && !strings.Contains(err.Error(), "did not resolve") {
		t.Errorf("an empty answer: %v", err)
	}
	// the request names what it accepts, and a failed request shows the cause, not the client's wrapper
	var accept string
	o := stub(t, func(w http.ResponseWriter, r *http.Request) {
		accept = r.Header.Get("Accept")
		http.Redirect(w, r, "http://ok.test/", http.StatusFound)
	})
	_, err := guardedGet(context.Background(), "https://ok.test/", o)
	if !strings.Contains(accept, "text/html") || accept == "" {
		t.Errorf("Accept = %q", accept)
	}
	if err == nil || strings.Contains(err.Error(), `Get "`) || !strings.HasPrefix(err.Error(), "redirected to ok.test") {
		t.Errorf("the error should be the cause itself: %v", err)
	}
}

func TestRemoveRefusesEveryKnownAliasWithoutAMove(t *testing.T) {
	for _, alias := range []string{"fable", "opus", "sonnet", "haiku"} {
		doc := regDoc()
		list := doc["models"].(map[string]any)["anthropic"].([]any)
		list = append(list, map[string]any{"id": "probe-" + alias, "alias": alias}) // holds the alias, no default
		doc["models"].(map[string]any)["anthropic"] = list
		// two holders of one alias are not valid, so drop the original holder's alias first
		for _, e := range list[:len(list)-1] {
			if m := e.(map[string]any); m["alias"] == alias {
				m["alias"] = ""
			}
		}
		if err := removeModel(doc, "probe-"+alias, ""); err == nil || !strings.Contains(err.Error(), "the alias "+alias) {
			t.Errorf("%s: err = %v", alias, err)
		}
	}
	if err := removeModel(regDoc(), "nope", ""); err == nil || !strings.Contains(err.Error(), "no model") {
		t.Errorf("an unknown id: %v", err)
	}
	doc := regDoc()
	before, _ := json.Marshal(doc)
	if err := removeModel(doc, "claude-sonnet-5", "nope"); err == nil || !strings.Contains(err.Error(), "no model") {
		t.Errorf("an unknown move target: %v", err)
	}
	if after, _ := json.Marshal(doc); string(before) != string(after) {
		t.Error("a refused remove changed the registry")
	}
	// the messages name the models involved
	if err := retireModel(regDoc(), "claude-sonnet-5", "claude-opus-5-5"); err == nil || !strings.Contains(err.Error(), "claude-opus-5-5 already has the alias opus") {
		t.Errorf("alias conflict message: %v", err)
	}
	if err := retireModel(regDoc(), "claude-sonnet-5", "gpt-6-sol"); err == nil || !strings.Contains(err.Error(), "claude-sonnet-5 can only move to the same provider") {
		t.Errorf("provider message: %v", err)
	}
}

func TestAliasOfAndConsistencyEdgeCases(t *testing.T) {
	doc := regDoc()
	list := doc["models"].(map[string]any)["anthropic"].([]any)
	list[2].(map[string]any)["alias"] = nil // a JSON null alias is "no alias", never the text "<nil>"
	if aliasOf(list[2].(map[string]any)) != "" {
		t.Error("a null alias is empty")
	}
	if a, _ := heldBy(doc, "anthropic", list[2].(map[string]any)); a != "" {
		t.Errorf("heldBy read a null alias as %q", a)
	}
	list = append(list, map[string]any{"id": "x-1", "alias": nil}, map[string]any{"id": "x-2", "alias": ""}, map[string]any{"id": "x-3"})
	doc["models"].(map[string]any)["anthropic"] = list
	if !modelTiersValid(doc) {
		t.Error("several entries with no alias are valid")
	}
	// a null or empty alias on the target is no conflict
	d2 := regDoc()
	d2["models"].(map[string]any)["anthropic"].([]any)[2].(map[string]any)["alias"] = nil
	if err := retireModel(d2, "claude-sonnet-5", "claude-sonnet-5-5"); err != nil {
		t.Errorf("a target with a null alias takes the alias: %v", err)
	}
	// the sources key: a string, a list of strings, are invalid
	for _, src := range []string{`"x"`, `["x"]`, `[{"url":"https://example.com/","kind":"docs"}]`} {
		var d map[string]any
		_ = json.Unmarshal([]byte(`{"defaults":{},"models":{"anthropic":[],"openai":[]},"sources":`+src+`}`), &d)
		if modelTiersValid(d) {
			t.Errorf("sources %s should be invalid", src)
		}
	}
}

// registryMove loads the current registry, applies a change, and saves it through the same validation; a refused change saves nothing.
func TestRegistryMoveSavesOnlyAGoodChange(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	user := filepath.Join(dir, "cockpit", "model-tiers.json")
	seed := filepath.Join(dir, "seed.json")
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	raw, _ := json.Marshal(regDoc())
	if err := os.WriteFile(seed, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	res := registryMove(func(map[string]any) error { return errors.New("no thanks") })
	if res["ok"] != false || res["error"] != "no thanks" || res["data"] != nil {
		t.Errorf("a refused change: %v", res)
	}
	if _, err := os.Stat(user); err == nil {
		t.Error("a refused change must not write the registry")
	}
	res = registryMove(func(doc map[string]any) error { return retireModel(doc, "claude-sonnet-5", "claude-sonnet-5-5") })
	if res["ok"] != true || res["data"] == nil {
		t.Fatalf("a good change: %v", res)
	}
	var saved map[string]any
	b, _ := os.ReadFile(user)
	if err := json.Unmarshal(b, &saved); err != nil || defaultOf(saved, "eval", "anthropic") != "claude-sonnet-5-5" {
		t.Errorf("the change should be saved: %v %v", err, saved["defaults"])
	}
	if defaultOf(res["data"].(map[string]any), "eval", "anthropic") != "claude-sonnet-5-5" {
		t.Error("the response carries the new registry")
	}
	// a change that makes the registry invalid is refused by the shared validation and saves nothing more
	before, _ := os.ReadFile(user)
	res = registryMove(func(doc map[string]any) error {
		doc["models"].(map[string]any)["anthropic"].([]any)[0].(map[string]any)["alias"] = "sonnet"
		return nil
	})
	after, _ := os.ReadFile(user)
	if res["ok"] != false || string(before) != string(after) {
		t.Errorf("an invalid result must be refused: %v", res)
	}
}

func TestVersionAndNameHelpers(t *testing.T) {
	less := func(a, b []int) bool { return versionLess(a, b) }
	for _, c := range []struct {
		a, b []int
		want bool
	}{
		{[]int{5, 5}, []int{5, 6}, true}, {[]int{5, 6}, []int{5, 5}, false}, {[]int{5, 5}, []int{5, 5}, false},
		{[]int{5}, []int{5, 1}, true}, {[]int{5, 1}, []int{5}, false}, {[]int{5}, []int{5, 0}, false}, {[]int{4, 9}, []int{5}, true}, {nil, []int{1}, true}, {[]int{1}, nil, false},
	} {
		if less(c.a, c.b) != c.want {
			t.Errorf("versionLess(%v, %v) != %v", c.a, c.b, c.want)
		}
	}
	for id, want := range map[string]string{
		"claude-haiku-5-6": "Claude Haiku 5.6", "claude-haiku-4-5-20251001": "Claude Haiku 4.5", "gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-sol-mini": "GPT-6 Sol Mini",
		"claude-sonnet-5": "Claude Sonnet 5",
	} {
		if got := displayName(id); got != want {
			t.Errorf("displayName(%s) = %q, want %q", id, got, want)
		}
	}
	for _, id := range []string{"xclaude-opus-5", "claude-opus-5-preview", "claude-opus", "gpt-6", "my-gpt-6-sol", "gpt-6-sol-x-y"} {
		if _, _, ok := lineAndVersion(id); ok {
			t.Errorf("%s is not a model id of a known shape", id)
		}
	}
	if line, ver, ok := lineAndVersion("claude-haiku-4-5-20251001"); !ok || line != "haiku" || len(ver) != 2 {
		t.Errorf("a dated id drops its date: %s %v", line, ver)
	}
}

func TestParsersEdgeCases(t *testing.T) {
	// an id repeated on a page is one find; an id at the very end of the text still parses
	got := parseDocsPage("anthropic", `claude-opus-5-5 $4 $20 ... claude-opus-5-5 $9 $9 ... claude-fable-5-1`)
	if len(got) != 2 || got[0].In != 4 || got[0].Out != 20 || got[1].PriceKnow {
		t.Errorf("%+v", got)
	}
	if got := parseDocsPage("anthropic", `<p>claude-opus-5-5 &#36;4 and &#36;20</p><p>a&nbsp;claude-fable-5-1&nbsp;&amp;</p>`); len(got) != 2 || got[0].In != 4 || got[0].Out != 20 {
		t.Errorf("entities: %+v", got)
	}
	api, err := parseModelsAPI("openai", []byte(`{"data":[{"id":"gpt-6.1-sol"},{"id":"claude-opus-5-5"},{"id":"xgpt-6-sol"},{"id":"gpt-6-sol-beta-x"},{"id":"gpt-6-luna","display_name":"Luna"}]}`))
	if err != nil || len(api) != 2 || api[0].ID != "gpt-6.1-sol" || api[0].Name != "GPT-6.1 Sol" || api[1].Name != "Luna" {
		t.Errorf("openai list: %+v %v", api, err)
	}
	if _, err := parseModelsAPI("anthropic", []byte(`nope`)); err == nil || err.Error() != "the answer is not a model list" {
		t.Errorf("not JSON: %v", err)
	}
	api, _ = parseModelsAPI("anthropic", []byte(`{"data":[{"id":"gpt-6.1-sol"},{"id":"xclaude-opus-5-5"},{"id":"claude-opus-5-5-preview"},{"id":"claude-opus-5-5"}]}`))
	if len(api) != 1 || api[0].ID != "claude-opus-5-5" {
		t.Errorf("anthropic ids of another shape: %+v", api)
	}
}

func TestBuildProposalOrderLegacyAndCustomEntries(t *testing.T) {
	doc := proposalDoc()
	m := doc["models"].(map[string]any)
	m["anthropic"] = append(m["anthropic"].([]any),
		map[string]any{"id": "claude-haiku-5-5", "name": "Claude Haiku 5.5"},
		map[string]any{"id": "claude-sonnet-5-4", "name": "Claude Sonnet 5.4", "legacy": true}, // legacy: never a replacement target, never listed
		map[string]any{"id": "custom-model", "name": "Custom"},                                 // no line: skipped
		map[string]any{"id": "claude-opus-5-5-fast", "name": "Opus fast"})                      // a lookalike that is not a model id shape
	m["openai"] = append(m["openai"].([]any), map[string]any{"id": "gpt-6.1-sol", "name": "GPT-6.1 Sol"})
	p := buildProposal(doc, []found{
		{Provider: "anthropic", ID: "claude-sonnet-5-6", Name: "Claude Sonnet 5.6"}, {Provider: "anthropic", ID: "claude-aaa-1", Name: "A"},
		{Provider: "openai", ID: "gpt-6.2-sol", Name: "GPT-6.2 Sol"}, {Provider: "anthropic", ID: "claude-fable-5-1", Name: "F"}})
	var ids []string
	for _, e := range p.Add {
		ids = append(ids, e.ID)
	}
	if strings.Join(ids, ",") != "claude-aaa-1,claude-fable-5-1,claude-sonnet-5-6,gpt-6.2-sol" {
		t.Errorf("adds are sorted by id: %v", ids)
	}
	for _, e := range p.Add {
		if e.ID == "claude-sonnet-5-6" && e.Replaces != "claude-sonnet-5-5" {
			t.Errorf("5.6 replaces 5.5, not the legacy 5.4: %+v", e)
		}
		if e.ID == "gpt-6.2-sol" && e.Replaces != "gpt-6.1-sol" {
			t.Errorf("sol 6.2 replaces 6.1: %+v", e)
		}
	}
	var olds []string
	for _, r := range p.Retire {
		olds = append(olds, r.Old)
	}
	if strings.Join(olds, ",") != "claude-haiku-4-5-20251001,claude-sonnet-5,gpt-6-sol" {
		t.Errorf("retire list sorted, no legacy or custom entries: %v", olds)
	}
	for _, c := range p.Current {
		if strings.Contains(c, "5.4") || c == "Custom" {
			t.Errorf("a legacy or line-less entry must not be listed current: %v", p.Current)
		}
	}
	// the same version under two ids (dated and undated) retires neither and is listed current, not dropped
	d2 := proposalDoc()
	d2["models"].(map[string]any)["anthropic"] = append(d2["models"].(map[string]any)["anthropic"].([]any), map[string]any{"id": "claude-haiku-4-5", "name": "Claude Haiku 4.5 undated"})
	for _, r := range buildProposal(d2, nil).Retire {
		if strings.HasPrefix(r.Old, "claude-haiku-4-5") {
			t.Errorf("equal versions retire nothing: %+v", r)
		}
	}
	// a registry entry of another provider with the same line word is not a candidate
	d3 := proposalDoc()
	d3["models"].(map[string]any)["openai"] = append(d3["models"].(map[string]any)["openai"].([]any), map[string]any{"id": "gpt-6-haiku", "name": "GPT-6 Haiku"})
	e := buildProposal(d3, []found{{Provider: "anthropic", ID: "claude-haiku-5-9", Name: "H"}}).Add[0]
	if e.Replaces != "claude-haiku-4-5-20251001" {
		t.Errorf("only the same provider's line counts: %+v", e)
	}
}

func TestApplyProposalEntryShapeAndBoundaries(t *testing.T) {
	doc := proposalDoc()
	adds := []map[string]any{
		{"id": "claude-haiku-5-6", "provider": "anthropic", "name": "Claude Haiku 5.6", "input_price": 0.0, "output_price": 0.5},
		{"id": "gpt-6.2-sol", "provider": "openai", "name": "GPT-6.2 Sol", "input_price": 2.0, "output_price": 10.0},
	}
	if err := applyProposal(doc, adds, nil); err != nil {
		t.Fatal(err)
	}
	h := entry(t, doc, "claude-haiku-5-6")
	for _, k := range []string{"id", "name", "desc", "reasoning", "input_price", "output_price", "alias"} {
		if _, ok := h[k]; !ok {
			t.Errorf("an added Anthropic entry lacks %q: %v", k, h)
		}
	}
	if h["name"] != "Claude Haiku 5.6" || h["input_price"] != 0.0 || h["output_price"] != 0.5 || h["alias"] != "" {
		t.Errorf("%v", h)
	}
	g := entry(t, doc, "gpt-6.2-sol")
	if _, has := g["alias"]; has || g["output_price"] != 10.0 {
		t.Errorf("an OpenAI entry carries no alias key: %v", g)
	}
	if err := applyProposal(proposalDoc(), []map[string]any{{"id": "m-3", "provider": "openai", "name": "x", "input_price": 1.0, "output_price": -0.5}}, nil); err == nil || err.Error() != "a price cannot be negative" {
		t.Errorf("a negative output price: %v", err)
	}
}

func TestWireFormatOfProposalAndStatus(t *testing.T) {
	p := proposal{Add: []proposalEntry{{found: found{Provider: "anthropic", ID: "a", Name: "A", In: 1, Out: 2, PriceKnow: true, From: true}, Replaces: "b", ReplacesAll: "B", Gate: true}},
		Retire: []retireEntry{{Old: "o", OldName: "O", New: "n", NewName: "N", Gate: true}}, Current: []string{"C"}}
	b, _ := json.Marshal(map[string]any{"proposal": p, "sources": []sourceStatus{{Index: 1, Status: "s", OK: true, Found: 2}}})
	var back map[string]any
	_ = json.Unmarshal(b, &back)
	keys := func(m map[string]any) string {
		var ks []string
		for k := range m {
			ks = append(ks, k)
		}
		sortStrings(ks)
		return strings.Join(ks, ",")
	}
	prop := back["proposal"].(map[string]any)
	if keys(prop) != "add,current,retire" {
		t.Errorf("proposal keys: %s", keys(prop))
	}
	if k := keys(prop["add"].([]any)[0].(map[string]any)); k != "changes_gate_model,id,input_price,name,output_price,price_from,price_known,provider,replaces,replaces_name" {
		t.Errorf("add keys: %s", k)
	}
	if k := keys(prop["retire"].([]any)[0].(map[string]any)); k != "changes_gate_model,new,new_name,old,old_name" {
		t.Errorf("retire keys: %s", k)
	}
	if k := keys(back["sources"].([]any)[0].(map[string]any)); k != "found,index,ok,status" {
		t.Errorf("status keys: %s", k)
	}
	var plain map[string]any
	pb, _ := json.Marshal(proposalEntry{found: found{ID: "x"}})
	_ = json.Unmarshal(pb, &plain)
	if _, has := plain["replaces"]; has {
		t.Error("an empty replaces is left out")
	}
}

func sortStrings(s []string) {
	for i := range s {
		for j := i + 1; j < len(s); j++ {
			if s[j] < s[i] {
				s[i], s[j] = s[j], s[i]
			}
		}
	}
}

// Refresh: the OpenAI key goes as a Bearer token to the API source only; a docs source never carries a key; a bad answer is a one-line status
// and does not stop the others; one source by index 0 is fetched alone; a source found twice keeps the priced copy.
func TestRefreshSourcesProviderPathsAndMerge(t *testing.T) {
	t.Setenv("OPENAI_API_KEY", "sk-openai-0123456789")
	t.Setenv("ANTHROPIC_API_KEY", "sk-anthropic-0123456789")
	var auth, xkey = map[string]string{}, map[string]string{}
	hits := map[string]int{}
	o := stub(t, func(w http.ResponseWriter, r *http.Request) {
		hits[r.URL.Path]++
		auth[r.URL.Path], xkey[r.URL.Path] = r.Header.Get("Authorization"), r.Header.Get("x-api-key")
		switch r.URL.Path {
		case "/openai-api":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"data":[{"id":"gpt-6.2-sol"}]}`))
		case "/docs":
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<p>gpt-6.2-sol $2 $10</p>`))
		case "/badjson":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`not json`))
		}
	})
	doc := proposalDoc()
	doc["sources"] = []any{
		map[string]any{"url": "https://ok.test/openai-api", "kind": "api", "provider": "openai"},
		map[string]any{"url": "https://ok.test/docs", "kind": "docs", "provider": "openai"},
		map[string]any{"url": "https://ok.test/badjson", "kind": "api", "provider": "openai"},
	}
	res, st := refreshSources(doc, -1, o)
	if auth["/openai-api"] != "Bearer sk-openai-0123456789" || xkey["/openai-api"] != "" {
		t.Errorf("the OpenAI key goes as a Bearer token only: %q %q", auth["/openai-api"], xkey["/openai-api"])
	}
	if auth["/docs"] != "" || xkey["/docs"] != "" {
		t.Errorf("a docs source never carries a key: %q %q", auth["/docs"], xkey["/docs"])
	}
	if !st[0].OK || !st[1].OK || st[2].OK || st[2].Status != "the answer is not a model list" || st[0].Found != 1 {
		t.Errorf("statuses: %+v", st)
	}
	// found twice (API without a price, docs with one): the priced copy is kept whichever came first
	add := res["proposal"].(proposal).Add
	if len(add) != 1 || !add[0].PriceKnow || add[0].In != 2 || add[0].Replaces != "gpt-6-sol" {
		t.Errorf("merged find: %+v", add)
	}
	hits = map[string]int{}
	_, only := refreshSources(doc, 0, o)
	if len(only) != 1 || only[0].Index != 0 || hits["/openai-api"] != 1 || hits["/docs"] != 0 {
		t.Errorf("one source by index 0: %+v %v", only, hits)
	}
	// redactKey: a six-character key is still removed, either provider's
	t.Setenv("OPENAI_API_KEY", "abc123")
	if got := redactKey("bad abc123 and " + os.Getenv("ANTHROPIC_API_KEY")); strings.Contains(got, "abc123") || strings.Contains(got, "sk-anthropic") || !strings.Contains(got, "***") {
		t.Errorf("redactKey: %q", got)
	}
	t.Setenv("OPENAI_API_KEY", "abcde")
	if got := redactKey("abcde"); got != "abcde" {
		t.Errorf("a key of fewer than six characters is not worth masking (it would blank ordinary words): %q", got)
	}
}
