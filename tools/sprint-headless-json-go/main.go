// sprint-headless-json-go builds the Windows-only helper compiled to
// tools/sprint-headless-json-win.exe. It replaces the JSON-parsing half of
// tools/sprint-headless's two python3 calls (`claude -p --output-format
// json`'s output -> is_error/session_id/result) so a Windows machine
// without python3 installed can still run sprint-headless. Output contract
// matches the python3 step byte-for-byte: one line,
// "<is_error>\t<session_id>\t<result>", is_error rendered "True"/"False"
// (not lowercase) to match Python's str(bool), result's embedded newlines
// re-encoded as \x02 so the caller can safely read the line with `cut`
// before restoring them with `tr '\002' '\n'`.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

type headlessResult struct {
	IsError   *bool   `json:"is_error"`
	SessionID *string `json:"session_id"`
	Result    *string `json:"result"`
}

// formatResult mirrors the python3 step: on any parse failure, matches its
// "PARSE_ERROR\t\t" fallback (deliberately not an error exit — the caller's
// own IS_ERROR != "False" check already turns that into a hard failure).
func formatResult(data []byte) string {
	var r headlessResult
	if err := json.Unmarshal(data, &r); err != nil {
		return "PARSE_ERROR\t\t"
	}

	isError := "True"
	if r.IsError != nil && !*r.IsError {
		isError = "False"
	}

	sessionID := "unknown"
	if r.SessionID != nil {
		sessionID = *r.SessionID
	}

	result := ""
	if r.Result != nil {
		result = strings.ReplaceAll(*r.Result, "\n", "\x02")
	}

	return fmt.Sprintf("%s\t%s\t%s", isError, sessionID, result)
}

func main() {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "sprint-headless-json-win: failed to read stdin:", err)
		os.Exit(1)
	}
	fmt.Println(formatResult(data))
}
