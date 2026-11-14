package board

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
)

// t-d40b: the model registry's moves. One function retires a model in favour of another (its alias and any default
// that named it go to the replacement, the old entry is marked legacy), and Remove-with-a-move uses the same
// transfer, so there is exactly one way an alias or a default changes hands. The registry is the document that
// /api/admin/model-tiers reads and writes: {"defaults": {tier: {provider: id}}, "models": {provider: [entry...]}}.

// knownAliases are the short names Claude Code resolves and the per-ticket Gate model dropdown offers (static/cockpit-admin.js
// MT_ALIASES). Removing the entry that holds one is refused until another model takes it over; a custom alias is not one of these.
var knownAliases = map[string]bool{"fable": true, "opus": true, "sonnet": true, "haiku": true}

// aliasOf is an entry's alias, trimmed; a missing or null alias is "".
func aliasOf(m map[string]any) string { a, _ := m["alias"].(string); return strings.TrimSpace(a) }

// registryModel finds an entry by id across providers.
func registryModel(doc map[string]any, id string) (prov string, entry map[string]any) {
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

// t-8f6d + t-2cc8: the registry's defaults are one model id per step and agent: defaults.<step>.<agent>. This table is their one owner
// (validation, the migration, retire/remove, the Refresh flag, the audit names and the Pipeline rows read it; static/cockpit-admin.js
// mirrors it for the cards). A claude pick is an Anthropic model; a copilot pick is an Anthropic or an OpenAI model (Copilot CLI runs both).
var (
	tierSteps          = []string{"plan", "build", "reviewer", "evaluator", "light"}
	tierAgents         = []string{"claude", "copilot"}
	tierAgentProviders = map[string][]string{"claude": {"anthropic"}, "copilot": {"anthropic", "openai"}}
	tierStepLabel      = map[string]string{"plan": "Plan", "build": "Build", "reviewer": "Reviewer", "evaluator": "Evaluator", "light": "Simple / Light work"}
	tierAgentLabel     = map[string]string{"claude": "Claude Code", "copilot": "Copilot CLI"}
)

// haikuClass: a Haiku model (its alias is haiku, or its id names haiku). The binding evaluator is never one, under any agent (user,
// 2026-11-14); a Lite ticket's forced Haiku evaluator is a per-ticket rule at close, not a default.
func haikuClass(id string, m map[string]any) bool {
	return strings.EqualFold(aliasOf(m), "haiku") || strings.Contains(strings.ToLower(id), "haiku")
}

// migrateTierDefaults rewrites a registry saved before the reshape (defaults.eval and defaults.light by provider) in memory: the old
// Review & Eval pick becomes the reviewer and the evaluator for both agents, the old light pick the light for both, plan and build come
// from the seed's defaults. Every carried pick must pass today's rules (a model the agent can run, not legacy, never a Haiku evaluator):
// one that does not takes the seed's pick, so a migrated file never fails validation and locks Admin. The OpenAI picks drove nothing
// and are dropped (the models stay in models.openai). A file that already has new-shape steps (an old board saved over a new file) keeps
// them and only loses its old keys. A document in the new shape is left as it is. Returns whether it changed anything; the file on
// disk changes only on the next save.
func migrateTierDefaults(doc, seed map[string]any) bool {
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
	for _, step := range tierSteps {
		cur, _ := d[step].(map[string]any)
		per := map[string]any{}
		for _, agent := range tierAgents {
			if v, _ := cur[agent].(string); v != "" { // a new-shape pick already there (a mixed file) wins
				per[agent] = v
				continue
			}
			id := ""
			switch step {
			case "reviewer", "evaluator":
				id = old("eval")
			case "light":
				id = old("light")
			}
			if agent == "copilot" { // t-aba6: a Copilot pick is Copilot's own id
				id = copilotFormOf(id)
			}
			if id = firstUsablePick(doc, step, agent, id, seedPick(step, agent)); id != "" {
				per[agent] = id
			}
		}
		out[step] = per
	}
	doc["defaults"] = out
	return true
}

// tierPickProblem says why one default cannot hold id, or "": a Claude Code pick is an active Anthropic model of the registry; a Copilot
// CLI pick is one of Copilot's own ids (t-aba6: the list read from Copilot, else the seed's fallback list), a Claude or GPT model; the
// binding evaluator is never a Haiku model under either agent (user, 2026-11-14).
func tierPickProblem(doc map[string]any, step, agent, id string) string {
	if agent == "copilot" {
		switch { // the list holds only Claude and GPT models (keepCopilotModels), so membership is the family rule too
		case !copilotPickIDs(doc)[id]:
			return id + " is not in Copilot CLI's model list (Read Copilot's models in Admin)"
		case step == "evaluator" && haikuClass(id, nil):
			return "the binding evaluator is never a Haiku model"
		}
		return ""
	}
	prov, m := registryModel(doc, id)
	switch {
	case m == nil:
		return id + " is not in the registry"
	case isLegacy(m):
		return id + " is legacy"
	case !slices.Contains(tierAgentProviders[agent], prov):
		return id + " is an " + map[string]string{"anthropic": "Anthropic", "openai": "OpenAI"}[prov] + " model, which " + tierAgentLabel[agent] + " cannot run"
	case step == "evaluator" && haikuClass(id, m):
		return "the binding evaluator is never a Haiku model"
	}
	return ""
}

// tierDefaultsProblem names the first default a save cannot hold ("the Evaluator default for Claude Code: ..."), or "" when all are
// fine: the refusal a person reads in Admin.
func tierDefaultsProblem(data map[string]any) string {
	defaults, _ := data["defaults"].(map[string]any)
	steps := make([]string, 0, len(defaults))
	for step := range defaults {
		steps = append(steps, step)
	}
	slices.Sort(steps)
	for _, step := range steps {
		if tierStepLabel[step] == "" {
			return "defaults: unknown step " + step + " (steps: " + strings.Join(tierSteps, ", ") + ")"
		}
		per, _ := defaults[step].(map[string]any)
		agents := make([]string, 0, len(per))
		for agent := range per {
			agents = append(agents, agent)
		}
		slices.Sort(agents)
		for _, agent := range agents {
			if tierAgentLabel[agent] == "" {
				return "defaults." + step + ": unknown agent " + agent + " (agents: " + strings.Join(tierAgents, ", ") + ")"
			}
			if why := tierPickProblem(data, step, agent, fmt.Sprint(per[agent])); why != "" {
				return tierSlot(step+"."+agent) + ": " + why
			}
		}
	}
	return ""
}

// copilotFormOf is a registry id in Copilot's spelling: the last version dash is a dot (claude-sonnet-5-5 -> claude-sonnet-5.5);
// an id with one version number (claude-sonnet-5, gpt-6-luna) is the same in both.
var registryVersionRe = regexp.MustCompile(`^(claude-[a-z]+-[0-9]+)-([0-9]+)$`)

func copilotFormOf(id string) string { return registryVersionRe.ReplaceAllString(id, "$1.$2") }

// migrateCopilotPicks (t-aba6): a registry saved before Copilot picks were Copilot's own ids holds registry ids there. Each one Copilot's
// list does not name is mapped once to Copilot's spelling, else takes the seed's pick, else is left out; it is written on the next save.
func migrateCopilotPicks(doc, seed map[string]any) bool {
	d, _ := doc["defaults"].(map[string]any)
	sd, _ := seed["defaults"].(map[string]any)
	changed := false
	for _, step := range tierSteps {
		per, _ := d[step].(map[string]any)
		cur, _ := per["copilot"].(string)
		if per == nil || cur == "" || tierPickProblem(doc, step, "copilot", cur) == "" {
			continue
		}
		seedPer, _ := sd[step].(map[string]any)
		seedPick, _ := seedPer["copilot"].(string)
		next := firstUsablePick(doc, step, "copilot", copilotFormOf(cur), seedPick)
		if next == "" {
			delete(per, "copilot")
		} else {
			per["copilot"] = next
		}
		changed = true
	}
	return changed
}

// firstUsablePick is the first of ids one default may hold today (tierPickProblem), or "": the one fallback rule both migrations use.
func firstUsablePick(doc map[string]any, step, agent string, ids ...string) string {
	for _, id := range ids {
		if id != "" && tierPickProblem(doc, step, agent, id) == "" {
			return id
		}
	}
	return ""
}

// tierOption is one model a step's picker offers: the id stored, its name, the group it is listed under, and Copilot's multiplier.
type tierOption struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Group string `json:"group"`
	Usage string `json:"usage,omitempty"`
	Saved bool   `json:"saved_only,omitempty"` // shown only because it is the saved pick (a hand-edited file); never offered otherwise
}

// tierCandidates are the models an agent can run, before any step's rule: Claude Code, the registry's active Anthropic models; Copilot
// CLI, Copilot's own list (read in Admin, else the fallback list).
func tierCandidates(doc map[string]any, agent string) []tierOption {
	out := []tierOption{}
	if agent == "copilot" {
		list, _ := savedCopilotModels(doc)
		for _, m := range list.Models {
			out = append(out, tierOption{ID: m.ID, Name: m.Name, Group: copilotGroup(m.ID), Usage: m.Usage})
		}
		return out
	}
	models, _ := doc["models"].(map[string]any)
	for _, raw := range anySlice(models["anthropic"]) {
		m, _ := raw.(map[string]any)
		if id := fmt.Sprint(m["id"]); m != nil && !isLegacy(m) {
			name, _ := m["name"].(string)
			out = append(out, tierOption{ID: id, Name: name, Group: "Anthropic"})
		}
	}
	return out
}

// lightLine: the cheap line Simple / Light work offers (a Haiku model, or a Luna one under Copilot). An offer only; validation does not
// require it, so a person's own pick from before stays valid.
func lightLine(id string) bool {
	return haikuClass(id, nil) || strings.Contains(strings.ToLower(id), "luna")
}

// tierOptions (t-aba6, DRY with validation): what each step's picker offers each agent, built from tierPickProblem so Admin can never
// offer a model a save would refuse. The saved pick is always listed, marked when no rule offers it. The one owner static/cockpit-admin.js renders.
func tierOptions(doc map[string]any) map[string]map[string][]tierOption {
	defaults, _ := doc["defaults"].(map[string]any)
	out := map[string]map[string][]tierOption{}
	for _, step := range tierSteps {
		per, _ := defaults[step].(map[string]any)
		out[step] = map[string][]tierOption{}
		for _, agent := range tierAgents {
			cur, _ := per[agent].(string)
			opts, has := []tierOption{}, false
			for _, c := range tierCandidates(doc, agent) {
				if tierPickProblem(doc, step, agent, c.ID) != "" || (step == "light" && !lightLine(c.ID) && c.ID != cur) {
					continue
				}
				has = has || c.ID == cur
				opts = append(opts, c)
			}
			if cur != "" && !has {
				opts = append(opts, tierOption{ID: cur, Name: cur, Group: "Saved", Saved: true})
			}
			out[step][agent] = opts
		}
	}
	return out
}

// tierOptionsView answers GET /api/admin/model-tiers/options: the steps and agents (their labels, the one place they are named) and
// each picker's options.
func tierOptionsView() map[string]any {
	doc := loadModelTiers()
	steps, agents := []map[string]string{}, []map[string]string{}
	for _, s := range tierSteps {
		steps = append(steps, map[string]string{"id": s, "label": tierStepLabel[s]})
	}
	for _, a := range tierAgents {
		agents = append(agents, map[string]string{"id": a, "label": tierAgentLabel[a]})
	}
	return map[string]any{"ok": true, "steps": steps, "agents": agents, "options": tierOptions(doc)}
}

// tierSlot names one default for a person: "the Evaluator default for Claude Code".
func tierSlot(slot string) string {
	step, agent, _ := strings.Cut(slot, ".")
	return "the " + tierStepLabel[step] + " default for " + tierAgentLabel[agent]
}

// heldBy lists what the entry holds: its alias and the <step>.claude defaults that name it. A Copilot CLI pick is Copilot's own id
// (t-aba6), another id space: a registry retire or remove never moves it, even when the two spell a model the same way.
func heldBy(doc map[string]any, prov string, m map[string]any) (alias string, tiers []string) {
	alias = aliasOf(m)
	defaults, _ := doc["defaults"].(map[string]any)
	for _, step := range tierSteps {
		per, _ := defaults[step].(map[string]any)
		for _, agent := range []string{"claude"} {
			if per != nil && fmt.Sprint(per[agent]) == fmt.Sprint(m["id"]) {
				tiers = append(tiers, step+"."+agent)
			}
		}
	}
	return alias, tiers
}

func isLegacy(m map[string]any) bool { b, _ := m["legacy"].(bool); return b }

// transfer moves from's alias and defaults to to. A target that already has a different alias cannot also carry
// the old one, so that is refused rather than dropping an alias silently.
func transfer(doc map[string]any, prov string, from, to map[string]any) error {
	alias, tiers := heldBy(doc, prov, from)
	if alias != "" {
		if cur := aliasOf(to); cur != "" && cur != alias {
			return fmt.Errorf("%s already has the alias %s, so it cannot also take %s", to["id"], cur, alias)
		}
		to["alias"] = alias
		from["alias"] = ""
	}
	defaults, _ := doc["defaults"].(map[string]any)
	for _, slot := range tiers {
		step, agent, _ := strings.Cut(slot, ".")
		per, _ := defaults[step].(map[string]any)
		per[agent] = to["id"]
	}
	return nil
}

// target checks that to is a usable replacement for from: another, active entry of the same provider.
func target(doc map[string]any, prov string, from map[string]any, toID string) (map[string]any, error) {
	toProv, to := registryModel(doc, toID)
	switch {
	case to == nil:
		return nil, fmt.Errorf("no model %q in the registry", toID)
	case toProv != prov:
		return nil, fmt.Errorf("%s is a %s model; %s can only move to the same provider", toID, toProv, from["id"])
	case fmt.Sprint(to["id"]) == fmt.Sprint(from["id"]):
		return nil, fmt.Errorf("a model cannot be replaced by itself")
	case isLegacy(to):
		return nil, fmt.Errorf("%s is legacy; pick an active model", toID)
	}
	return to, nil
}

// retireModel: oldID is replaced by newID. The alias and the matching defaults move to newID and oldID is marked legacy.
func retireModel(doc map[string]any, oldID, newID string) error {
	prov, old := registryModel(doc, oldID)
	if old == nil {
		return fmt.Errorf("no model %q in the registry", oldID)
	}
	if isLegacy(old) {
		return fmt.Errorf("%s is already legacy", oldID)
	}
	to, err := target(doc, prov, old, newID)
	if err != nil {
		return err
	}
	if err := transfer(doc, prov, old, to); err != nil {
		return err
	}
	old["legacy"] = true
	return nil
}

// removeModel deletes id. When it holds an alias or a default, moveTo must name the model that takes them over.
func removeModel(doc map[string]any, id, moveTo string) error {
	prov, m := registryModel(doc, id)
	if m == nil {
		return fmt.Errorf("no model %q in the registry", id)
	}
	alias, tiers := heldBy(doc, prov, m)
	// only a name Claude Code resolves, or a default, must be handed over; a custom alias goes with its entry
	if (knownAliases[strings.ToLower(alias)] || len(tiers) > 0) && !isLegacy(m) {
		if moveTo == "" {
			held := []string{}
			if alias != "" {
				held = append(held, "the alias "+alias)
			}
			for _, t := range tiers {
				held = append(held, tierSlot(t))
			}
			return fmt.Errorf("%s holds %s: choose the model that takes it over", id, strings.Join(held, " and "))
		}
		to, err := target(doc, prov, m, moveTo)
		if err != nil {
			return err
		}
		if err := transfer(doc, prov, m, to); err != nil {
			return err
		}
	}
	models, _ := doc["models"].(map[string]any)
	list, _ := models[prov].([]any)
	kept := make([]any, 0, len(list))
	for _, e := range list {
		if em, ok := e.(map[string]any); ok && fmt.Sprint(em["id"]) == id {
			continue
		}
		kept = append(kept, e)
	}
	models[prov] = kept
	return nil
}

// registryMove runs a move on the current registry and saves it through the same validation as every other write.
func registryMove(apply func(doc map[string]any) error) map[string]any {
	doc := loadModelTiers()
	if err := apply(doc); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	res := saveModelTiers(doc)
	if ok, _ := res["ok"].(bool); ok {
		res["data"] = doc
	}
	return res
}

// modelTiersConsistent is the part of validation that needs the whole document (t-d40b): `legacy` is a boolean, no two
// active entries of a provider share an alias (a second `sonnet` would make the dropdown and the gate pick one at
// random), and no default points at a legacy entry (legacy entries leave the pickers and the defaults).
func modelTiersConsistent(data map[string]any) bool {
	if !modelSourcesValid(data) {
		return false
	}
	models, _ := data["models"].(map[string]any)
	legacyIDs := map[string]bool{}
	for _, raw := range models {
		list, _ := raw.([]any)
		seen := map[string]bool{}
		for _, e := range list {
			m, _ := e.(map[string]any)
			if v, has := m["legacy"]; has {
				if _, isBool := v.(bool); !isBool {
					return false
				}
			}
			if isLegacy(m) {
				legacyIDs[fmt.Sprint(m["id"])] = true
				continue
			}
			if a := strings.ToLower(aliasOf(m)); a != "" {
				if seen[a] {
					return false
				}
				seen[a] = true
			}
		}
	}
	// t-8f6d: every default is a known step and agent, names an active model the agent can run, and the binding evaluator is never Haiku.
	return tierDefaultsProblem(data) == ""
}

// apiHost is the one host a provider's Models API source may name: the key is attached to it and to nothing else.
var apiHost = map[string]string{"anthropic": "api.anthropic.com", "openai": "api.openai.com"}

func anySlice(v any) []any { l, _ := v.([]any); return l }

// modelSourcesValid: each saved source is an https address of a known kind and provider, and a Models API source can only be the
// provider's own host (the key is attached to it and to nothing else).
func modelSourcesValid(data map[string]any) bool {
	raw, has := data["sources"]
	if !has {
		return true
	}
	list, ok := raw.([]any)
	if !ok {
		return false
	}
	for _, e := range list {
		s, ok := e.(map[string]any)
		if !ok {
			return false
		}
		if at, has := s["checked_at"]; has { // the bookkeeping Refresh records: a timestamp, a flag and a line of text, or absent
			text, isText := at.(string)
			if _, err := time.Parse(time.RFC3339, text); !isText || err != nil {
				return false
			}
			if _, isBool := s["last_ok"].(bool); !isBool {
				return false
			}
			if _, isText := s["last_status"].(string); !isText {
				return false
			}
		}
		kind, prov, raw := fmt.Sprint(s["kind"]), fmt.Sprint(s["provider"]), fmt.Sprint(s["url"])
		if (kind != "docs" && kind != "api") || (prov != "anthropic" && prov != "openai") {
			return false
		}
		u, err := checkFetchURL(raw)
		if err != nil {
			return false
		}
		if kind == "api" && !strings.EqualFold(u.Hostname(), apiHost[prov]) {
			return false
		}
	}
	return true
}
