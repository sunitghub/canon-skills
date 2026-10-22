package board

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// t-d40b: what Refresh does with the pages it fetched. A source is a docs page (HTML with model ids and prices) or a provider's Models
// API (JSON ids; the key comes from the board's environment and is never stored or returned). The result is a PROPOSAL: models the
// registry does not have, each with an optional "replaces X" (same line, higher version), a flag when a price is unconfirmed, and the
// models already current. Nothing is written until the user applies it (applyProposal).

// found is one model a source mentions.
type found struct {
	Provider  string  `json:"provider"`
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	In        float64 `json:"input_price"`
	Out       float64 `json:"output_price"`
	PriceKnow bool    `json:"price_known"`
	From      bool    `json:"price_from"` // the page says "from $x": a floor, not the price
}

var (
	claudeIDRe = regexp.MustCompile(`claude-[a-z]+(?:-[0-9]+){1,3}(?:-[0-9]{8})?`)
	gptIDRe    = regexp.MustCompile(`gpt-[0-9]+(?:\.[0-9]+)?-[a-z]+(?:-[a-z]+)?`)
	priceRe    = regexp.MustCompile(`(?i)(from\s+)?\$\s?([0-9]+(?:\.[0-9]+)?)`)
	tagRe      = regexp.MustCompile(`(?s)<script.*?</script>|<style.*?</style>|<[^>]+>`)
)

// parseDocsPage reads model ids out of an HTML or text page and, when two dollar amounts follow an id within 300 characters, takes them
// as the input and output price per million tokens (a "from" in front flags the price as a floor).
func parseDocsPage(provider, page string) []found {
	text := tagRe.ReplaceAllString(page, " ")
	text = strings.NewReplacer("&nbsp;", " ", "&#36;", "$").Replace(text)
	re := claudeIDRe
	if provider == "openai" {
		re = gptIDRe
	}
	seen := map[string]bool{}
	var out []found
	for _, loc := range re.FindAllStringIndex(text, -1) {
		id := text[loc[0]:loc[1]]
		if seen[id] {
			continue
		}
		seen[id] = true
		f := found{Provider: provider, ID: id, Name: displayName(id)}
		ms := priceRe.FindAllStringSubmatch(text[loc[1]:min(loc[1]+300, len(text))], 2)
		if len(ms) == 2 {
			f.In, _ = strconv.ParseFloat(ms[0][2], 64)
			f.Out, _ = strconv.ParseFloat(ms[1][2], 64)
			f.PriceKnow, f.From = true, strings.TrimSpace(ms[0][1]) != ""
		}
		out = append(out, f)
	}
	return out
}

// parseModelsAPI reads {"data":[{"id":..,"display_name":..}]} from either provider's /v1/models. An API lists ids, not prices.
func parseModelsAPI(provider string, body []byte) ([]found, error) {
	var doc struct {
		Data []struct {
			ID          string `json:"id"`
			DisplayName string `json:"display_name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("the answer is not a model list")
	}
	var out []found
	for _, m := range doc.Data {
		re := claudeIDRe
		if provider == "openai" {
			re = gptIDRe
		}
		if loc := re.FindStringIndex(m.ID); loc == nil || loc[0] != 0 || loc[1] != len(m.ID) {
			continue // only ids of the shape the registry holds
		}
		name := m.DisplayName
		if name == "" {
			name = displayName(m.ID)
		}
		out = append(out, found{Provider: provider, ID: m.ID, Name: name})
	}
	return out, nil
}

// displayName turns claude-haiku-5-6 into "Claude Haiku 5.6" and gpt-6.1-sol into "GPT-6.1 Sol".
func displayName(id string) string {
	id = regexp.MustCompile(`-[0-9]{8}$`).ReplaceAllString(id, "")
	parts := strings.Split(id, "-")
	var words, nums []string
	for _, p := range parts {
		if _, err := strconv.Atoi(strings.ReplaceAll(p, ".", "")); err == nil {
			nums = append(nums, p)
		} else if p != "gpt" {
			words = append(words, strings.ToUpper(p[:1])+p[1:])
		}
	}
	ver := strings.Join(nums, ".")
	if strings.HasPrefix(id, "gpt-") {
		return "GPT-" + ver + " " + strings.Join(words, " ")
	}
	return strings.Join(words, " ") + " " + ver
}

// lineAndVersion splits a registry id into its model line and its version: claude-sonnet-5-5 -> ("sonnet", [5 5]); gpt-6.1-sol ->
// ("sol", [6 1]). A date suffix is dropped. ok is false for an id of neither shape.
func lineAndVersion(id string) (line string, ver []int, ok bool) {
	id = regexp.MustCompile(`-[0-9]{8}$`).ReplaceAllString(id, "")
	if m := regexp.MustCompile(`^claude-([a-z]+)((?:-[0-9]+)+)$`).FindStringSubmatch(id); m != nil {
		for _, n := range strings.Split(strings.TrimPrefix(m[2], "-"), "-") {
			v, _ := strconv.Atoi(n)
			ver = append(ver, v)
		}
		return m[1], ver, true
	}
	if m := regexp.MustCompile(`^gpt-([0-9]+(?:\.[0-9]+)?)-([a-z]+(?:-[a-z]+)?)$`).FindStringSubmatch(id); m != nil {
		for _, n := range strings.Split(m[1], ".") {
			v, _ := strconv.Atoi(n)
			ver = append(ver, v)
		}
		return m[2], ver, true
	}
	return "", nil, false
}

func versionLess(a, b []int) bool {
	for i := 0; i < len(a) || i < len(b); i++ {
		x, y := 0, 0
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x < y
		}
	}
	return false
}

// proposalEntry is one model Refresh offers to add, with the model it would replace (empty when none matches).
type proposalEntry struct {
	found
	Replaces    string `json:"replaces,omitempty"`      // id of the active model of the same line and a lower version
	ReplacesAll string `json:"replaces_name,omitempty"` // its display name
	Gate        bool   `json:"changes_gate_model,omitempty"`
}

// retireEntry is an active model that a newer active model of its line (already in the registry) supersedes.
type retireEntry struct {
	Old     string `json:"old"`
	OldName string `json:"old_name"`
	New     string `json:"new"`
	NewName string `json:"new_name"`
	Gate    bool   `json:"changes_gate_model,omitempty"`
}

type proposal struct {
	Add     []proposalEntry `json:"add"`
	Retire  []retireEntry   `json:"retire"`
	Current []string        `json:"current"` // "Claude Opus 5.5": no newer model of its line
}

// buildProposal compares what the sources found with the registry. A model is offered when no registry entry (active or legacy) has its id.
// Same line, higher version replaces the highest lower active one; a line the registry has no match for is never mapped. The registry's own
// active entries where a newer active one of the same line exists are offered for retirement, so a registry that already holds both
// Sonnet 5 and Sonnet 5.5 can be tidied without a fetch.
func buildProposal(doc map[string]any, finds []found) proposal {
	models, _ := doc["models"].(map[string]any)
	type reg struct {
		id, name string
		ver      []int
		line     string
		legacy   bool
		prov     string
	}
	var all []reg
	have := map[string]bool{}
	for prov, raw := range models {
		list, _ := raw.([]any)
		for _, e := range list {
			m, _ := e.(map[string]any)
			id := fmt.Sprint(m["id"])
			line, ver, _ := lineAndVersion(id)
			have[id] = true
			all = append(all, reg{id, fmt.Sprint(m["name"]), ver, line, isLegacy(m), prov})
		}
	}
	best := func(prov, line string, below []int) *reg { // the highest active entry of the line, strictly below `below` when given
		var b *reg
		for i := range all {
			r := &all[i]
			if r.prov != prov || r.legacy || r.line != line || (below != nil && !versionLess(r.ver, below)) {
				continue
			}
			if b == nil || versionLess(b.ver, r.ver) {
				b = r
			}
		}
		return b
	}
	evalDefault := func(prov, id string) bool {
		defaults, _ := doc["defaults"].(map[string]any)
		per, _ := defaults["eval"].(map[string]any)
		return per != nil && fmt.Sprint(per[prov]) == id
	}
	p := proposal{Add: []proposalEntry{}, Retire: []retireEntry{}, Current: []string{}}
	for _, f := range finds {
		if have[f.ID] {
			continue
		}
		e := proposalEntry{found: f}
		if line, ver, ok := lineAndVersion(f.ID); ok {
			if old := best(f.Provider, line, ver); old != nil {
				e.Replaces, e.ReplacesAll, e.Gate = old.id, old.name, evalDefault(f.Provider, old.id)
			}
		}
		p.Add = append(p.Add, e)
	}
	sort.Slice(p.Add, func(i, j int) bool { return p.Add[i].ID < p.Add[j].ID })
	for _, r := range all {
		if r.legacy || r.line == "" {
			continue
		}
		newest := best(r.prov, r.line, nil) // never nil: r itself is an active entry of this line
		if versionLess(r.ver, newest.ver) {
			p.Retire = append(p.Retire, retireEntry{r.id, r.name, newest.id, newest.name, evalDefault(r.prov, r.id)})
		} else {
			p.Current = append(p.Current, r.name)
		}
	}
	sort.Slice(p.Retire, func(i, j int) bool { return p.Retire[i].Old < p.Retire[j].Old })
	sort.Strings(p.Current)
	return p
}

// applyProposal adds the chosen models first (so a model exists before anything moves to it), then retires each old one in favour of its
// replacement. adds are checked like any registry entry; a retire pair goes through retireModel, the one place aliases and defaults move.
func applyProposal(doc map[string]any, adds []map[string]any, retire [][2]string) error {
	models, _ := doc["models"].(map[string]any)
	for _, a := range adds {
		id := fmt.Sprint(a["id"])
		prov := fmt.Sprint(a["provider"])
		if !modelIDRe.MatchString(id) || (prov != "anthropic" && prov != "openai") {
			return fmt.Errorf("%q is not a model id of a known provider", id)
		}
		if p, m := registryModel(doc, id); m != nil {
			return fmt.Errorf("%s is already in the registry (%s)", id, p)
		}
		in, _ := a["input_price"].(float64)
		out, _ := a["output_price"].(float64)
		if in < 0 || out < 0 {
			return fmt.Errorf("a price cannot be negative")
		}
		entry := map[string]any{"id": id, "name": fmt.Sprint(a["name"]), "desc": "", "reasoning": []any{}, "input_price": in, "output_price": out}
		if prov == "anthropic" {
			entry["alias"] = ""
		}
		list, _ := models[prov].([]any)
		models[prov] = append(list, entry)
	}
	for _, r := range retire {
		if err := retireModel(doc, r[0], r[1]); err != nil {
			return err
		}
	}
	return nil
}

// sourceStatus is what Refresh reports per saved source.
type sourceStatus struct {
	Index  int    `json:"index"`
	Status string `json:"status"` // "checked just now", "key not set", or a one-line refusal
	OK     bool   `json:"ok"`
	Found  int    `json:"found"`
}

// refreshSources fetches the saved sources (all, or one by index; -1 = all) and builds the proposal. Sources come from the registry, never
// from the request, so a request cannot aim the fetcher.
func refreshSources(doc map[string]any, only int, fetchO fetchOpts) (map[string]any, []sourceStatus) {
	srcs, _ := doc["sources"].([]any)
	var finds []found
	var st []sourceStatus
	for i, raw := range srcs {
		if only >= 0 && i != only {
			continue
		}
		s, _ := raw.(map[string]any)
		kind, prov, u := fmt.Sprint(s["kind"]), fmt.Sprint(s["provider"]), fmt.Sprint(s["url"])
		o := fetchO // a copy: the key header below is set on this source's request only
		if kind == "api" {
			key := os.Getenv(map[string]string{"anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY"}[prov])
			if key == "" {
				st = append(st, sourceStatus{i, "key not set", false, 0})
				continue
			}
			o.noRedirect = true // a request that carries a key is never redirected
			if prov == "anthropic" {
				o.headers = map[string]string{"x-api-key": key, "anthropic-version": "2023-06-01"}
			} else {
				o.headers = map[string]string{"Authorization": "Bearer " + key}
			}
		}
		body, err := guardedGet(context.Background(), u, o)
		if err != nil {
			st = append(st, sourceStatus{i, "refused: " + redactKey(err.Error()), false, 0})
			continue
		}
		var got []found
		if kind == "api" {
			got, err = parseModelsAPI(prov, body)
		} else {
			got = parseDocsPage(prov, string(body))
		}
		if err != nil {
			st = append(st, sourceStatus{i, err.Error(), false, 0})
			continue
		}
		finds = append(finds, got...)
		st = append(st, sourceStatus{i, "checked just now", true, len(got)})
	}
	// the same id from a docs page and the API: keep the one that has a price
	byID := map[string]found{}
	for _, f := range finds {
		if cur, ok := byID[f.ID]; !ok || (!cur.PriceKnow && f.PriceKnow) {
			byID[f.ID] = f
		}
	}
	merged := make([]found, 0, len(byID))
	for _, f := range byID {
		merged = append(merged, f)
	}
	return map[string]any{"proposal": buildProposal(doc, merged)}, st
}

// redactKey keeps an API key out of anything shown to the user, whatever an error message happens to contain.
func redactKey(msg string) string {
	for _, env := range []string{"ANTHROPIC_API_KEY", "OPENAI_API_KEY"} {
		if k := os.Getenv(env); len(k) >= 6 {
			msg = strings.ReplaceAll(msg, k, "***")
		}
	}
	return msg
}
