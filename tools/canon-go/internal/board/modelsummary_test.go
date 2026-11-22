package board

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-2a21: `canon-go model-summary` is what `sprint start` prints as the run's preset and models, and what the ticket records as
// run_preset. The preset must be the one Admin's dropdown shows (mtPresetMatches): matched over every agent Admin lists, else Custom.
// Protects `canon-go model-summary` (sprint start's Models line, sprint approve's run_preset_build).
func TestModelSummary(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	seed, _ := filepath.Abs("../../../sprint-check-app/model-tiers.json")
	old, oldBin := modelTiersPath, copilotBin
	modelTiersPath, copilotBin = seed, "canon-test-no-such-copilot"
	defer func() { modelTiersPath, copilotBin = old, oldBin }()
	raw, err := os.ReadFile(seed)
	if err != nil {
		t.Fatal(err)
	}
	user := filepath.Join(home, "cockpit", "model-tiers.json")
	os.MkdirAll(filepath.Dir(user), 0o755)
	save := func(edit func(doc map[string]any)) {
		var doc map[string]any
		json.Unmarshal(raw, &doc)
		edit(doc)
		b, _ := json.Marshal(doc)
		os.WriteFile(user, b, 0o644)
	}
	pick := func(doc map[string]any, step, agent, id string) {
		d := doc["defaults"].(map[string]any)
		per, _ := d[step].(map[string]any)
		if per == nil {
			per = map[string]any{}
			d[step] = per
		}
		per[agent] = id
	}
	got := func(agent string) string { return strings.Join(modelSummary(agent), "\n") }
	want := func(label, agent string, lines ...string) {
		t.Helper()
		out := got(agent)
		for _, l := range lines {
			if !strings.Contains(out+"\n", l+"\n") {
				t.Errorf("%s: model-summary %s lacks %q:\n%s", label, agent, l, out)
			}
		}
	}

	// the seed's own defaults are canon's default preset; display names from the registry; Second eval Off
	want("seed", "claude", "preset\tbalanced\tBalanced", "plan\tClaude Opus 5.5", "build\tClaude Sonnet 5.5", "evaluator2\tOff")
	steps := []string{}
	for _, l := range modelSummary("claude")[1:] {
		steps = append(steps, strings.SplitN(l, "\t", 2)[0])
	}
	if got := strings.Join(steps, " "); got != "plan speccheck build reviewer evaluator evaluator2" {
		t.Errorf("seed: want the steps in run order, got %q", got)
	}
	// two presets resolving to the same picks: the first in Admin's order wins (canon's before yours)
	save(func(doc map[string]any) {
		doc["my_presets"] = []any{map[string]any{"id": "same", "name": "Same as Balanced", "picks": map[string]any{}}}
	})
	want("tie", "claude", "preset\tbalanced\tBalanced")

	// Economy for Claude Code only; Copilot is not on PATH and its column is the seed's, so Admin lists Claude Code alone: Economy
	save(func(doc map[string]any) {
		pick(doc, "plan", "claude", "claude-sonnet-5-5")
		pick(doc, "build", "claude", "claude-haiku-5-5")
	})
	want("economy, claude only", "claude", "preset\teconomy\tEconomy", "plan\tClaude Sonnet 5.5", "build\tClaude Haiku 5.5")
	// the run's own agent always counts: under Copilot its column (still Balanced) breaks the match, as Admin with both listed would
	want("economy, copilot run", "copilot", "preset\tcustom\tCustom", "plan\tClaude Opus 5.5")
	// Copilot on PATH: Admin lists both agents, so the Claude Code run is Custom too
	bin := filepath.Join(t.TempDir(), "copilot")
	os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755)
	copilotBin = bin
	want("economy, both listed", "claude", "preset\tcustom\tCustom")
	save(func(doc map[string]any) {
		for agent, ids := range map[string][2]string{"claude": {"claude-sonnet-5-5", "claude-haiku-5-5"}, "copilot": {"claude-sonnet-5.5", "claude-haiku-5.5"}} {
			pick(doc, "plan", agent, ids[0])
			pick(doc, "build", agent, ids[1])
		}
	})
	want("economy, both columns", "copilot", "preset\teconomy\tEconomy", "plan\tClaude Sonnet 5.5", "build\tClaude Haiku 5.5")
	copilotBin = "canon-test-no-such-copilot"

	// a person's preset (exact picks) matches by its own id and name
	save(func(doc map[string]any) {
		pick(doc, "evaluator", "claude", "claude-opus-5-5")
		doc["my_presets"] = []any{map[string]any{"id": "mine", "name": "My gates", "picks": map[string]any{"evaluator": map[string]any{"claude": "claude-opus-5-5"}}}}
	})
	want("my preset", "claude", "preset\tmine\tMy gates", "evaluator\tClaude Opus 5.5")
	// t-2a21 reviewer: a hand-edited id that is no plain id (a newline would reach ticket.md's frontmatter) reads as Custom
	save(func(doc map[string]any) {
		pick(doc, "evaluator", "claude", "claude-opus-5-5")
		doc["my_presets"] = []any{map[string]any{"id": "mine\nrun_agent: x", "name": "My gates", "picks": map[string]any{"evaluator": map[string]any{"claude": "claude-opus-5-5"}}}}
	})
	want("bad preset id", "claude", "preset\tcustom\tCustom")

	// a saved pick outside the option list shows as its id, and is Custom
	save(func(doc map[string]any) { pick(doc, "build", "claude", "claude-mystery-9") })
	want("unlisted pick", "claude", "preset\tcustom\tCustom", "build\tclaude-mystery-9")

	// no agent picks: pi, or anything unknown
	if out := got("pi"); out != "" {
		t.Errorf("pi: want nothing, got %q", out)
	}
	// neither file reads: nothing, never a Custom guess
	os.Remove(user)
	modelTiersPath = filepath.Join(t.TempDir(), "missing.json")
	if out := got("claude"); out != "" {
		t.Errorf("no registry: want nothing, got %q", out)
	}
}

// t-2a21 sweep: the CLI's usage and exit codes, and that it reads the seed it is given. Protects `canon-go model-summary`.
func TestModelSummaryCLI(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	seed, _ := filepath.Abs("../../../sprint-check-app/model-tiers.json")
	old := modelTiersPath
	defer func() { modelTiersPath = old }()
	var out, errb strings.Builder
	if code := modelSummaryCLI([]string{"claude"}, &out, &errb); code != 2 || !strings.Contains(errb.String(), "usage: canon-go model-summary") || out.Len() != 0 {
		t.Errorf("one argument: code %d, stderr %q, stdout %q", code, errb.String(), out.String())
	}
	modelTiersPath = filepath.Join(t.TempDir(), "elsewhere.json")
	if code := modelSummaryCLI([]string{"claude", seed}, &out, &errb); code != 0 || !strings.HasPrefix(out.String(), "preset\tbalanced\tBalanced\n") {
		t.Errorf("claude + seed: code %d, stdout %q", code, out.String())
	}
}
