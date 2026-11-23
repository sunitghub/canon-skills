package board

import (
	"fmt"
	"io"
	"os"

	"canon/internal/common"
)

// t-2a21: `canon-go model-summary <agent> <seed>`: the preset and the models one agent's run uses, for `sprint start`'s Models line and
// the ticket's run_preset. The preset is the one Admin's dropdown shows (presetMatches, cockpit-admin.js's mtPresetMatches): the first,
// in Admin's list order, whose resolved picks equal the saved ones for every agent Admin lists, else Custom. Admin's in-page "last
// applied" tie-break is page state and is not reproduced.

// modelSummarySteps are the steps the Models line names, in the order a sprint runs them (Simple / Light work is not one run step).
var modelSummarySteps = []string{"plan", "speccheck", "build", "close", "reviewer", "evaluator", "evaluator2"}

// presetMatches is mtPresetMatches: for every listed agent, every step the preset's picks name for that agent equals the saved pick.
func presetMatches(picks map[string]map[string]string, defaults map[string]any, agents []string) bool {
	for _, agent := range agents {
		for step, per := range picks {
			want, named := per[agent]
			if !named {
				continue
			}
			saved, _ := defaults[step].(map[string]any)
			got, _ := saved[agent].(string)
			if got != want {
				return false
			}
		}
	}
	return true
}

// modelSummary returns "preset\t<id|custom>\t<name|Custom>" then "<step>\t<display name|Off>" per modelSummarySteps, or nil for an
// agent with no picks (pi, anything else) or when neither the user's file nor the seed can be read (never a guess).
func modelSummary(agent string) []string {
	if common.TierAgentLabel[agent] == "" {
		return nil
	}
	readable := false
	for _, p := range []string{modelTiersUserFile(), modelTiersPath} {
		if _, err := os.ReadFile(p); err == nil {
			readable = true
		}
	}
	if !readable {
		return nil
	}
	doc := loadModelTiers()
	agents, ids := []map[string]string{}, []string{}
	for _, a := range common.TierAgents {
		if a == agent || a != "copilot" || copilotAgentShown(doc) { // the run's own agent always counts; else Admin's list
			agents = append(agents, map[string]string{"id": a, "label": common.TierAgentLabel[a]})
			ids = append(ids, a)
		}
	}
	defaults, _ := doc["defaults"].(map[string]any)
	out := []string{"preset\tcustom\tCustom"}
	for _, p := range presetsView(doc, agents) {
		picks, _ := p["picks"].(map[string]map[string]string)
		// a hand-edited my_presets id is shape-checked only on save: one that is no plain id never reaches the ticket (Custom instead)
		if id, _ := p["id"].(string); presetMatches(picks, defaults, ids) && common.ModelIDRe.MatchString(id) && len(id) <= 40 {
			out[0] = fmt.Sprintf("preset\t%s\t%v", id, p["name"])
			break
		}
	}
	opts := tierOptions(doc)
	for _, step := range modelSummarySteps {
		per, _ := defaults[step].(map[string]any)
		id, _ := per[agent].(string)
		name := "Off"
		if id != "" {
			name = id
			for _, o := range opts[step][agent] {
				if o.ID == id {
					name = o.Name
					break
				}
			}
		}
		out = append(out, step+"\t"+name)
	}
	return out
}

func modelSummaryCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) != 2 {
		fmt.Fprintln(stderr, "usage: canon-go model-summary <agent> <seed model-tiers.json>")
		return 2
	}
	modelTiersPath = args[1]
	for _, line := range modelSummary(args[0]) {
		fmt.Fprintln(stdout, line)
	}
	return 0
}
