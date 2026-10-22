package board

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// regDoc is a small registry shaped like model-tiers.json: Sonnet 5 holds the sonnet alias and the eval default,
// Haiku 4.5 holds haiku and the light default; 5.5 entries carry no alias; OpenAI has Sol and Luna.
func regDoc() map[string]any {
	var doc map[string]any
	_ = json.Unmarshal([]byte(`{
	 "defaults": {"eval": {"anthropic": "claude-sonnet-5", "openai": "gpt-6-luna"}, "light": {"anthropic": "claude-haiku-4-5", "openai": "gpt-6-luna"}},
	 "models": {
	  "anthropic": [
	   {"id": "claude-opus-5-5", "alias": "opus"},
	   {"id": "claude-sonnet-5", "alias": "sonnet"}, {"id": "claude-sonnet-5-5"},
	   {"id": "claude-haiku-4-5", "alias": "haiku"}, {"id": "claude-haiku-5-5"}],
	  "openai": [{"id": "gpt-6-sol"}, {"id": "gpt-6.1-sol"}, {"id": "gpt-6-luna"}]}}`), &doc)
	return doc
}

func entry(t *testing.T, doc map[string]any, id string) map[string]any {
	t.Helper()
	_, m := registryModel(doc, id)
	if m == nil {
		t.Fatalf("no %s in %v", id, doc)
	}
	return m
}

func defaultOf(doc map[string]any, tier, prov string) string {
	return doc["defaults"].(map[string]any)[tier].(map[string]any)[prov].(string)
}

// Protects /api/admin/model-tiers/retire: the alias and every default that named the old model follow the line to the
// replacement, the old entry goes legacy, and the other provider's defaults stay put.
func TestRetireModelMovesAliasAndDefaults(t *testing.T) {
	doc := regDoc()
	if err := retireModel(doc, "claude-sonnet-5", "claude-sonnet-5-5"); err != nil {
		t.Fatal(err)
	}
	if got := entry(t, doc, "claude-sonnet-5-5")["alias"]; got != "sonnet" {
		t.Errorf("alias sonnet did not move: %v", got)
	}
	old := entry(t, doc, "claude-sonnet-5")
	if old["alias"] != "" || old["legacy"] != true {
		t.Errorf("old entry should be legacy with no alias: %v", old)
	}
	if got := defaultOf(doc, "eval", "anthropic"); got != "claude-sonnet-5-5" {
		t.Errorf("eval default = %s", got)
	}
	if got := defaultOf(doc, "eval", "openai"); got != "gpt-6-luna" {
		t.Errorf("an OpenAI default must not move: %s", got)
	}
	if got := defaultOf(doc, "light", "anthropic"); got != "claude-haiku-4-5" {
		t.Errorf("an unrelated default must not move: %s", got)
	}
	if !modelTiersValid(doc) {
		t.Error("the result must pass validation")
	}
}

func TestRetireModelRefusals(t *testing.T) {
	cases := []struct{ name, old, new, want string }{
		{"unknown old", "nope", "claude-sonnet-5-5", "no model"},
		{"unknown new", "claude-sonnet-5", "nope", "no model"},
		{"itself", "claude-sonnet-5", "claude-sonnet-5", "itself"},
		{"across providers", "claude-sonnet-5", "gpt-6-sol", "same provider"},
		{"target has another alias", "claude-sonnet-5", "claude-opus-5-5", "already has the alias opus"},
	}
	for _, c := range cases {
		doc := regDoc()
		before, _ := json.Marshal(doc)
		err := retireModel(doc, c.old, c.new)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
		after, _ := json.Marshal(doc)
		if string(before) != string(after) {
			t.Errorf("%s: a refused retire changed the registry", c.name)
		}
	}
	doc := regDoc()
	_ = retireModel(doc, "claude-sonnet-5", "claude-sonnet-5-5")
	if err := retireModel(doc, "claude-sonnet-5", "claude-sonnet-5-5"); err == nil || !strings.Contains(err.Error(), "already legacy") {
		t.Errorf("retiring a legacy entry: %v", err)
	}
	if err := retireModel(doc, "claude-haiku-4-5", "claude-sonnet-5"); err == nil || !strings.Contains(err.Error(), "legacy; pick an active") {
		t.Errorf("a legacy replacement: %v", err)
	}
}

// Protects Remove: an entry that holds nothing is deleted outright (no tombstone); one that holds an alias or a default
// refuses without a move target and, with one, hands both over before it goes.
func TestRemoveModel(t *testing.T) {
	doc := regDoc()
	if err := removeModel(doc, "claude-haiku-5-5", ""); err != nil {
		t.Fatal(err)
	}
	if _, m := registryModel(doc, "claude-haiku-5-5"); m != nil {
		t.Error("an entry that holds nothing should be deleted")
	}

	doc = regDoc()
	before, _ := json.Marshal(doc)
	err := removeModel(doc, "claude-sonnet-5", "")
	if err == nil || !strings.Contains(err.Error(), "the alias sonnet and the eval default") {
		t.Fatalf("err = %v", err)
	}
	if after, _ := json.Marshal(doc); string(before) != string(after) {
		t.Error("a refused remove changed the registry")
	}

	if err := removeModel(doc, "claude-sonnet-5", "claude-sonnet-5-5"); err != nil {
		t.Fatal(err)
	}
	if _, m := registryModel(doc, "claude-sonnet-5"); m != nil {
		t.Error("the removed entry is still there")
	}
	if entry(t, doc, "claude-sonnet-5-5")["alias"] != "sonnet" || defaultOf(doc, "eval", "anthropic") != "claude-sonnet-5-5" {
		t.Errorf("alias and default should have moved: %v", doc)
	}

	// a default-only holder may move to a model that has an alias; an alias holder may not
	doc = regDoc()
	if err := removeModel(doc, "claude-haiku-4-5", "claude-opus-5-5"); err == nil || !strings.Contains(err.Error(), "already has the alias opus") {
		t.Errorf("alias holder onto an aliased model: %v", err)
	}
	doc = regDoc()
	if err := removeModel(doc, "gpt-6-luna", "gpt-6-sol"); err != nil || defaultOf(doc, "eval", "openai") != "gpt-6-sol" || defaultOf(doc, "light", "openai") != "gpt-6-sol" {
		t.Errorf("OpenAI default holder: %v %v", err, doc["defaults"])
	}

	// a custom alias (not one Claude Code resolves) goes with its entry, so it is deleted without a move target
	doc = regDoc()
	doc["models"].(map[string]any)["anthropic"] = append(doc["models"].(map[string]any)["anthropic"].([]any), map[string]any{"id": "probe", "alias": "probe-alias"})
	if err := removeModel(doc, "probe", ""); err != nil {
		t.Errorf("a custom alias should not block Remove: %v", err)
	}

	// a legacy entry holds nothing and is deleted outright
	doc = regDoc()
	_ = retireModel(doc, "claude-sonnet-5", "claude-sonnet-5-5")
	if err := removeModel(doc, "claude-sonnet-5", ""); err != nil {
		t.Errorf("removing a legacy entry: %v", err)
	}
}

// Protects POST /api/admin/model-tiers: the whole-document validation rejects what would make a gate pick at random or
// run on a model the pickers no longer offer.
func TestModelTiersConsistency(t *testing.T) {
	mut := func(f func(doc map[string]any)) map[string]any { d := regDoc(); f(d); return d }
	anth := func(d map[string]any) []any { return d["models"].(map[string]any)["anthropic"].([]any) }
	bad := map[string]map[string]any{
		"two active entries with one alias": mut(func(d map[string]any) { anth(d)[2].(map[string]any)["alias"] = "SONNET" }),
		"legacy that is not a boolean":      mut(func(d map[string]any) { anth(d)[0].(map[string]any)["legacy"] = "yes" }),
		"a default on a legacy entry":       mut(func(d map[string]any) { anth(d)[1].(map[string]any)["legacy"] = true }),
	}
	for name, d := range bad {
		if modelTiersValid(d) {
			t.Errorf("%s should be invalid", name)
		}
	}
	ok := mut(func(d map[string]any) {
		anth(d)[3].(map[string]any)["legacy"] = true
		d["defaults"].(map[string]any)["light"].(map[string]any)["anthropic"] = "claude-haiku-5-5"
	})
	if !modelTiersValid(ok) {
		t.Error("a legacy entry that no default names, and a duplicate alias on a legacy entry, are fine")
	}
	// two entries with the same alias are fine when one is legacy (the retired one keeps its history)
	dup := mut(func(d map[string]any) {
		anth(d)[2].(map[string]any)["alias"] = "sonnet"
		anth(d)[1].(map[string]any)["legacy"] = true
		d["defaults"].(map[string]any)["eval"].(map[string]any)["anthropic"] = "claude-sonnet-5-5"
	})
	if !modelTiersValid(dup) {
		t.Error("a legacy duplicate alias should be accepted")
	}
}

// The tracked seed must keep passing the stricter validation, or a fresh install could not save its first edit.
func TestSeedModelTiersStaysValid(t *testing.T) {
	raw, err := os.ReadFile("../../../sprint-check-app/model-tiers.json")
	if err != nil {
		t.Fatal(err)
	}
	var seed map[string]any
	if err := json.Unmarshal(raw, &seed); err != nil {
		t.Fatal(err)
	}
	if !modelTiersValid(seed) {
		t.Error("the tracked seed fails modelTiersValid")
	}
}
