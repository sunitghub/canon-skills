package common

import (
	"fmt"
	"strconv"
	"strings"
)

// t-f5fa: Admin > Model tiers presets. A canon preset (the seed's `presets`) names a tier per step: top, mid, cheap, or off for an
// optional step; a person's preset (`my_presets` in their file) holds exact picks. ResolvePreset turns either into picks per step and
// agent and says, in notes, every adjustment it made. This file is the one owner of the rule; the board serves its answer.

// presetFamilies: the families a tier tries, in order (the end of the list is "keep the current pick").
var presetFamilies = map[string][]string{
	"top":   {"opus", "sonnet", "haiku"},
	"mid":   {"sonnet", "opus", "haiku"},
	"cheap": {"haiku", "sonnet", "opus"},
}

// PresetTiers are the values a canon preset may name for a step.
var PresetTiers = map[string]bool{"top": true, "mid": true, "cheap": true, "off": true}

// modelFamily and modelVersion read a Claude model id (claude-sonnet-5-5, claude-haiku-4-5-20251001, Copilot's claude-sonnet-5.5):
// the family word and the version numbers after it (a date suffix is not part of the version).
func modelFamily(id string) string {
	p := strings.Split(strings.ToLower(id), "-")
	if len(p) < 3 || p[0] != "claude" {
		return ""
	}
	return p[1]
}

func modelVersion(id string) []int {
	var v []int
	for _, part := range strings.FieldsFunc(strings.ToLower(id), func(r rune) bool { return r == '-' || r == '.' })[2:] {
		n, err := strconv.Atoi(part)
		if err != nil || len(part) >= 8 { // a word, or a release date
			break
		}
		v = append(v, n)
	}
	return v
}

func newer(a, b []int) bool {
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return len(a) > len(b)
}

// newestOf is the newest model of a family among ids, by version (never by list order), or "".
func newestOf(ids []string, family string) string {
	best := ""
	for _, id := range ids {
		if modelFamily(id) != family || (len(strings.Split(id, "-")) < 3) {
			continue
		}
		if best == "" || newer(modelVersion(id), modelVersion(best)) {
			best = id
		}
	}
	return best
}

// PresetCandidates are the models a preset may pick for an agent: Claude Code's current (non-legacy) registry entries; Copilot CLI's own
// list (copilotIDs: every entry current), Claude models only.
func PresetCandidates(doc map[string]any, agent string, copilotIDs []string) []string {
	out := []string{}
	if agent == "copilot" {
		for _, id := range copilotIDs {
			if modelFamily(id) != "" {
				out = append(out, id)
			}
		}
		return out
	}
	models, _ := doc["models"].(map[string]any)
	list, _ := models["anthropic"].([]any)
	for _, raw := range list {
		m, _ := raw.(map[string]any)
		if id, _ := m["id"].(string); id != "" && !IsLegacy(m) {
			out = append(out, id)
		}
	}
	return out
}

// ResolvePreset gives a preset's picks for the listed agents and the notes on what it adjusted. The preset is checked as a whole: its
// own picks are put in a copy of doc's defaults and run through the save's rules (TierDefaultsProblem's per-pick rule, TierPickProblem);
// a Second eval equal to the Evaluator becomes Off, any other refused pick keeps the step's current pick.
func ResolvePreset(doc, preset map[string]any, agents []string, copilotIDs map[string][]string) (map[string]map[string]string, []string) {
	defaults, _ := doc["defaults"].(map[string]any)
	cur := func(step, agent string) string {
		per, _ := defaults[step].(map[string]any)
		s, _ := per[agent].(string)
		return s
	}
	tiers, _ := preset["tiers"].(map[string]any)
	exact, _ := preset["picks"].(map[string]any)
	picks := map[string]map[string]string{}
	notes := []string{}
	note := func(agent, step, text string) {
		notes = append(notes, TierAgentLabel[agent]+" · "+TierStepLabel[step]+": "+text)
	}
	for _, step := range TierSteps {
		picks[step] = map[string]string{}
		for _, agent := range agents {
			if exact != nil { // a person's preset: exact picks
				per, _ := exact[step].(map[string]any)
				s, ok := per[agent].(string)
				if !ok {
					s = cur(step, agent)
				}
				picks[step][agent] = s
				continue
			}
			tier, _ := tiers[step].(string)
			if tier == "off" && TierStepOptional[step] {
				picks[step][agent] = ""
				continue
			}
			cands := PresetCandidates(doc, agent, copilotIDs[agent])
			got := ""
			for i, fam := range presetFamilies[tier] {
				if fam == "haiku" && (step == "evaluator" || step == "evaluator2") {
					continue // the evaluators are never a Haiku model
				}
				if got = newestOf(cands, fam); got != "" {
					if i > 0 {
						note(agent, step, "no "+presetFamilies[tier][0]+" model, so "+got)
					}
					break
				}
			}
			if got == "" {
				got = cur(step, agent)
				note(agent, step, "no model for "+tier+", so it keeps "+orOff(got))
			}
			picks[step][agent] = got
		}
	}
	// the preset as a whole, by the save's own rules
	trial := map[string]any{}
	for k, v := range doc {
		trial[k] = v
	}
	td := map[string]any{}
	for step, per := range defaults {
		td[step] = per
	}
	for step, per := range picks {
		m := map[string]any{}
		if old, ok := defaults[step].(map[string]any); ok {
			for a, v := range old {
				m[a] = v
			}
		}
		for a, v := range per {
			m[a] = v
		}
		td[step] = m
	}
	trial["defaults"] = td
	for _, agent := range agents {
		if picks["evaluator2"][agent] != "" && picks["evaluator2"][agent] == picks["evaluator"][agent] {
			picks["evaluator2"][agent] = ""
			td["evaluator2"].(map[string]any)[agent] = ""
			note(agent, "evaluator2", "the same model as the Evaluator, so Off")
		}
	}
	for _, step := range TierSteps {
		for _, agent := range agents {
			if why := TierPickProblem(trial, step, agent, picks[step][agent]); why != "" {
				keep := cur(step, agent)
				note(agent, step, why+"; it keeps "+orOff(keep))
				picks[step][agent] = keep
				td[step].(map[string]any)[agent] = keep
			}
		}
	}
	return picks, notes
}

func orOff(id string) string {
	if id == "" {
		return "Off"
	}
	return id
}

// MyPresetsProblem names the first problem with a person's saved presets (`my_presets`), or "": at most 20, each with an id, a name of
// 1-40 printable characters and picks only for known steps and agents, every pick one the save accepts.
func MyPresetsProblem(doc map[string]any) string {
	raw, ok := doc["my_presets"]
	if !ok || raw == nil {
		return ""
	}
	list, ok := raw.([]any)
	if !ok {
		return "my_presets must be a list"
	}
	if len(list) > 20 {
		return fmt.Sprintf("my_presets holds %d presets; at most 20", len(list))
	}
	for i, r := range list {
		p, _ := r.(map[string]any)
		name, _ := p["name"].(string)
		id, _ := p["id"].(string)
		if !ModelIDRe.MatchString(id) {
			return fmt.Sprintf("my_presets[%d] needs an id of letters, digits, '.', '_' or '-'", i)
		}
		if n := len([]rune(name)); n < 1 || n > 40 || strings.IndexFunc(name, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0 {
			return fmt.Sprintf("my_presets[%d] needs a name of 1-40 printable characters", i)
		}
		picks, _ := p["picks"].(map[string]any)
		for step, perRaw := range picks {
			if TierStepLabel[step] == "" {
				return fmt.Sprintf("my_presets %q: unknown step %s", name, step)
			}
			per, _ := perRaw.(map[string]any)
			for agent, v := range per {
				s, _ := v.(string)
				if TierAgentLabel[agent] == "" {
					return fmt.Sprintf("my_presets %q: unknown agent %s", name, agent)
				}
				if why := TierPickProblem(doc, step, agent, s); why != "" && !(TierStepOptional[step] && s == "") {
					if !strings.Contains(why, "same model as") { // the evaluators' pairing is checked on the preset as a whole when applied
						return fmt.Sprintf("my_presets %q: %s", name, TierSlot(step+"."+agent)+": "+why)
					}
				}
			}
		}
	}
	return ""
}
