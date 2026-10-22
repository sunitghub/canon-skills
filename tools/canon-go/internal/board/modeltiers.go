package board

import (
	"fmt"
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

// heldBy lists what the entry holds: its alias and the tiers whose default for the provider names it.
func heldBy(doc map[string]any, prov string, m map[string]any) (alias string, tiers []string) {
	alias = aliasOf(m)
	defaults, _ := doc["defaults"].(map[string]any)
	for _, tier := range []string{"eval", "light"} {
		per, _ := defaults[tier].(map[string]any)
		if per != nil && fmt.Sprint(per[prov]) == fmt.Sprint(m["id"]) {
			tiers = append(tiers, tier)
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
	for _, tier := range tiers {
		per, _ := defaults[tier].(map[string]any)
		per[prov] = to["id"]
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
				held = append(held, "the "+t+" default")
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
	defaults, _ := data["defaults"].(map[string]any)
	for _, perRaw := range defaults {
		per, _ := perRaw.(map[string]any)
		for _, id := range per {
			if legacyIDs[fmt.Sprint(id)] {
				return false
			}
		}
	}
	return true
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
