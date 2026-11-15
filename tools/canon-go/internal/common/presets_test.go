package common

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// presetDoc is a registry whose model list is deliberately shuffled (older before newer) and holds a legacy entry.
func presetDoc() map[string]any {
	var doc map[string]any
	_ = json.Unmarshal([]byte(`{
	 "defaults": {"plan": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"}, "speccheck": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"},
	  "build": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"}, "reviewer": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"},
	  "evaluator": {"claude": "claude-sonnet-5", "copilot": "claude-sonnet-5"}, "evaluator2": {}, "light": {"claude": "claude-haiku-5-5", "copilot": "claude-haiku-4.5"}},
	 "models": {"anthropic": [{"id": "claude-haiku-4-5-20251001", "alias": "haiku"}, {"id": "claude-sonnet-5", "alias": "sonnet"}, {"id": "claude-opus-6-0", "legacy": true},
	  {"id": "claude-haiku-5-5"}, {"id": "claude-opus-5-5", "alias": "opus"}, {"id": "claude-sonnet-5-5"}]}}`), &doc)
	return doc
}

func preset(t map[string]string) map[string]any {
	m := map[string]any{}
	for k, v := range t {
		m[k] = v
	}
	return map[string]any{"id": "p", "name": "P", "tiers": m}
}

// t-f5fa: a tier is the newest model of its family by version (never list order, never a legacy entry); the evaluators skip Haiku; a
// Copilot list without a family falls back in the fixed order with a note; a Second eval equal to the Evaluator is Off.
// Protects GET /api/admin/model-tiers/options' presets, which Admin applies.
func TestResolvePresetTiers(t *testing.T) {
	doc := presetDoc()
	all := map[string]string{"plan": "top", "speccheck": "mid", "build": "cheap", "reviewer": "mid", "evaluator": "cheap", "evaluator2": "mid", "light": "cheap"}
	picks, notes := ResolvePreset(doc, preset(all), []string{"claude", "copilot"},
		map[string][]string{"copilot": {"claude-haiku-4.5", "claude-sonnet-5", "claude-sonnet-5.5", "claude-haiku-5.5", "gpt-6-luna"}})
	want := map[string][2]string{
		"plan":       {"claude-opus-5-5", "claude-sonnet-5.5"},   // Copilot has no Opus: the next family down
		"speccheck":  {"claude-sonnet-5-5", "claude-sonnet-5.5"}, // newest by version, though listed after sonnet-5
		"build":      {"claude-haiku-5-5", "claude-haiku-5.5"},
		"reviewer":   {"claude-sonnet-5-5", "claude-sonnet-5.5"},
		"evaluator":  {"claude-sonnet-5-5", "claude-sonnet-5.5"}, // cheap, but never Haiku: the next family
		"evaluator2": {"", ""},                                   // equal to the Evaluator: Off
		"light":      {"claude-haiku-5-5", "claude-haiku-5.5"},
	}
	for step, w := range want {
		if picks[step]["claude"] != w[0] || picks[step]["copilot"] != w[1] {
			t.Errorf("%s = %v, want claude %s, copilot %s", step, picks[step], w[0], w[1])
		}
	}
	text := strings.Join(notes, "\n")
	for _, n := range []string{"Copilot CLI · Plan: no opus model, so claude-sonnet-5.5", "Claude Code · Second eval: the same model as the Evaluator, so Off",
		"Claude Code · Evaluator: no haiku model, so claude-sonnet-5-5"} {
		if !strings.Contains(text, n) {
			t.Errorf("notes lack %q:\n%s", n, text)
		}
	}
	if strings.Contains(text, "claude-opus-6-0") || picks["plan"]["claude"] == "claude-opus-6-0" {
		t.Error("a legacy model was picked")
	}
}

// t-f5fa: the end of the fallback: no model in any family keeps the step's current pick (noted); only the listed agents are resolved; a
// person's preset gives exact picks, still checked as a whole.
func TestResolvePresetEnds(t *testing.T) {
	doc := presetDoc()
	doc["models"] = map[string]any{"anthropic": []any{map[string]any{"id": "claude-haiku-5-5"}}}
	picks, notes := ResolvePreset(doc, preset(map[string]string{"plan": "top", "evaluator": "top"}), []string{"claude"}, nil)
	if picks["plan"]["claude"] != "claude-haiku-5-5" {
		t.Errorf("top with only a Haiku model = %q, want the Haiku (last in the order)", picks["plan"]["claude"])
	}
	if picks["evaluator"]["claude"] != "claude-sonnet-5" || !strings.Contains(strings.Join(notes, "\n"), "Evaluator: no model for top, so it keeps claude-sonnet-5") {
		t.Errorf("an evaluator with only Haiku = %q (notes %v), want the current pick kept", picks["evaluator"]["claude"], notes)
	}
	if _, ok := picks["plan"]["copilot"]; ok {
		t.Error("an agent Admin does not list was resolved")
	}
	mine := map[string]any{"id": "m", "name": "Mine", "picks": map[string]any{"evaluator": map[string]any{"claude": "claude-sonnet-5"}, "evaluator2": map[string]any{"claude": "claude-sonnet-5"}}}
	picks, notes = ResolvePreset(presetDoc(), mine, []string{"claude"}, nil)
	if picks["evaluator2"]["claude"] != "" || !strings.Contains(strings.Join(notes, "\n"), "Second eval: the same model as the Evaluator, so Off") {
		t.Errorf("a saved preset with both evaluators on one model = %v %v", picks["evaluator2"], notes)
	}
}

// t-f5fa: my_presets is checked on save: at most 20, a name of 1-40 printable characters, known steps and agents, picks the save accepts.
func TestMyPresetsProblem(t *testing.T) {
	doc := presetDoc()
	ok := []any{map[string]any{"id": "team", "name": "Team default", "picks": map[string]any{"plan": map[string]any{"claude": "claude-opus-5-5"}, "evaluator2": map[string]any{"claude": ""}}}}
	doc["my_presets"] = ok
	if why := MyPresetsProblem(doc); why != "" {
		t.Fatalf("a good preset was refused: %s", why)
	}
	for name, bad := range map[string]any{
		"no name":      []any{map[string]any{"id": "x", "name": "", "picks": map[string]any{}}},
		"control char": []any{map[string]any{"id": "x", "name": "a\x1bb", "picks": map[string]any{}}},
		"long name":    []any{map[string]any{"id": "x", "name": strings.Repeat("n", 41), "picks": map[string]any{}}},
		"bad id":       []any{map[string]any{"id": "../x", "name": "n", "picks": map[string]any{}}},
		"unknown step": []any{map[string]any{"id": "x", "name": "n", "picks": map[string]any{"deploy": map[string]any{"claude": "claude-opus-5-5"}}}},
		"haiku eval":   []any{map[string]any{"id": "x", "name": "n", "picks": map[string]any{"evaluator": map[string]any{"claude": "claude-haiku-5-5"}}}},
		"not a list":   map[string]any{},
	} {
		doc["my_presets"] = bad
		if MyPresetsProblem(doc) == "" {
			t.Errorf("%s: accepted", name)
		}
	}
	many := []any{}
	for i := 0; i < 21; i++ {
		many = append(many, ok[0])
	}
	doc["my_presets"] = many
	if MyPresetsProblem(doc) == "" {
		t.Error("21 presets were accepted")
	}
}

// t-f5fa: the seed's presets name only known steps and tiers (off only on an optional step). Protects every install's Preset dropdown.
func TestSeedPresetsWellFormed(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "sprint-check-app", "model-tiers.json"))
	if err != nil {
		t.Fatal(err)
	}
	var seed map[string]any
	if err := json.Unmarshal(raw, &seed); err != nil {
		t.Fatal(err)
	}
	list, _ := seed["presets"].([]any)
	if len(list) != 4 {
		t.Fatalf("the seed has %d presets, want the four starters", len(list))
	}
	for _, r := range list {
		p := r.(map[string]any)
		for step, tv := range p["tiers"].(map[string]any) {
			tier, _ := tv.(string)
			if TierStepLabel[step] == "" || !PresetTiers[tier] || (tier == "off" && !TierStepOptional[step]) {
				t.Errorf("preset %v: step %s tier %q", p["id"], step, tier)
			}
		}
		if len(p["tiers"].(map[string]any)) != len(TierSteps) {
			t.Errorf("preset %v does not name every step", p["id"])
		}
	}
}
