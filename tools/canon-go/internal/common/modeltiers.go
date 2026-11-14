package common

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// t-3425: the model registry's one owner for every reader: the board (its routes, audit, retire/remove, Admin's options) and the
// daemon (which model a Cockpit session starts on). The registry is $CANON_HOME/cockpit/model-tiers.json, else the install's seed
// tools/sprint-check-app/model-tiers.json: {"defaults": {step: {agent: id}}, "models": {provider: [entry...]}, "copilot_models": [...]}.

// ModelIDRe is what a model id or alias may look like: it reaches a command line and a file name (t-7e36).
var ModelIDRe = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// ModelValueRe is the guard on a value that becomes an agent's --model argv element (t-3425 moved it here from the daemon): it must START
// with a letter or digit, so `--model --dangerously-skip-permissions` can never be built from a file the configured agent can write.
var ModelValueRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// t-8f6d + t-2cc8: the registry's defaults are one model id per step and agent: defaults.<step>.<agent>. This table is their one owner
// (validation, the migration, retire/remove, the Refresh flag, the audit names and the Pipeline rows read it; static/cockpit-admin.js
// mirrors it for the cards). A claude pick is an Anthropic model; a copilot pick is an Anthropic or an OpenAI model (Copilot CLI runs both).
var (
	TierSteps     = []string{"plan", "build", "speccheck", "reviewer", "evaluator", "evaluator2", "light"}
	TierAgents    = []string{"claude", "copilot"}
	TierStepLabel = map[string]string{"plan": "Plan", "build": "Build", "speccheck": "Spec check", "reviewer": "Reviewer", "evaluator": "Evaluator", "evaluator2": "Second eval", "light": "Simple / Light work"}
	TierStepRole  = map[string]string{"speccheck": "advisory", "reviewer": "advisory", "evaluator": "binding", "evaluator2": "advisory"} // shown after the label in Admin
	// TierStepChecks: the step whose work this one checks (t-3425): Admin notes a checker picked the same as the maker (never blocks).
	// t-9b13: the spec check grades the plan, so it is compared with Plan.
	TierStepChecks = map[string]string{"speccheck": "plan", "reviewer": "build", "evaluator": "build"}
	// GateAgentStep: the Admin step that picks each gate agent's model (t-9b13), so a page never guesses it from the agent's role
	GateAgentStep = map[string]string{"canon-spec-checker": "speccheck", "canon-reviewer": "reviewer", "canon-evaluator": "evaluator"}
	// TierStepFrom: a step added after a registry was saved starts from this step's picks (t-9b13: the spec check from the Reviewer's)
	TierStepFrom   = map[string]string{"speccheck": "reviewer"}
	TierAgentLabel = map[string]string{"claude": "Claude Code", "copilot": "Copilot CLI"}
	// TierStepOptional: a step whose "no pick" means Off (t-864c: the second evaluator runs only once a model is picked)
	TierStepOptional = map[string]bool{"evaluator2": true}
)

// RegistryAgent is the agent whose picks are registry ids (models.anthropic): registry moves (retire, remove, the Refresh flag) touch
// its picks only. A Copilot CLI pick is Copilot's own id (t-aba6), another id space, even where the two spell a model the same way.
const RegistryAgent = "claude"

// CopilotFormOf is a registry id in Copilot's spelling: the two version numbers joined by a dot and a release date dropped
// (claude-sonnet-5-5 -> claude-sonnet-5.5, claude-haiku-4-5-20251001 -> claude-haiku-4.5); an id with one version number
// (claude-sonnet-5, gpt-6-luna) is the same in both. A pure function of the string (tests/model-registry-parity.sh spells the same rule).
var registryVersionRe = regexp.MustCompile(`^(claude-[a-z]+-[0-9]+)-([0-9]+)(-[0-9]{8})?$`)

func CopilotFormOf(id string) string { return registryVersionRe.ReplaceAllString(id, "$1.$2") }

// AliasOf is an entry's alias, trimmed; a missing or null alias is "".
func AliasOf(m map[string]any) string { a, _ := m["alias"].(string); return strings.TrimSpace(a) }

// RegistryModel finds an entry by id across providers.
func RegistryModel(doc map[string]any, id string) (prov string, entry map[string]any) {
	models, _ := doc["models"].(map[string]any)
	for p, raw := range models {
		list, _ := raw.([]any)
		for _, e := range list {
			if m, ok := e.(map[string]any); ok && fmt.Sprint(m["id"]) == id {
				return p, m
			}
		}
	}
	return "", nil
}

func IsLegacy(m map[string]any) bool { b, _ := m["legacy"].(bool); return b }

// HaikuClass: a Haiku model (its alias is haiku, or its id names haiku). The binding evaluator is never one, under any agent (user,
// 2026-11-14); a Lite ticket's forced Haiku evaluator is a per-ticket rule at close, not a default.
func HaikuClass(id string, m map[string]any) bool {
	return strings.EqualFold(AliasOf(m), "haiku") || strings.Contains(strings.ToLower(id), "haiku")
}

// MigrateTierDefaults rewrites a registry saved before the reshape (defaults.eval and defaults.light by provider) in memory: the old
// Review & Eval pick becomes the reviewer and the evaluator for both agents, the old light pick the light for both, plan and build come
// from the seed's defaults. Every carried pick must pass today's rules (a model the agent can run, not legacy, never a Haiku evaluator):
// one that does not takes the seed's pick, so a migrated file never fails validation and locks Admin. The OpenAI picks drove nothing
// and are dropped (the models stay in models.openai). A file that already has new-shape steps (an old board saved over a new file) keeps
// them and only loses its old keys. A document in the new shape is left as it is. Returns whether it changed anything; the file on
// disk changes only on the next save.
func MigrateTierDefaults(doc, seed map[string]any) bool {
	d, _ := doc["defaults"].(map[string]any)
	if d == nil {
		return false
	}
	_, hasEval := d["eval"]
	light, _ := d["light"].(map[string]any)
	_, lightOld := light["anthropic"]
	_, lightOldO := light["openai"]
	if !hasEval && !lightOld && !lightOldO {
		return false
	}
	old := func(tier string) string {
		per, _ := d[tier].(map[string]any)
		id, _ := per["anthropic"].(string)
		return id
	}
	sd, _ := seed["defaults"].(map[string]any)
	seedPick := func(step, agent string) string {
		per, _ := sd[step].(map[string]any)
		id, _ := per[agent].(string)
		return id
	}
	out := map[string]any{}
	for _, step := range TierSteps {
		cur, _ := d[step].(map[string]any)
		per := map[string]any{}
		for _, agent := range TierAgents {
			if v, _ := cur[agent].(string); v != "" { // a new-shape pick already there (a mixed file) wins
				per[agent] = v
				continue
			}
			id, src := "", step
			if f := TierStepFrom[step]; f != "" { // a later step starts from the step it was copied from (t-9b13)
				src = f
			}
			switch src {
			case "reviewer", "evaluator":
				id = old("eval")
			case "light":
				id = old("light")
			}
			if agent == "copilot" { // t-aba6: a Copilot pick is Copilot's own id
				id = CopilotFormOf(id)
			}
			if id = FirstUsablePick(doc, step, agent, id, seedPick(step, agent)); id != "" {
				per[agent] = id
			}
		}
		out[step] = per
	}
	doc["defaults"] = out
	return true
}

// TierPickProblem says why one default cannot hold id, or "": a Claude Code pick is an active Anthropic model of the registry; a Copilot
// CLI pick is one of Copilot's own ids (t-aba6), a Claude or GPT model. Which Copilot models an account offers decides what Admin lists
// (tierOptions), never whether a saved pick is valid: a pick from another account, or one Copilot later drops, stays saved and shown.
// The binding evaluator is never a Haiku model under either agent (user, 2026-11-14).
func TierPickProblem(doc map[string]any, step, agent, id string) string {
	if id == "" && TierStepOptional[step] { // Off (t-864c)
		return ""
	}
	if step == "evaluator2" { // t-864c: a second opinion on another model: never the Evaluator's own pick for this agent
		defaults, _ := doc["defaults"].(map[string]any)
		ev, _ := defaults["evaluator"].(map[string]any)
		if cur, _ := ev[agent].(string); cur != "" && cur == id {
			return "the same model as the Evaluator default for " + TierAgentLabel[agent] + "; a second opinion needs another model (or Off)"
		}
	}
	if agent == "copilot" {
		switch {
		case !ModelIDRe.MatchString(id) || CopilotGroup(id) == "":
			return id + " is not a Claude or GPT model id"
		case (step == "evaluator" || step == "evaluator2") && HaikuClass(id, nil):
			return "the binding evaluator is never a Haiku model"
		}
		return ""
	}
	prov, m := RegistryModel(doc, id)
	switch {
	case m == nil:
		return id + " is not in the registry"
	case IsLegacy(m):
		return id + " is legacy"
	case prov != "anthropic":
		return id + " is an " + map[string]string{"anthropic": "Anthropic", "openai": "OpenAI"}[prov] + " model, which " + TierAgentLabel[agent] + " cannot run"
	case (step == "evaluator" || step == "evaluator2") && HaikuClass(id, m):
		return "the binding evaluator is never a Haiku model"
	}
	return ""
}

// TierDefaultsProblem names the first default a save cannot hold ("the Evaluator default for Claude Code: ..."), or "" when all are
// fine: the refusal a person reads in Admin.
func TierDefaultsProblem(data map[string]any) string {
	defaults, _ := data["defaults"].(map[string]any)
	steps := make([]string, 0, len(defaults))
	for step := range defaults {
		steps = append(steps, step)
	}
	slices.Sort(steps)
	for _, step := range steps {
		if TierStepLabel[step] == "" {
			return "defaults: unknown step " + step + " (steps: " + strings.Join(TierSteps, ", ") + ")"
		}
		per, _ := defaults[step].(map[string]any)
		agents := make([]string, 0, len(per))
		for agent := range per {
			agents = append(agents, agent)
		}
		slices.Sort(agents)
		for _, agent := range agents {
			if TierAgentLabel[agent] == "" {
				return "defaults." + step + ": unknown agent " + agent + " (agents: " + strings.Join(TierAgents, ", ") + ")"
			}
			if why := TierPickProblem(data, step, agent, fmt.Sprint(per[agent])); why != "" {
				return TierSlot(step+"."+agent) + ": " + why
			}
		}
	}
	return ""
}

// MigrateCopilotPicks (t-aba6): a registry saved before Copilot picks were Copilot's own ids may hold registry spellings there. Each is
// respelled once (CopilotFormOf); nothing is dropped, and Copilot's current list plays no part (it decides only what Admin offers), so
// the result is the same on every read. Returns whether it changed anything; the file changes on the next save.
func MigrateCopilotPicks(doc map[string]any) bool {
	d, _ := doc["defaults"].(map[string]any)
	changed := false
	for _, step := range TierSteps {
		per, _ := d[step].(map[string]any)
		cur, _ := per["copilot"].(string)
		if next := CopilotFormOf(cur); per != nil && next != cur {
			per["copilot"] = next
			changed = true
		}
	}
	return changed
}

// FirstUsablePick is the first of ids one default may hold today (TierPickProblem), or "": the one fallback rule both migrations use.
func FirstUsablePick(doc map[string]any, step, agent string, ids ...string) string {
	for _, id := range ids {
		if id != "" && TierPickProblem(doc, step, agent, id) == "" {
			return id
		}
	}
	return ""
}

// TierSlot names one default for a person: "the Evaluator default for Claude Code".
func TierSlot(slot string) string {
	step, agent, _ := strings.Cut(slot, ".")
	return "the " + TierStepLabel[step] + " default for " + TierAgentLabel[agent]
}

// CopilotGroup is a Copilot model's family, the one owner of the rule (user, 2026-11-14: Anthropic and OpenAI models only): "Anthropic"
// for claude-*, "OpenAI" for gpt-*, "" for any other (not a Copilot CLI pick canon offers or keeps). Admin lists models under it.
func CopilotGroup(id string) string {
	switch {
	case strings.HasPrefix(id, "claude-"):
		return "Anthropic"
	case strings.HasPrefix(id, "gpt-"):
		return "OpenAI"
	}
	return ""
}

// ModelTiersUserFile is the person's copy of the registry: $CANON_HOME/cockpit/model-tiers.json (default ~/.canon/cockpit).
func ModelTiersUserFile() string {
	home := os.Getenv("CANON_HOME")
	if home == "" {
		h, _ := os.UserHomeDir()
		home = filepath.Join(h, ".canon")
	}
	return filepath.Join(home, "cockpit", "model-tiers.json")
}

// FillNewSteps (t-9b13) gives a registry saved before a step existed that step's picks, copied from TierStepFrom's step (written so on
// its next save). A step with any pick of its own is left alone. Reports whether it changed doc.
func FillNewSteps(doc map[string]any) bool {
	d, _ := doc["defaults"].(map[string]any)
	if d == nil {
		return false
	}
	changed := false
	for step, from := range TierStepFrom {
		if _, ok := d[step]; ok {
			continue
		}
		src, _ := d[from].(map[string]any)
		per := map[string]any{}
		for _, agent := range TierAgents {
			if v, _ := src[agent].(string); v != "" {
				per[agent] = v
			}
		}
		d[step], changed = per, true
	}
	return changed
}

// LoadModelTiers reads the registry: the person's copy (userFile) when it parses, else the seed (seedFile); a copy saved before a
// key existed gets the seed's (sources, copilot_models), and an old shape is read migrated (written so on its next save). Read-only.
func LoadModelTiers(userFile, seedFile string) map[string]any {
	empty := map[string]any{
		"defaults": map[string]any{"plan": map[string]any{}, "build": map[string]any{}, "reviewer": map[string]any{}, "evaluator": map[string]any{}, "light": map[string]any{}},
		"models":   map[string]any{"anthropic": []any{}, "openai": []any{}},
	}
	var found []map[string]any
	for _, p := range []string{userFile, seedFile} {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var parsed map[string]any
		if json.Unmarshal(data, &parsed) == nil && parsed != nil {
			found = append(found, parsed)
		}
	}
	if len(found) == 0 {
		return empty
	}
	// t-d40b: the same for the Refresh sources: a user file saved before they existed gets the seed's list.
	if _, ok := found[0]["sources"]; !ok && len(found) > 1 {
		if u, ok := found[len(found)-1]["sources"]; ok {
			found[0]["sources"] = u
		}
	}
	// t-aba6: the Copilot fallback list too (a user file saved before it existed gets the seed's).
	if _, ok := found[0]["copilot_models"]; !ok && len(found) > 1 {
		if u, ok := found[len(found)-1]["copilot_models"]; ok {
			found[0]["copilot_models"] = u
		}
	}
	// t-8f6d: a user file saved before the per-step, per-agent defaults is read in the new shape (written so on its next save);
	// t-aba6: and its Copilot picks in Copilot's own ids.
	MigrateTierDefaults(found[0], found[len(found)-1])
	FillNewSteps(found[0])
	MigrateCopilotPicks(found[0])
	return found[0]
}

// AdminStageModel (t-3425) is Admin's pick for one step and agent, as the agent's --model takes it: Claude Code gets the registry entry's
// alias when it has one, else the id; Copilot its own id as saved. "" when there is no pick or the value could not be a --model value (ModelValueRe).
// The one rule the daemon's session start and `canon-go stage-model` (sprint approve's line) share.
func AdminStageModel(doc map[string]any, step, agent string) string {
	defaults, _ := doc["defaults"].(map[string]any)
	per, _ := defaults[step].(map[string]any)
	id, _ := per[agent].(string)
	if agent == RegistryAgent {
		if _, m := RegistryModel(doc, id); m != nil && AliasOf(m) != "" {
			id = AliasOf(m)
		}
	}
	if !ModelValueRe.MatchString(id) {
		return ""
	}
	return id
}
