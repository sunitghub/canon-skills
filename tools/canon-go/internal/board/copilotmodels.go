package board

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// t-aba6 (slice 2 of t-8f6d / t-2cc8): Copilot CLI's own model list, read on a click in Admin > Model tiers (Agent: Copilot CLI). The
// board runs `copilot --acp` (Agent Client Protocol over stdio, newline-delimited JSON-RPC), sends initialize and session/new, and keeps
// the Anthropic and OpenAI models of the session's `models.availableModels` (no model call, no credits). Each read leaves one empty
// session folder in ~/.copilot/session-state (Copilot's own; canon never writes there), which is why it runs only on a click. The list
// is saved to $CANON_HOME/cockpit/copilot-models.json; with none saved the seed's `copilot_models` stand in.

var (
	copilotBin         = "copilot"        // a test points PATH at a stub
	copilotReadTimeout = 20 * time.Second // initialize + session/new answer in about 3 s on a real account
	copilotReadMu      sync.Mutex         // one read at a time
)

const (
	copilotReplyMax  = 1 << 20 // one ACP line; the session/new answer is about 10 KB
	copilotModelsMax = 64
	copilotFieldMax  = 80
)

// copilotModel is one model Copilot CLI offers: its own id (claude-sonnet-5.5), its name and its premium-request multiplier (1x, 0.33x).
type copilotModel struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Usage string `json:"usage,omitempty"`
}

type copilotModelList struct {
	ReadAt string         `json:"read_at"`
	Models []copilotModel `json:"models"`
}

func copilotModelsFile() string { return filepath.Join(registryDir(), "copilot-models.json") }

// copilotFamily: the families a Copilot CLI pick may be (user, 2026-11-14): Anthropic and OpenAI models only.
func copilotFamily(id string) bool {
	return strings.HasPrefix(id, "claude-") || strings.HasPrefix(id, "gpt-")
}

// cleanCopilotText keeps a field Copilot sent as plain printable text, capped: it reaches Admin's page and the cache file.
func cleanCopilotText(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if r := []rune(s); len(r) > copilotFieldMax {
		s = string(r[:copilotFieldMax])
	}
	return s
}

// parseCopilotModels keeps the usable entries of a session/new result: an id canon can store (modelIDRe) in the two families, once each.
func parseCopilotModels(result map[string]any) ([]copilotModel, error) {
	ms, _ := result["models"].(map[string]any)
	avail, ok := ms["availableModels"].([]any)
	if !ok {
		return nil, errors.New("Copilot answered without a model list (signed out?)")
	}
	seen := map[string]bool{}
	out := []copilotModel{}
	for _, raw := range avail {
		m, _ := raw.(map[string]any)
		id, _ := m["modelId"].(string)
		if seen[id] {
			continue
		}
		seen[id] = true
		name, _ := m["name"].(string)
		meta, _ := m["_meta"].(map[string]any)
		usage, _ := meta["copilotUsage"].(string)
		out = append(out, keepCopilotModels([]copilotModel{{ID: id, Name: name, Usage: usage}})...)
		if len(out) == copilotModelsMax {
			break
		}
	}
	if len(out) == 0 {
		return nil, errors.New("Copilot listed no Claude or GPT model")
	}
	return out, nil
}

// readCopilotModels runs one ACP exchange and returns the models, or a one-line reason. Fixed arguments, a fresh empty folder as cwd
// (removed after), no request data; stdin is closed and the process waited for, and killed at the deadline.
func readCopilotModels(ctx context.Context) ([]copilotModel, error) {
	bin, err := exec.LookPath(copilotBin)
	if err != nil {
		return nil, errors.New("Copilot CLI is not installed (no copilot on PATH)")
	}
	dir, err := os.MkdirTemp("", "canon-copilot-models-")
	if err != nil {
		return nil, fmt.Errorf("could not make a folder to run Copilot in: %v", err)
	}
	defer os.RemoveAll(dir)
	ctx, cancel := context.WithTimeout(ctx, copilotReadTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--acp")
	cmd.Dir = dir
	cmd.WaitDelay = 2 * time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("could not start Copilot CLI: %v", err)
	}
	defer func() { _ = stdin.Close(); _ = cmd.Wait() }()
	// Lines are read in their own goroutine so the deadline holds even when a child of copilot keeps the pipe open after the kill;
	// cmd.WaitDelay then closes the pipes, which ends this goroutine.
	lineCh := make(chan []byte)
	go func() {
		defer close(lineCh)
		sc := bufio.NewScanner(io.LimitReader(stdout, 4*copilotReplyMax))
		sc.Buffer(make([]byte, 64*1024), copilotReplyMax)
		for sc.Scan() {
			select {
			case lineCh <- append([]byte(nil), sc.Bytes()...):
			case <-ctx.Done():
				return
			}
		}
	}()
	send := func(id int, method string, params map[string]any) error {
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		_, err := stdin.Write(append(b, '\n'))
		return err
	}
	answer := func(id int) (map[string]any, error) {
		for {
			select {
			case <-ctx.Done():
				return nil, fmt.Errorf("Copilot CLI did not answer within %s", copilotReadTimeout)
			case line, ok := <-lineCh:
				if !ok {
					if ctx.Err() != nil {
						return nil, fmt.Errorf("Copilot CLI did not answer within %s", copilotReadTimeout)
					}
					return nil, errors.New("Copilot CLI stopped before it answered")
				}
				var msg map[string]any
				if json.Unmarshal(line, &msg) != nil {
					continue // a notification or log line Copilot writes between answers
				}
				if n, ok := msg["id"].(float64); !ok || int(n) != id {
					continue
				}
				if e, ok := msg["error"].(map[string]any); ok {
					return nil, fmt.Errorf("Copilot refused: %s", cleanCopilotText(fmt.Sprint(e["message"])))
				}
				res, _ := msg["result"].(map[string]any)
				return res, nil
			}
		}
	}
	if err := send(1, "initialize", map[string]any{"protocolVersion": 1, "clientCapabilities": map[string]any{}}); err != nil {
		return nil, errors.New("Copilot CLI stopped before it answered")
	}
	if _, err := answer(1); err != nil {
		return nil, err
	}
	if err := send(2, "session/new", map[string]any{"cwd": dir, "mcpServers": []any{}}); err != nil {
		return nil, errors.New("Copilot CLI stopped before it answered")
	}
	res, err := answer(2)
	if err != nil {
		return nil, err
	}
	return parseCopilotModels(res)
}

// copilotGroup is the group a Copilot model is listed under in Admin: its family.
func copilotGroup(id string) string {
	if strings.HasPrefix(id, "gpt-") {
		return "OpenAI"
	}
	return "Anthropic"
}

// keepCopilotModels is the one filter for a list from any source (a read, the saved file, the fallback): ids canon can store, in the two
// families, text cleaned.
func keepCopilotModels(in []copilotModel) []copilotModel {
	out := []copilotModel{}
	for _, m := range in {
		if modelIDRe.MatchString(m.ID) && copilotFamily(m.ID) {
			out = append(out, copilotModel{ID: m.ID, Name: cleanCopilotText(m.Name), Usage: cleanCopilotText(m.Usage)})
		}
	}
	return out
}

// savedCopilotModels is the list Admin shows and validation reads: the saved read, else the registry's fallback `copilot_models`
// (loadModelTiers fills it from the seed when a user file has none).
func savedCopilotModels(doc map[string]any) (list copilotModelList, source string) {
	if b, err := os.ReadFile(copilotModelsFile()); err == nil && json.Unmarshal(b, &list) == nil {
		if list.Models = keepCopilotModels(list.Models); len(list.Models) > 0 {
			return list, "copilot"
		}
	}
	var fallback []copilotModel
	if b, err := json.Marshal(doc["copilot_models"]); err == nil {
		_ = json.Unmarshal(b, &fallback)
	}
	return copilotModelList{Models: keepCopilotModels(fallback)}, "fallback"
}

// copilotPickIDs is the set a Copilot CLI pick in doc may name.
func copilotPickIDs(doc map[string]any) map[string]bool {
	list, _ := savedCopilotModels(doc)
	ids := map[string]bool{}
	for _, m := range list.Models {
		ids[m.ID] = true
	}
	return ids
}

// copilotModelsView answers GET /api/admin/copilot-models: the list, where it came from and when it was read.
func copilotModelsView() map[string]any {
	list, source := savedCopilotModels(loadModelTiers())
	return map[string]any{"ok": true, "source": source, "read_at": list.ReadAt, "models": list.Models}
}

// readAndSaveCopilotModels is the click: read, then save. A failed read keeps the old file and answers with the reason.
func readAndSaveCopilotModels(ctx context.Context) map[string]any {
	if !copilotReadMu.TryLock() {
		return map[string]any{"ok": false, "error": "a read of Copilot's models is already running"}
	}
	defer copilotReadMu.Unlock()
	models, err := readCopilotModels(ctx)
	if err != nil {
		res := copilotModelsView()
		res["ok"], res["error"] = false, err.Error()
		return res
	}
	b, _ := json.MarshalIndent(copilotModelList{ReadAt: time.Now().UTC().Format(time.RFC3339), Models: models}, "", "  ")
	if err := os.MkdirAll(registryDir(), 0o700); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	tmp := copilotModelsFile() + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if err := os.Rename(tmp, copilotModelsFile()); err != nil {
		_ = os.Remove(tmp)
		return map[string]any{"ok": false, "error": err.Error()}
	}
	return copilotModelsView()
}
