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
	parts := strings.FieldsFunc(strings.ToLower(id), func(r rune) bool { return r == '-' || r == '.' })
	if len(parts) < 3 {
		return nil // not claude-<family>-<version>: no version (also "")
	}
	for _, part := range parts[2:] {
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

// newestOf is the newest model of a family among ids, by version (never by list order), or "". ok filters the ids (the save's own rule).
func newestOf(ids []string, family string, ok func(string) bool) string {
	best := ""
	for _, id := range ids {
		if modelFamily(id) != family || !ok(id) {
			continue
		}
		// newest by version; a tie (claude-opus-4-5 beside its dated claude-opus-4-5-20251101) goes to the shorter id, never to list order
		if a, b := modelVersion(id), modelVersion(best); best == "" || newer(a, b) || (!newer(b, a) && (len(id) < len(best) || (len(id) == len(best) && id < best))) {
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

// ResolvePreset gives a preset's picks for the listed agents and the notes on what it adjusted. One rule decides what a step may take: the
// save's own (TierPickProblem). A candidate is tried against the floors only (a doc without the two evaluators' picks, so their pairing
// does not skip a family); then the preset is checked as a whole: a Second eval equal to the Evaluator becomes Off, and any pick the save
// would refuse keeps the step's current pick (Off for an optional step whose current pick is refused too).
func ResolvePreset(doc, preset map[string]any, agents []string, copilotIDs map[string][]string) (map[string]map[string]string, []string) {
	defaults, _ := doc["defaults"].(map[string]any)
	cur := func(step, agent string) string {
		per, _ := defaults[step].(map[string]any)
		s, _ := per[agent].(string)
		return s
	}
	floors := map[string]any{}
	for k, v := range doc {
		floors[k] = v
	}
	fd := map[string]any{}
	for step, per := range defaults {
		if step != "evaluator" && step != "evaluator2" {
			fd[step] = per
		}
	}
	floors["defaults"] = fd
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
			if exact != nil { // a person's preset: exact picks (a step it does not name keeps the current pick)
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
			allowed := func(id string) bool { return TierPickProblem(floors, step, agent, id) == "" }
			got := ""
			for i, fam := range presetFamilies[tier] {
				if got = newestOf(cands, fam, allowed); got != "" {
					if i > 0 {
						note(agent, step, "no "+presetFamilies[tier][0]+" model, so "+got)
					}
					break
				}
			}
			if got == "" {
				got = cur(step, agent)
				note(agent, step, "no model for "+orOff(tier)+", so it keeps "+orOff(got))
			}
			picks[step][agent] = got
		}
	}
	// the preset as a whole, by the save's own rules, until it is stable
	trial := map[string]any{}
	for k, v := range doc {
		trial[k] = v
	}
	td := map[string]any{}
	for step, per := range defaults {
		m := map[string]any{}
		if old, ok := per.(map[string]any); ok {
			for a, v := range old {
				m[a] = v
			}
		}
		td[step] = m
	}
	for step, per := range picks {
		if _, ok := td[step]; !ok {
			td[step] = map[string]any{}
		}
		for a, v := range per {
			td[step].(map[string]any)[a] = v
		}
	}
	trial["defaults"] = td
	set := func(step, agent, v string) { picks[step][agent] = v; td[step].(map[string]any)[agent] = v }
	for _, agent := range agents {
		if e2 := picks["evaluator2"][agent]; e2 != "" && e2 == picks["evaluator"][agent] {
			set("evaluator2", agent, "")
			note(agent, "evaluator2", "the same model as the Evaluator, so Off")
		}
	}
	// one pass is enough: TierSteps checks the Evaluator before the Second eval (the only pick that depends on another), and a kept pick
	// is checked again on the spot (else Off for an optional step)
	for _, step := range TierSteps {
		for _, agent := range agents {
			if why := TierPickProblem(trial, step, agent, picks[step][agent]); why != "" {
				keep := cur(step, agent)
				if keep == picks[step][agent] || TierPickProblem(trial, step, agent, keep) != "" {
					keep = map[bool]string{true: "", false: keep}[TierStepOptional[step]]
				}
				note(agent, step, why+"; it keeps "+orOff(keep))
				set(step, agent, keep)
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

// MyPresetsProblem names the first problem with the SHAPE of a person's saved presets (`my_presets`), or "": at most 20, each with a
// unique id (never one of reserved: canon's own preset ids), a name of 1-40 printable characters, and picks (a map) only for known steps
// and agents, each a model id or "" (Off). Whether a pick is still a model the save accepts is decided when the preset is applied
// (ResolvePreset keeps the current pick and says so), so a model retired or removed later never blocks an unrelated save (t-f5fa reviewer).
func MyPresetsProblem(doc map[string]any, reserved []string) string {
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
	seen := map[string]bool{}
	for _, r := range reserved {
		seen[r] = true
	}
	for i, r := range list {
		p, _ := r.(map[string]any)
		name, _ := p["name"].(string)
		id, _ := p["id"].(string)
		if !ModelIDRe.MatchString(id) {
			return fmt.Sprintf("my_presets[%d] needs an id of letters, digits, '.', '_' or '-'", i)
		}
		if seen[id] {
			return fmt.Sprintf("my_presets[%d]: the id %s is already used", i, id)
		}
		seen[id] = true
		if n := len([]rune(name)); n < 1 || n > 40 || strings.IndexFunc(name, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0 {
			return fmt.Sprintf("my_presets[%d] needs a name of 1-40 printable characters", i)
		}
		picks, ok := p["picks"].(map[string]any)
		if !ok {
			return fmt.Sprintf("my_presets %q needs its picks", name)
		}
		for step, perRaw := range picks {
			if TierStepLabel[step] == "" {
				return fmt.Sprintf("my_presets %q: unknown step %s", name, step)
			}
			per, ok := perRaw.(map[string]any)
			if !ok {
				return fmt.Sprintf("my_presets %q: %s must hold a pick per agent", name, step)
			}
			for agent, v := range per {
				s, isText := v.(string)
				if TierAgentLabel[agent] == "" {
					return fmt.Sprintf("my_presets %q: unknown agent %s", name, agent)
				}
				if !isText || (s != "" && !ModelValueRe.MatchString(s)) {
					return fmt.Sprintf("my_presets %q: %s for %s is not a model id", name, TierStepLabel[step], TierAgentLabel[agent])
				}
			}
		}
	}
	return ""
}
