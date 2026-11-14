package board

import (
	"fmt"
	"slices"
	"strings"
	"time"

	"canon/internal/common"
)

// t-d40b: the model registry's moves. One function retires a model in favour of another (its alias and any default
// that named it go to the replacement, the old entry is marked legacy), and Remove-with-a-move uses the same
// transfer, so there is exactly one way an alias or a default changes hands. The registry is the document that
// /api/admin/model-tiers reads and writes: {"defaults": {tier: {provider: id}}, "models": {provider: [entry...]}}.

// knownAliases are the short names Claude Code resolves and the per-ticket Gate model dropdown offers (static/cockpit-admin.js
// MT_ALIASES). Removing the entry that holds one is refused until another model takes it over; a custom alias is not one of these.
var knownAliases = map[string]bool{"fable": true, "opus": true, "sonnet": true, "haiku": true}

// tierOption is one model a step's picker offers: the id stored, its name, the group it is listed under, and Copilot's multiplier.
type tierOption struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Group string `json:"group"`
	Usage string `json:"usage,omitempty"`
	Saved bool   `json:"saved_only,omitempty"` // shown only because it is the saved pick (a hand-edited file); never offered otherwise
}

// tierCandidates are the models an agent can run, before any step's rule: Claude Code, the registry's active Anthropic models; Copilot
// CLI, Copilot's own list (read in Admin, else the fallback list). Computed once per agent per request.
func tierCandidates(doc map[string]any, agent string) []tierOption {
	out := []tierOption{}
	if agent == "copilot" {
		list, _ := savedCopilotModels(doc)
		for _, m := range list.Models {
			out = append(out, tierOption{ID: m.ID, Name: m.Name, Group: common.CopilotGroup(m.ID), Usage: m.Usage})
		}
		// Claude, then GPT (acceptance: grouped Claude then GPT), each family in Copilot's own order
		rank := map[string]int{"Anthropic": 0, "OpenAI": 1}
		slices.SortStableFunc(out, func(a, b tierOption) int { return rank[a.Group] - rank[b.Group] })
		return out
	}
	models, _ := doc["models"].(map[string]any)
	for _, raw := range anySlice(models["anthropic"]) {
		m, _ := raw.(map[string]any)
		if id := fmt.Sprint(m["id"]); m != nil && !common.IsLegacy(m) {
			name, _ := m["name"].(string)
			out = append(out, tierOption{ID: id, Name: name, Group: "Anthropic"})
		}
	}
	return out
}

// lightLine: the cheap line Simple / Light work offers (a Haiku model, or a Luna one under Copilot). An offer only; validation does not
// require it, so a person's own pick from before stays valid.
func lightLine(id string) bool {
	return common.HaikuClass(id, nil) || strings.Contains(strings.ToLower(id), "luna")
}

// tierOptions (t-aba6, DRY with validation): what each step's picker offers each agent, built from common.TierPickProblem so Admin can never
// offer a model a save would refuse. The saved pick is always listed, marked when no rule offers it. The one owner static/cockpit-admin.js renders.
func tierOptions(doc map[string]any) map[string]map[string][]tierOption {
	defaults, _ := doc["defaults"].(map[string]any)
	cands := map[string][]tierOption{}
	for _, agent := range common.TierAgents {
		cands[agent] = tierCandidates(doc, agent)
	}
	out := map[string]map[string][]tierOption{}
	for _, step := range common.TierSteps {
		per, _ := defaults[step].(map[string]any)
		out[step] = map[string][]tierOption{}
		for _, agent := range common.TierAgents {
			cur, _ := per[agent].(string)
			opts, has := []tierOption{}, false
			for _, c := range cands[agent] {
				if common.TierPickProblem(doc, step, agent, c.ID) != "" || (step == "light" && !lightLine(c.ID) && c.ID != cur) {
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
	for _, s := range common.TierSteps {
		steps = append(steps, map[string]string{"id": s, "label": common.TierStepLabel[s], "role": common.TierStepRole[s], "checks": common.TierStepChecks[s]})
	}
	for _, a := range common.TierAgents {
		agents = append(agents, map[string]string{"id": a, "label": common.TierAgentLabel[a]})
	}
	return map[string]any{"ok": true, "steps": steps, "agents": agents, "registry_agent": common.RegistryAgent, "options": tierOptions(doc)}
}

// heldBy lists what the entry holds: its alias and the <step>.claude defaults that name it. A Copilot CLI pick is Copilot's own id
// (t-aba6), another id space: a registry retire or remove never moves it, even when the two spell a model the same way.
func heldBy(doc map[string]any, prov string, m map[string]any) (alias string, tiers []string) {
	alias = common.AliasOf(m)
	defaults, _ := doc["defaults"].(map[string]any)
	for _, step := range common.TierSteps {
		per, _ := defaults[step].(map[string]any)
		for _, agent := range []string{common.RegistryAgent} {
			if per != nil && fmt.Sprint(per[agent]) == fmt.Sprint(m["id"]) {
				tiers = append(tiers, step+"."+agent)
			}
		}
	}
	return alias, tiers
}

// transfer moves from's alias and defaults to to. A target that already has a different alias cannot also carry
// the old one, so that is refused rather than dropping an alias silently.
func transfer(doc map[string]any, prov string, from, to map[string]any) error {
	alias, tiers := heldBy(doc, prov, from)
	if alias != "" {
		if cur := common.AliasOf(to); cur != "" && cur != alias {
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
	toProv, to := common.RegistryModel(doc, toID)
	switch {
	case to == nil:
		return nil, fmt.Errorf("no model %q in the registry", toID)
	case toProv != prov:
		return nil, fmt.Errorf("%s is a %s model; %s can only move to the same provider", toID, toProv, from["id"])
	case fmt.Sprint(to["id"]) == fmt.Sprint(from["id"]):
		return nil, fmt.Errorf("a model cannot be replaced by itself")
	case common.IsLegacy(to):
		return nil, fmt.Errorf("%s is legacy; pick an active model", toID)
	}
	return to, nil
}

// retireModel: oldID is replaced by newID. The alias and the matching defaults move to newID and oldID is marked legacy.
func retireModel(doc map[string]any, oldID, newID string) error {
	prov, old := common.RegistryModel(doc, oldID)
	if old == nil {
		return fmt.Errorf("no model %q in the registry", oldID)
	}
	if common.IsLegacy(old) {
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
	prov, m := common.RegistryModel(doc, id)
	if m == nil {
		return fmt.Errorf("no model %q in the registry", id)
	}
	alias, tiers := heldBy(doc, prov, m)
	// only a name Claude Code resolves, or a default, must be handed over; a custom alias goes with its entry
	if (knownAliases[strings.ToLower(alias)] || len(tiers) > 0) && !common.IsLegacy(m) {
		if moveTo == "" {
			held := []string{}
			if alias != "" {
				held = append(held, "the alias "+alias)
			}
			for _, t := range tiers {
				held = append(held, common.TierSlot(t))
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
			if common.IsLegacy(m) {
				legacyIDs[fmt.Sprint(m["id"])] = true
				continue
			}
			if a := strings.ToLower(common.AliasOf(m)); a != "" {
				if seen[a] {
					return false
				}
				seen[a] = true
			}
		}
	}
	// t-8f6d: every default is a known step and agent, names an active model the agent can run, and the binding evaluator is never Haiku.
	return common.TierDefaultsProblem(data) == ""
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
