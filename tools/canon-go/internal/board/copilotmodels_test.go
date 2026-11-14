package board

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// stubCopilot puts a fake `copilot` on PATH that speaks newline JSON-RPC like `copilot --acp`: it answers initialize, then session/new
// per STUB_MODE (ok, noise, error, signedout, hang, exit, none). It records its argv and cwd to $STUB_LOG.
func stubCopilot(t *testing.T, mode string) (log string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the stub is a shell script")
	}
	dir := t.TempDir()
	log = filepath.Join(dir, "calls.log")
	script := `#!/bin/sh
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$STUB_LOG"
case "$STUB_MODE" in exit) exit 3 ;; esac
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*) printf '{"jsonrpc":"2.0","method":"note","params":{}}\nnot json at all\n{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}\n' ;;
    *'"session/new"'*)
      case "$STUB_MODE" in
        hang) sleep 30 ;;
        error) printf '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Not signed in\u001b[2J"}}\n' ;;
        signedout) printf '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s"}}\n' ;;
        none) printf '{"jsonrpc":"2.0","id":2,"result":{"models":{"availableModels":[{"modelId":"gemini-3.8-flash","name":"Gemini"},{"modelId":"auto","name":"Auto"}]}}}\n' ;;
        *) printf '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s","models":{"currentModelId":"claude-sonnet-5.5","availableModels":[{"modelId":"auto","name":"Auto"},{"modelId":"claude-sonnet-5.5","name":"Claude Sonnet 5.5","_meta":{"copilotUsage":"1x"}},{"modelId":"claude-haiku-4.5","name":"Claude Haiku 4.5","_meta":{"copilotUsage":"0.33x"}},{"modelId":"gpt-6-luna","name":"GPT-6 Luna\u001b[31m","_meta":{"copilotUsage":"1x"}},{"modelId":"gemini-3.8-flash","name":"Gemini 3.8 Flash","_meta":{"copilotUsage":"14x"}},{"modelId":"../evil","name":"x"},{"modelId":"claude-sonnet-5.5","name":"dup"}]}}}\n' ;;
      esac ;;
  esac
done
`
	if err := os.WriteFile(filepath.Join(dir, "copilot"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("STUB_MODE", mode)
	t.Setenv("STUB_LOG", log)
	return log
}

// t-aba6. Protects POST /api/admin/copilot-models/read: one ACP exchange with fixed arguments in a fresh folder, the Claude and GPT
// models kept (Copilot's own ids, names cleaned, multipliers), everything else (auto, Gemini, a hostile id, a repeat) dropped, and
// the list saved to the Cockpit data dir.
func TestReadCopilotModels(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	log := stubCopilot(t, "noise")
	res := readAndSaveCopilotModels(context.Background())
	if res["ok"] != true || res["source"] != "copilot" || res["read_at"] == "" {
		t.Fatalf("read = %v", res)
	}
	got, _ := json.Marshal(res["models"])
	want := `[{"id":"claude-sonnet-5.5","name":"Claude Sonnet 5.5","usage":"1x"},{"id":"claude-haiku-4.5","name":"Claude Haiku 4.5","usage":"0.33x"},{"id":"gpt-6-luna","name":"GPT-6 Luna[31m","usage":"1x"}]`
	if string(got) != want {
		t.Errorf("models = %s\nwant     %s", got, want)
	}
	if b, err := os.ReadFile(copilotModelsFile()); err != nil || !strings.Contains(string(b), `"claude-haiku-4.5"`) {
		t.Errorf("the list was not saved: %v %s", err, b)
	}
	if fi, err := os.Stat(copilotModelsFile()); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("the saved list is not 0600: %v", fi)
	}
	calls, _ := os.ReadFile(log)
	line := strings.TrimSpace(string(calls))
	args, cwd, _ := strings.Cut(line, "|")
	if args != "--acp" || !strings.Contains(cwd, "canon-copilot-models-") {
		t.Errorf("copilot ran as %q in %q, want --acp in a fresh folder", args, cwd)
	}
	if _, err := os.Stat(cwd); !os.IsNotExist(err) {
		t.Errorf("the run folder %s was left behind", cwd)
	}
	if ids := copilotPickIDs(loadModelTiers()); !ids["gpt-6-luna"] || ids["gemini-3.8-flash"] {
		t.Errorf("a pick reads the saved list: %v", ids)
	}
}

// t-aba6. Each way a read can fail answers with one line and keeps the last saved list. Protects Admin when Copilot is missing,
// signed out, refuses, offers no Claude or GPT model, stops, or hangs (killed at the deadline).
func TestReadCopilotModelsFailures(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	stubCopilot(t, "ok")
	if res := readAndSaveCopilotModels(context.Background()); res["ok"] != true {
		t.Fatalf("first read = %v", res)
	}
	saved, _ := os.ReadFile(copilotModelsFile())
	old := copilotReadTimeout
	copilotReadTimeout = 1500 * time.Millisecond
	defer func() { copilotReadTimeout = old }()
	for mode, want := range map[string]string{
		"error":     "Copilot refused: Not signed in[2J",
		"signedout": "Copilot answered without a model list (signed out?)",
		"none":      "Copilot listed no Claude or GPT model",
		"exit":      "Copilot CLI stopped before it answered",
		"hang":      "Copilot CLI did not answer within 1.5s",
	} {
		stubCopilot(t, mode)
		start := time.Now()
		res := readAndSaveCopilotModels(context.Background())
		if res["ok"] != false || res["error"] != want {
			t.Errorf("%s: %v, want error %q", mode, res, want)
		}
		if mode == "hang" && time.Since(start) > 6*time.Second {
			t.Errorf("a hung copilot was not stopped at the deadline (%s)", time.Since(start))
		}
		if res["source"] != "copilot" || len(res["models"].([]copilotModel)) != 3 {
			t.Errorf("%s: the last saved list is not shown: %v", mode, res)
		}
		if now, _ := os.ReadFile(copilotModelsFile()); string(now) != string(saved) {
			t.Errorf("%s: a failed read changed the saved list", mode)
		}
	}
	t.Setenv("PATH", t.TempDir())
	if res := readAndSaveCopilotModels(context.Background()); res["error"] != "Copilot CLI is not installed (no copilot on PATH)" {
		t.Errorf("missing copilot: %v", res)
	}
}

// t-aba6. With no read saved, the registry's copilot_models stand in (a user file saved before them gets the seed's); a saved list
// with no usable entry is ignored.
func TestSavedCopilotModelsFallback(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	doc := regDoc()
	list, source := savedCopilotModels(doc)
	if source != "fallback" || len(list.Models) != 8 || list.Models[0].ID != "claude-opus-5.5" {
		t.Fatalf("fallback = %s %v", source, list)
	}
	_ = os.MkdirAll(registryDir(), 0o700)
	_ = os.WriteFile(copilotModelsFile(), []byte(`{"read_at":"x","models":[{"id":"../evil"},{"id":"gemini-x"}]}`), 0o600)
	if _, source := savedCopilotModels(doc); source != "fallback" {
		t.Errorf("a saved list with no usable model was used: %s", source)
	}
}

// t-aba6. A registry saved by slice 1 holds registry ids as Copilot picks: each is mapped once to Copilot's spelling (or the seed's
// pick), so the file stays valid; a pick Copilot's list names is kept.
func TestMigrateCopilotPicks(t *testing.T) {
	if got := copilotFormOf("claude-sonnet-5-5"); got != "claude-sonnet-5.5" {
		t.Errorf("copilotFormOf = %s", got)
	}
	for _, same := range []string{"claude-sonnet-5", "gpt-6-luna", "gpt-6.1-sol", "claude-haiku-4-5-20251001"} {
		if got := copilotFormOf(same); got != same {
			t.Errorf("copilotFormOf(%s) = %s", same, got)
		}
	}
	doc := regDoc()
	d := doc["defaults"].(map[string]any)
	d["build"].(map[string]any)["copilot"] = "claude-sonnet-5-5" // slice 1's registry id
	d["plan"].(map[string]any)["copilot"] = "claude-fable-9"     // nowhere: takes the seed's
	seed := regDoc()
	if !migrateCopilotPicks(doc, seed) {
		t.Fatal("registry-form Copilot picks were not migrated")
	}
	if defaultOf(doc, "build", "copilot") != "claude-sonnet-5.5" || defaultOf(doc, "plan", "copilot") != "claude-opus-5.5" || defaultOf(doc, "reviewer", "copilot") != "gpt-6-luna" {
		t.Errorf("migrated = %v", d)
	}
	if !modelTiersValid(doc) {
		t.Errorf("a migrated registry fails validation: %s", tierDefaultsProblem(doc))
	}
	if migrateCopilotPicks(doc, seed) {
		t.Error("a valid registry was migrated again")
	}
}

// t-aba6: the read path converts a slice-1 file's Copilot picks (registry ids) to Copilot's own ids, and fills a missing fallback list
// from the seed. Protects GET /api/admin/model-tiers and every close after the update.
func TestLoadModelTiersConvertsSliceOneCopilotPicks(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	seed := filepath.Join(dir, "seed.json")
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	raw, _ := json.Marshal(regDoc())
	if err := os.WriteFile(seed, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	user := regDoc()
	delete(user, "copilot_models") // saved by slice 1, before the fallback list existed
	user["defaults"].(map[string]any)["build"].(map[string]any)["copilot"] = "claude-sonnet-5-5"
	ub, _ := json.Marshal(user)
	_ = os.MkdirAll(filepath.Dir(modelTiersUserFile()), 0o755)
	if err := os.WriteFile(modelTiersUserFile(), ub, 0o644); err != nil {
		t.Fatal(err)
	}
	got := loadModelTiers()
	if defaultOf(got, "build", "copilot") != "claude-sonnet-5.5" {
		t.Errorf("a slice-1 Copilot pick was not converted: %v", got["defaults"])
	}
	if _, has := got["copilot_models"]; !has || !modelTiersValid(got) {
		t.Errorf("the fallback list was not filled, or the registry is invalid: %s", tierDefaultsProblem(got))
	}
}
