package board

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"canon/internal/common"
)

// regDoc is a small registry shaped like model-tiers.json: Sonnet 5 holds the sonnet alias and the eval default,
// Haiku 4.5 holds haiku and the light default; 5.5 entries carry no alias; OpenAI has Sol and Luna.
func regDoc() map[string]any {
	var doc map[string]any
	_ = json.Unmarshal([]byte(`{
	 "defaults": {"plan": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5.5"}, "build": {"claude": "claude-sonnet-5-5", "copilot": "gpt-6-sol"},
	  "reviewer": {"claude": "claude-sonnet-5", "copilot": "gpt-6-luna"}, "evaluator": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"},
	  "light": {"claude": "claude-haiku-4-5", "copilot": "claude-haiku-4.5"}},
	 "copilot_models": [{"id": "claude-opus-5.5"}, {"id": "claude-sonnet-5.5"}, {"id": "claude-sonnet-5"}, {"id": "claude-haiku-5.5"}, {"id": "claude-haiku-4.5"},
	  {"id": "gpt-6-sol"}, {"id": "gpt-6.1-sol"}, {"id": "gpt-6-luna"}],
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
	_, m := common.RegistryModel(doc, id)
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
	for _, slot := range [][2]string{{"evaluator", "claude"}, {"reviewer", "claude"}} { // t-8f6d: every Claude Code slot that named it
		if got := defaultOf(doc, slot[0], slot[1]); got != "claude-sonnet-5-5" {
			t.Errorf("%s.%s default = %s", slot[0], slot[1], got)
		}
	}
	if got := defaultOf(doc, "reviewer", "copilot"); got != "gpt-6-luna" {
		t.Errorf("an OpenAI default must not move: %s", got)
	}
	if got := defaultOf(doc, "evaluator", "copilot"); got != "claude-sonnet-5" { // t-aba6: Copilot's own id, another id space
		t.Errorf("a registry retire moved a Copilot CLI pick: %s", got)
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
	if _, m := common.RegistryModel(doc, "claude-haiku-5-5"); m != nil {
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
	if _, m := common.RegistryModel(doc, "claude-sonnet-5"); m != nil {
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
	if err := removeModel(doc, "gpt-6-luna", "gpt-6-sol"); err != nil || defaultOf(doc, "reviewer", "copilot") != "gpt-6-luna" { // t-aba6: a Copilot pick is never moved by a registry remove
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
		d["defaults"].(map[string]any)["light"] = map[string]any{"claude": "claude-haiku-5-5", "copilot": "claude-haiku-5.5"}
	})
	if !modelTiersValid(ok) {
		t.Error("a legacy entry that no default names, and a duplicate alias on a legacy entry, are fine")
	}
	// two entries with the same alias are fine when one is legacy (the retired one keeps its history)
	dup := mut(func(d map[string]any) {
		anth(d)[2].(map[string]any)["alias"] = "sonnet"
		anth(d)[1].(map[string]any)["legacy"] = true
		for _, step := range []string{"reviewer", "evaluator"} { // a registry default; Copilot picks are Copilot ids (t-aba6), not registry entries
			if d["defaults"].(map[string]any)[step].(map[string]any)["claude"] == "claude-sonnet-5" {
				d["defaults"].(map[string]any)[step].(map[string]any)["claude"] = "claude-sonnet-5-5"
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
	if !common.MigrateTierDefaults(old, seed) {
		t.Fatal("an old-shape registry was not migrated")
	}
	want := map[string]map[string]string{
		"plan": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5.5"}, "build": {"claude": "claude-sonnet-5-5", "copilot": "gpt-6-sol"},
		"reviewer": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5.5"}, "evaluator": {"claude": "claude-opus-5-5", "copilot": "claude-opus-5.5"},
		"light":      {"claude": "claude-haiku-5-5", "copilot": "claude-haiku-5.5"},
		"speccheck":  {"claude": "claude-opus-5-5", "copilot": "claude-opus-5.5"}, // t-9b13: from the old Review & Eval pick, as the reviewer
		"evaluator2": {},                                                          // t-864c: Off (no pick) until one is chosen
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
	if common.MigrateTierDefaults(old, seed) {
		t.Error("a new-shape registry was migrated again")
	}
	if now, _ := json.Marshal(old); string(now) != string(again) {
		t.Errorf("a second migration changed the document: %s", now)
	}
	// an old file with no light pick takes the seed's light; an empty eval keeps the seed's gates
	part := regDoc()
	part["defaults"] = map[string]any{"eval": map[string]any{}}
	common.MigrateTierDefaults(part, seed)
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
		"an unknown step":                        set("deploy", "claude", "claude-sonnet-5"),
		"an unknown agent":                       set("reviewer", "codex", "claude-sonnet-5"),
		"the old shape":                          set("eval", "anthropic", "claude-sonnet-5"),
		"an OpenAI model for Claude Code":        set("reviewer", "claude", "gpt-6-luna"),
		"a Copilot pick outside Claude and GPT":  set("build", "copilot", "gemini-3.8-flash"),
		"a Claude Code pick not in the registry": set("build", "claude", "claude-gone-9"),
		"a Haiku evaluator under Claude Code":    set("evaluator", "claude", "claude-haiku-4-5"),
		"a Haiku evaluator under Copilot":        set("evaluator", "copilot", "claude-haiku-5-5"),
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
	if defaultOf(got, "evaluator", "copilot") != "claude-opus-5.5" || defaultOf(got, "light", "claude") != "claude-haiku-5-5" || defaultOf(got, "plan", "claude") != "claude-opus-5-5" || defaultOf(got, "build", "copilot") != "gpt-6-sol" {
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
		common.MigrateTierDefaults(doc, seed)
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
	common.MigrateTierDefaults(doc, seed)
	if got := defaultOf(doc, "reviewer", "claude"); got != "claude-haiku-4-5" {
		t.Errorf("the reviewer lost the user's pick: %s", got)
	}
	mixed := regDoc()
	mixed["defaults"].(map[string]any)["eval"] = map[string]any{"anthropic": "claude-opus-5-5"}
	if !common.MigrateTierDefaults(mixed, seed) {
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
	d["defaults"].(map[string]any)["evaluator"].(map[string]any)["copilot"] = "claude-haiku-5.5"
	if got := common.TierDefaultsProblem(d); got != "the Evaluator default for Copilot CLI: the binding evaluator is never a Haiku model" {
		t.Errorf("problem = %q", got)
	}
	d = regDoc()
	d["defaults"].(map[string]any)["reviewer"].(map[string]any)["claude"] = "gpt-6-luna"
	if got := common.TierDefaultsProblem(d); got != "the Reviewer default for Claude Code: gpt-6-luna is an OpenAI model, which Claude Code cannot run" {
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
		if !common.MigrateTierDefaults(doc, regDoc()) {
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

// t-aba6 (DRY with validation): what Admin's pickers offer comes from common.TierPickProblem, so a picker can never offer a model a save would
// refuse. Protects GET /api/admin/model-tiers/options, the one owner static/cockpit-admin.js renders.
func TestTierOptions(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	doc := regDoc()
	opts := tierOptions(doc)
	ids := func(step, agent string) []string {
		out := []string{}
		for _, o := range opts[step][agent] {
			out = append(out, o.ID)
		}
		return out
	}
	for step, per := range opts {
		for agent, list := range per {
			for _, o := range list {
				if why := common.TierPickProblem(doc, step, agent, o.ID); why != "" && !o.Saved {
					t.Errorf("%s.%s offers %s, which a save refuses: %s", step, agent, o.ID, why)
				}
			}
		}
	}
	if got := strings.Join(ids("evaluator", "claude"), " "); got != "claude-opus-5-5 claude-sonnet-5 claude-sonnet-5-5" {
		t.Errorf("Claude Code evaluator options = %s (no Haiku, Anthropic only)", got)
	}
	if got := strings.Join(ids("reviewer", "copilot"), " "); got != "claude-opus-5.5 claude-sonnet-5.5 claude-sonnet-5 claude-haiku-5.5 claude-haiku-4.5 gpt-6-sol gpt-6.1-sol gpt-6-luna" {
		t.Errorf("Copilot CLI reviewer options = %s (Copilot's own ids)", got)
	}
	if got := strings.Join(ids("light", "copilot"), " "); got != "claude-haiku-5.5 claude-haiku-4.5 gpt-6-luna" {
		t.Errorf("Copilot CLI light options = %s (the cheap line)", got)
	}
	if g := opts["reviewer"]["copilot"][5].Group; g != "OpenAI" {
		t.Errorf("a GPT model is grouped %q", g)
	}
	// a saved pick no rule offers (a hand-edited file) is still listed, marked, so the select shows what is saved
	doc["defaults"].(map[string]any)["light"].(map[string]any)["claude"] = "claude-opus-5-5"
	found := false
	for _, o := range tierOptions(doc)["light"]["claude"] {
		found = found || (o.ID == "claude-opus-5-5" && !o.Saved)
	}
	if !found {
		t.Errorf("a saved light pick outside the cheap line (valid, just not offered) should stay listed: %v", tierOptions(doc)["light"]["claude"])
	}
	doc["defaults"].(map[string]any)["evaluator"].(map[string]any)["claude"] = "claude-haiku-4-5"
	ev := tierOptions(doc)["evaluator"]["claude"]
	if l := ev[len(ev)-1]; l.ID != "claude-haiku-4-5" || !l.Saved {
		t.Errorf("a saved Haiku evaluator (refused by validation) must be listed as saved_only: %+v", l)
	}
}

// t-aba6 (evaluator, criterion 3): the Copilot CLI pickers list Claude, then GPT, whatever order Copilot answered in; each family keeps
// Copilot's own order. Protects the options route and Admin's grouped pickers.
func TestTierOptionsGroupsClaudeThenGPT(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	doc := regDoc()
	doc["copilot_models"] = []any{map[string]any{"id": "gpt-6-luna"}, map[string]any{"id": "claude-sonnet-5.5"}, map[string]any{"id": "gpt-6-sol"}, map[string]any{"id": "claude-sonnet-5"}}
	doc["defaults"].(map[string]any)["reviewer"].(map[string]any)["copilot"] = "claude-sonnet-5"
	got := []string{}
	for _, o := range tierOptions(doc)["reviewer"]["copilot"] {
		got = append(got, o.Group+":"+o.ID)
	}
	if want := "Anthropic:claude-sonnet-5.5 Anthropic:claude-sonnet-5 OpenAI:gpt-6-luna OpenAI:gpt-6-sol"; strings.Join(got, " ") != want {
		t.Errorf("order = %v, want %s", got, want)
	}
}

// t-3425: the options route names the step each checker checks (Reviewer and Evaluator check Build), the one rule Admin's same-model
// note reads; the other steps check nothing. Protects GET /api/admin/model-tiers/options and Admin > Model tiers' note.
func TestTierOptionsViewNamesChecks(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	got, roles := map[string]string{}, map[string]string{}
	for _, st := range tierOptionsView()["steps"].([]map[string]string) {
		got[st["id"]], roles[st["id"]] = st["checks"], st["role"]
	}
	// the role Admin shows after each label: the spec check is advisory like the reviewer (t-9b13)
	if want := map[string]string{"plan": "", "build": "", "speccheck": "advisory", "reviewer": "advisory", "evaluator": "binding", "evaluator2": "advisory", "light": ""}; fmt.Sprint(roles) != fmt.Sprint(want) {
		t.Errorf("steps[].role = %v, want %v", roles, want)
	}
	want := map[string]string{"plan": "", "build": "", "speccheck": "plan", "reviewer": "build", "evaluator": "build", "evaluator2": "", "light": ""} // t-9b13: the spec check is compared with Plan
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("steps[].checks = %v, want %v", got, want)
	}
}

// t-3425: common.AdminStageModel is Admin's pick as --model takes it: Claude Code gets the entry's alias, else its id; Copilot its own id;
// no pick or a value that is not an id gives "". Protects the session's model at every Cockpit start and sprint approve's Build line.
func TestAdminStageModel(t *testing.T) {
	doc := map[string]any{
		"defaults": map[string]any{"build": map[string]any{"claude": "claude-opus-5-5", "copilot": "gpt-6"}, "plan": map[string]any{"claude": "claude-sonnet-5-5", "copilot": "--model"}},
		"models":   map[string]any{"anthropic": []any{map[string]any{"id": "claude-opus-5-5", "alias": "opus"}, map[string]any{"id": "claude-sonnet-5-5"}}},
	}
	for _, c := range [][3]string{{"build", "claude", "opus"}, {"plan", "claude", "claude-sonnet-5-5"}, {"build", "copilot", "gpt-6"}, {"plan", "copilot", ""}, {"light", "claude", ""}} {
		if got := common.AdminStageModel(doc, c[0], c[1]); got != c[2] {
			t.Errorf("AdminStageModel(%s, %s) = %q, want %q", c[0], c[1], got, c[2])
		}
	}
}

// t-9b13: a registry saved in the new shape before the Spec check step existed reads it from the Reviewer's picks (written so on its next
// save); a file that already has the step keeps it. Protects Admin > Model tiers and the spec check's model at every sprint start.
func TestFillNewStepsFromReviewer(t *testing.T) {
	doc := map[string]any{"defaults": map[string]any{"reviewer": map[string]any{"claude": "claude-opus-5-5", "copilot": "gpt-6-luna"}}}
	if !common.FillNewSteps(doc) {
		t.Fatal("a file without speccheck was not filled")
	}
	got, _ := json.Marshal(doc["defaults"].(map[string]any)["speccheck"])
	if string(got) != `{"claude":"claude-opus-5-5","copilot":"gpt-6-luna"}` {
		t.Errorf("speccheck = %s, want the reviewer's picks", got)
	}
	doc["defaults"].(map[string]any)["speccheck"] = map[string]any{"claude": "claude-haiku-5-5"}
	if common.FillNewSteps(doc) {
		t.Error("a file with its own speccheck was changed")
	}
	if s := doc["defaults"].(map[string]any)["speccheck"].(map[string]any)["claude"]; s != "claude-haiku-5-5" {
		t.Errorf("the saved speccheck pick was replaced: %v", s)
	}
	// through the loader: a user file without the step reads it filled
	dir := t.TempDir()
	user := filepath.Join(dir, "user.json")
	if err := os.WriteFile(user, []byte(`{"defaults":{"reviewer":{"claude":"claude-opus-5-5"},"evaluator":{"claude":"claude-sonnet-5-5"}},"models":{"anthropic":[]}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := common.AdminStageModel(common.LoadModelTiers(user, filepath.Join(dir, "none.json")), "speccheck", "claude"); got != "claude-opus-5-5" {
		t.Errorf("loaded speccheck = %q, want the reviewer's claude-opus-5-5", got)
	}
}

// t-864c: the Second eval step is Off until picked (a save with no pick is accepted), never the Evaluator's own pick for the agent and
// never a Haiku model; its picker offers Off first and leaves those out; a registry saved before the step loads and saves with no pick.
// Protects Admin > Model tiers saves and pickers.
func TestSecondEvalStep(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	doc := regDoc()
	d := doc["defaults"].(map[string]any)
	delete(d, "evaluator2")
	if why := common.TierDefaultsProblem(doc); why != "" {
		t.Fatalf("a registry without evaluator2 was refused: %s", why)
	}
	d["evaluator2"] = map[string]any{"claude": "", "copilot": ""}
	if why := common.TierDefaultsProblem(doc); why != "" {
		t.Fatalf("Off (no pick) was refused: %s", why)
	}
	ev := d["evaluator"].(map[string]any)
	for agent, id := range map[string]string{"claude": ev["claude"].(string), "copilot": ev["copilot"].(string)} {
		if why := common.TierPickProblem(doc, "evaluator2", agent, id); !strings.Contains(why, "same model as the Evaluator") {
			t.Errorf("%s: the Evaluator's own pick %s was accepted for Second eval (%q)", agent, id, why)
		}
		for _, o := range tierOptions(doc)["evaluator2"][agent] {
			if o.ID == id {
				t.Errorf("%s: the picker offers the Evaluator's pick %s", agent, id)
			}
		}
		if first := tierOptions(doc)["evaluator2"][agent][0]; first.ID != "" || first.Name != "Off" {
			t.Errorf("%s: the first option is %+v, want Off", agent, first)
		}
	}
	// and the Evaluator's picker never offers the Second eval's model, so a pick there can never be refused for it (reviewer Consider)
	d["evaluator2"] = map[string]any{"claude": "claude-opus-5-5"}
	for _, o := range tierOptions(doc)["evaluator"]["claude"] {
		if o.ID == "claude-opus-5-5" {
			t.Error("the Evaluator's picker offers the Second eval's model")
		}
	}
	d["evaluator2"] = map[string]any{"claude": "", "copilot": ""}
	if why := common.TierPickProblem(doc, "evaluator2", "claude", "claude-haiku-5-5"); !strings.Contains(why, "Haiku") {
		t.Errorf("a Haiku Second eval was accepted: %q", why)
	}
	if why := common.TierPickProblem(doc, "evaluator2", "copilot", "claude-haiku-4.5"); !strings.Contains(why, "Haiku") { // evaluator t-864c: the Copilot floor too
		t.Errorf("a Haiku Second eval was accepted for Copilot CLI: %q", why)
	}
	if why := common.TierPickProblem(doc, "evaluator", "claude", ""); why == "" {
		t.Error("an empty pick was accepted for a step that is not optional")
	}
	// the one reader of a pick for a shell protocol: Off prints nothing
	if got := common.AdminStageModel(doc, "evaluator2", "claude"); got != "" {
		t.Errorf("AdminStageModel(evaluator2) with Off = %q", got)
	}
}

// t-864c (user): Admin's Agent list offers Copilot CLI only when `copilot` is on PATH (checked on every options request, so one installed
// later shows the next time Admin opens), or when the person's own saved registry holds a Copilot pick that differs from the seed's.
// Protects GET /api/admin/model-tiers/options and the Agent dropdown.
func TestCopilotAgentShownOnlyWhenFound(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	seed := filepath.Join(t.TempDir(), "seed.json")
	os.WriteFile(seed, []byte(`{"defaults":{"reviewer":{"claude":"claude-sonnet-5","copilot":"claude-sonnet-5"}},"models":{"anthropic":[{"id":"claude-sonnet-5"}]}}`), 0o644)
	old, oldBin := modelTiersPath, copilotBin
	modelTiersPath, copilotBin = seed, "canon-test-no-such-copilot"
	defer func() { modelTiersPath, copilotBin = old, oldBin }()
	ids := func() string {
		out := []string{}
		for _, a := range tierOptionsView()["agents"].([]map[string]string) {
			out = append(out, a["id"])
		}
		return strings.Join(out, " ")
	}
	if got := ids(); got != "claude" {
		t.Errorf("no copilot on PATH and no saved file: agents = %q, want claude", got)
	}
	os.MkdirAll(filepath.Join(home, "cockpit"), 0o755)
	user := filepath.Join(home, "cockpit", "model-tiers.json")
	os.WriteFile(user, []byte(`{"defaults":{"reviewer":{"claude":"claude-sonnet-5","copilot":"claude-sonnet-5"}},"models":{"anthropic":[{"id":"claude-sonnet-5"}]}}`), 0o644)
	if got := ids(); got != "claude" {
		t.Errorf("a saved file with the seed's own Copilot pick: agents = %q, want claude", got)
	}
	os.WriteFile(user, []byte(`{"defaults":{"reviewer":{"claude":"claude-sonnet-5","copilot":"gpt-6-luna"}},"models":{"anthropic":[{"id":"claude-sonnet-5"}]}}`), 0o644)
	if got := ids(); got != "claude copilot" {
		t.Errorf("a Copilot pick of the person's own: agents = %q, want both", got)
	}
	os.Remove(user)
	bin := filepath.Join(t.TempDir(), "copilot")
	os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755)
	copilotBin = bin
	if got := ids(); got != "claude copilot" {
		t.Errorf("copilot found: agents = %q, want both", got)
	}
}

// t-864c reviewer Act On 1: Off after a pick goes through the real save (the spec mocks the POST, so only this reaches the board's own
// shape check, which once ran every pick through modelIDRe and refused ""). And the Evaluator can never be set to the Second eval's
// model either. Protects POST /api/admin/model-tiers.
func TestSaveSecondEvalOffAfterAPick(t *testing.T) {
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
	d := loadModelTiers()
	defs := d["defaults"].(map[string]any)
	defs["evaluator2"] = map[string]any{"claude": "claude-opus-5-5", "copilot": ""}
	if res := saveModelTiers(d); res["ok"] != true {
		t.Fatalf("a Second eval pick was refused: %v", res)
	}
	d = loadModelTiers()
	d["defaults"].(map[string]any)["evaluator2"].(map[string]any)["claude"] = ""
	if res := saveModelTiers(d); res["ok"] != true {
		t.Fatalf("Off after a pick was refused: %v", res)
	}
	if got := loadModelTiers()["defaults"].(map[string]any)["evaluator2"].(map[string]any)["claude"]; got != "" {
		t.Errorf("Off was not saved: %v", got)
	}
	d = loadModelTiers()
	d["defaults"].(map[string]any)["evaluator2"].(map[string]any)["claude"] = "claude-opus-5-5"
	d["defaults"].(map[string]any)["evaluator"].(map[string]any)["claude"] = "claude-opus-5-5"
	if res := saveModelTiers(d); res["ok"] == true || !strings.Contains(fmt.Sprint(res["error"]), "different models") {
		t.Errorf("the Evaluator set to the Second eval's model was accepted: %v", res)
	}
}

// t-864c (user): the options route lists the steps in the order a sprint runs them and numbers them (Simple / Light, used throughout,
// has no number). Protects Admin > Model tiers' card order and labels.
func TestTierStepsNumberedInRunOrder(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	got := []string{}
	for _, st := range tierOptionsView()["steps"].([]map[string]string) {
		got = append(got, st["seq"]+":"+st["id"])
	}
	if want := "1:plan 2:speccheck 3:build 4:reviewer 5:evaluator 6:evaluator2 :light"; strings.Join(got, " ") != want {
		t.Errorf("steps = %q, want %q", strings.Join(got, " "), want)
	}
}

// t-f5fa: canon's presets live in the seed only: GET /api/admin/model-tiers never sends them (also when no user file exists, so the
// seed is the doc), a save drops them, and the options route serves them resolved with the person's own after. Protects every save from
// Admin and the Preset dropdown.
func TestPresetsNeverReachTheUserFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	seedFile := filepath.Join(dir, "seed.json")
	old, oldBin := modelTiersPath, copilotBin
	modelTiersPath, copilotBin = seedFile, "canon-test-no-such-copilot"
	defer func() { modelTiersPath, copilotBin = old, oldBin }()
	doc := regDoc()
	doc["presets"] = []any{map[string]any{"id": "balanced", "name": "Balanced", "tiers": map[string]any{"plan": "top", "speccheck": "mid", "build": "mid",
		"reviewer": "mid", "evaluator": "mid", "evaluator2": "off", "light": "cheap"}}}
	raw, _ := json.Marshal(doc)
	if err := os.WriteFile(seedFile, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	get := func() map[string]any {
		w := httptest.NewRecorder()
		handleGet(w, httptest.NewRequest("GET", "/api/admin/model-tiers", nil))
		var m map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &m)
		return m
	}
	page := get() // no user file: the seed is the doc
	if _, has := page["presets"]; has {
		t.Fatal("GET sent canon's presets, so a save would copy them into the user file")
	}
	page["presets"] = doc["presets"] // a page that sent them anyway
	page["my_presets"] = []any{map[string]any{"id": "team", "name": "Team", "picks": map[string]any{"plan": map[string]any{"claude": "claude-sonnet-5-5"}}}}
	if res := saveModelTiers(page); res["ok"] != true {
		t.Fatalf("save: %v", res)
	}
	b, _ := os.ReadFile(modelTiersUserFile())
	if strings.Contains(string(b), `"presets"`) || !strings.Contains(string(b), `"my_presets"`) {
		t.Errorf("the user file = %s; want my_presets and no presets", b)
	}
	view := tierOptionsView()["presets"].([]map[string]any)
	if len(view) != 2 || view[0]["source"] != "canon" || view[1]["source"] != "yours" || view[1]["name"] != "Team" {
		t.Fatalf("presets = %v", view)
	}
	picks := view[0]["picks"].(map[string]map[string]string)
	if picks["plan"]["claude"] != "claude-opus-5-5" || picks["light"]["claude"] == "" {
		t.Errorf("Balanced resolved to %v", picks)
	}
	if _, ok := picks["plan"]["copilot"]; ok {
		t.Error("Copilot CLI is not listed here, yet the preset resolved it")
	}
	page = get()
	page["my_presets"] = []any{map[string]any{"id": "x", "name": "", "picks": map[string]any{}}}
	if res := saveModelTiers(page); res["ok"] == true || !strings.Contains(fmt.Sprint(res["error"]), "1-40 printable") {
		t.Errorf("a preset with no name was saved: %v", res)
	}
}
