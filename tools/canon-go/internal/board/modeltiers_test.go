package board

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// regDoc is a small registry shaped like model-tiers.json: Sonnet 5 holds the sonnet alias and the eval default,
// Haiku 4.5 holds haiku and the light default; 5.5 entries carry no alias; OpenAI has Sol and Luna.
func regDoc() map[string]any {
	var doc map[string]any
	_ = json.Unmarshal([]byte(`{
	 "defaults": {"plan": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5-5"}, "build": {"claude": "claude-sonnet-5-5", "copilot": "gpt-6-sol"},
	  "reviewer": {"claude": "claude-sonnet-5", "copilot": "gpt-6-luna"}, "evaluator": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"},
	  "light": {"claude": "claude-haiku-4-5", "copilot": "claude-haiku-4-5"}},
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
	for _, slot := range [][2]string{{"evaluator", "claude"}, {"evaluator", "copilot"}, {"reviewer", "claude"}} { // t-8f6d: every slot that named it
		if got := defaultOf(doc, slot[0], slot[1]); got != "claude-sonnet-5-5" {
			t.Errorf("%s.%s default = %s", slot[0], slot[1], got)
		}
	}
	if got := defaultOf(doc, "reviewer", "copilot"); got != "gpt-6-luna" {
		t.Errorf("an OpenAI default must not move: %s", got)
	}
	if got := defaultOf(doc, "light", "claude"); got != "claude-haiku-4-5" {
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
	if err == nil || !strings.Contains(err.Error(), "the alias sonnet and the Reviewer default for Claude Code and the Evaluator default for Claude Code") {
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
	if entry(t, doc, "claude-sonnet-5-5")["alias"] != "sonnet" || defaultOf(doc, "evaluator", "claude") != "claude-sonnet-5-5" {
		t.Errorf("alias and default should have moved: %v", doc)
	}

	// a default-only holder may move to a model that has an alias; an alias holder may not
	doc = regDoc()
	if err := removeModel(doc, "claude-haiku-4-5", "claude-opus-5-5"); err == nil || !strings.Contains(err.Error(), "already has the alias opus") {
		t.Errorf("alias holder onto an aliased model: %v", err)
	}
	doc = regDoc()
	if err := removeModel(doc, "gpt-6-luna", "gpt-6-sol"); err != nil || defaultOf(doc, "reviewer", "copilot") != "gpt-6-sol" {
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
		d["defaults"].(map[string]any)["light"] = map[string]any{"claude": "claude-haiku-5-5", "copilot": "claude-haiku-5-5"}
	})
	if !modelTiersValid(ok) {
		t.Error("a legacy entry that no default names, and a duplicate alias on a legacy entry, are fine")
	}
	// two entries with the same alias are fine when one is legacy (the retired one keeps its history)
	dup := mut(func(d map[string]any) {
		anth(d)[2].(map[string]any)["alias"] = "sonnet"
		anth(d)[1].(map[string]any)["legacy"] = true
		for _, step := range []string{"reviewer", "evaluator"} {
			for _, agent := range tierAgents {
				if d["defaults"].(map[string]any)[step].(map[string]any)[agent] == "claude-sonnet-5" {
					d["defaults"].(map[string]any)[step].(map[string]any)[agent] = "claude-sonnet-5-5"
				}
			}
		}
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

// t-8f6d + t-2cc8: a registry saved before the per-step, per-agent defaults is read in the new shape. Protects every close's gate models
// (complete.md reads defaults.<role>.<agent>) and Admin > Model tiers after an update: the old Review & Eval pick becomes the reviewer
// and the evaluator for both agents, the old light pick the light, plan and build come from the seed, and nothing else changes.
func TestMigrateTierDefaults(t *testing.T) {
	seed := regDoc()
	old := regDoc()
	old["defaults"] = map[string]any{"eval": map[string]any{"anthropic": "claude-opus-5-5", "openai": "gpt-6-luna"}, "light": map[string]any{"anthropic": "claude-haiku-5-5", "openai": "gpt-6-luna"}}
	models, _ := json.Marshal(old["models"])
	if !migrateTierDefaults(old, seed) {
		t.Fatal("an old-shape registry was not migrated")
	}
	want := map[string]map[string]string{
		"plan": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5-5"}, "build": {"claude": "claude-sonnet-5-5", "copilot": "gpt-6-sol"},
		"reviewer": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5-5"}, "evaluator": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5-5"},
		"light": {"claude": "claude-haiku-5-5", "copilot": "claude-haiku-5-5"},
	}
	got, _ := json.Marshal(old["defaults"])
	wantRaw, _ := json.Marshal(want)
	if string(got) != string(wantRaw) {
		t.Fatalf("migrated defaults = %s, want %s", got, wantRaw)
	}
	if after, _ := json.Marshal(old["models"]); string(after) != string(models) {
		t.Errorf("the migration changed the models: %s", after)
	}
	if !modelTiersValid(old) {
		t.Error("a migrated registry must pass validation")
	}
	again, _ := json.Marshal(old)
	if migrateTierDefaults(old, seed) {
		t.Error("a new-shape registry was migrated again")
	}
	if now, _ := json.Marshal(old); string(now) != string(again) {
		t.Errorf("a second migration changed the document: %s", now)
	}
	// an old file with no light pick takes the seed's light; an empty eval keeps the seed's gates
	part := regDoc()
	part["defaults"] = map[string]any{"eval": map[string]any{}}
	migrateTierDefaults(part, seed)
	if defaultOf(part, "light", "claude") != "claude-haiku-4-5" || defaultOf(part, "evaluator", "copilot") != "claude-sonnet-5" {
		t.Errorf("missing old picks should come from the seed: %v", part["defaults"])
	}
}

// t-8f6d: what a Model tiers save may hold. Protects POST /api/admin/model-tiers and the binding gate: the evaluator is never a Haiku
// model under any agent (user, 2026-11-14), and a pick is a model the agent can run.
func TestTierDefaultsValidation(t *testing.T) {
	set := func(step, agent, id string) map[string]any {
		d := regDoc()
		per, _ := d["defaults"].(map[string]any)[step].(map[string]any)
		if per == nil {
			per = map[string]any{}
			d["defaults"].(map[string]any)[step] = per
		}
		per[agent] = id
		return d
	}
	if !modelTiersValid(regDoc()) {
		t.Fatal("the fixture must be valid")
	}
	for name, d := range map[string]map[string]any{
		"an unknown step":                     set("deploy", "claude", "claude-sonnet-5"),
		"an unknown agent":                    set("reviewer", "codex", "claude-sonnet-5"),
		"the old shape":                       set("eval", "anthropic", "claude-sonnet-5"),
		"an OpenAI model for Claude Code":     set("reviewer", "claude", "gpt-6-luna"),
		"a model not in the registry":         set("build", "copilot", "gpt-9"),
		"a Haiku evaluator under Claude Code": set("evaluator", "claude", "claude-haiku-4-5"),
		"a Haiku evaluator under Copilot":     set("evaluator", "copilot", "claude-haiku-5-5"),
	} {
		if modelTiersValid(d) {
			t.Errorf("%s should be refused", name)
		}
	}
	for name, d := range map[string]map[string]any{
		"an OpenAI evaluator under Copilot": set("evaluator", "copilot", "gpt-6-sol"),
		"a Haiku reviewer":                  set("reviewer", "claude", "claude-haiku-5-5"),
		"an Opus evaluator":                 set("evaluator", "claude", "claude-opus-5-5"),
	} {
		if !modelTiersValid(d) {
			t.Errorf("%s should be accepted", name)
		}
	}
}

// t-8f6d: the read path migrates. Protects GET /api/admin/model-tiers and every reader after an update: a user file saved in the old shape
// is answered in the new one (plan and build from the seed), and the file on disk is left until a save.
func TestLoadModelTiersMigratesAnOldUserFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	seed := filepath.Join(dir, "seed.json")
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	raw, _ := json.Marshal(regDoc())
	if err := os.WriteFile(seed, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	user := regDoc()
	user["defaults"] = map[string]any{"eval": map[string]any{"anthropic": "claude-opus-5-5"}, "light": map[string]any{"anthropic": "claude-haiku-5-5"}}
	ub, _ := json.Marshal(user)
	if err := os.MkdirAll(filepath.Dir(modelTiersUserFile()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(modelTiersUserFile(), ub, 0o644); err != nil {
		t.Fatal(err)
	}
	got := loadModelTiers()
	if defaultOf(got, "evaluator", "copilot") != "claude-opus-5-5" || defaultOf(got, "light", "claude") != "claude-haiku-5-5" || defaultOf(got, "plan", "claude") != "claude-opus-5-5" || defaultOf(got, "build", "copilot") != "gpt-6-sol" {
		t.Fatalf("an old user file was not read migrated: %v", got["defaults"])
	}
	if after, _ := os.ReadFile(modelTiersUserFile()); string(after) != string(ub) {
		t.Errorf("a read rewrote the user file")
	}
}

// t-8f6d reviewer: a carried pick that today's rules refuse (a Haiku Review & Eval pick, an id no longer in the registry) takes the seed's
// pick, so a migrated file always validates and Admin is never locked behind a refused save; a mixed file (an old board saved over a new
// one) keeps its new-shape picks. Protects GET and every Admin write after an update.
func TestMigrateTierDefaultsClampsAndKeepsNewPicks(t *testing.T) {
	seed := regDoc()
	for name, eval := range map[string]string{"a Haiku pick": "claude-haiku-4-5", "an id not in the registry": "claude-gone-9"} {
		doc := regDoc()
		doc["defaults"] = map[string]any{"eval": map[string]any{"anthropic": eval}}
		migrateTierDefaults(doc, seed)
		if !modelTiersValid(doc) {
			t.Errorf("%s: the migrated registry fails validation: %v", name, doc["defaults"])
		}
		if got := defaultOf(doc, "evaluator", "claude"); got != "claude-sonnet-5" {
			t.Errorf("%s: evaluator = %s, want the seed's claude-sonnet-5", name, got)
		}
	}
	// a Haiku Review & Eval pick is still a fine reviewer: only the evaluator is clamped
	doc := regDoc()
	doc["defaults"] = map[string]any{"eval": map[string]any{"anthropic": "claude-haiku-4-5"}}
	migrateTierDefaults(doc, seed)
	if got := defaultOf(doc, "reviewer", "claude"); got != "claude-haiku-4-5" {
		t.Errorf("the reviewer lost the user's pick: %s", got)
	}
	mixed := regDoc()
	mixed["defaults"].(map[string]any)["eval"] = map[string]any{"anthropic": "claude-opus-5-5"}
	if !migrateTierDefaults(mixed, seed) {
		t.Fatal("a mixed file keeps its old key")
	}
	if _, has := mixed["defaults"].(map[string]any)["eval"]; has {
		t.Error("the old key survived the migration")
	}
	if defaultOf(mixed, "reviewer", "copilot") != "gpt-6-luna" || defaultOf(mixed, "evaluator", "claude") != "claude-sonnet-5" {
		t.Errorf("a mixed file lost its new-shape picks: %v", mixed["defaults"])
	}
}

// t-8f6d reviewer: a refused save names the default to change, so a person can fix it in Admin.
func TestTierDefaultsProblemNamesTheDefault(t *testing.T) {
	d := regDoc()
	d["defaults"].(map[string]any)["evaluator"].(map[string]any)["copilot"] = "claude-haiku-5-5"
	if got := tierDefaultsProblem(d); got != "the Evaluator default for Copilot CLI: the binding evaluator is never a Haiku model" {
		t.Errorf("problem = %q", got)
	}
	d = regDoc()
	d["defaults"].(map[string]any)["reviewer"].(map[string]any)["claude"] = "gpt-6-luna"
	if got := tierDefaultsProblem(d); got != "the Reviewer default for Claude Code: gpt-6-luna is an OpenAI model, which Claude Code cannot run" {
		t.Errorf("problem = %q", got)
	}
	if res := saveModelTiers(d); res["ok"] == true || !strings.Contains(fmt.Sprint(res["error"]), "the Reviewer default for Claude Code") {
		t.Errorf("save refusal = %v", res)
	}
}

// t-8f6d: an old file with only a light pick by provider (no eval) is still the old shape: it is migrated, the light pick kept.
func TestMigrateTierDefaultsLightOnly(t *testing.T) {
	for _, prov := range []string{"anthropic", "openai"} {
		doc := regDoc()
		doc["defaults"] = map[string]any{"light": map[string]any{prov: "claude-haiku-5-5"}}
		if !migrateTierDefaults(doc, regDoc()) {
			t.Fatalf("a light-only (%s) old file was not migrated", prov)
		}
		want := "claude-haiku-4-5" // the seed's, unless the anthropic pick carried over
		if prov == "anthropic" {
			want = "claude-haiku-5-5"
		}
		if got := defaultOf(doc, "light", "claude"); got != want || defaultOf(doc, "evaluator", "claude") != "claude-sonnet-5" {
			t.Errorf("light-only (%s): light %s (want %s), defaults %v", prov, got, want, doc["defaults"])
		}
	}
}
