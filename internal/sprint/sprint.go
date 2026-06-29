package sprint

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/sunitghub/canon-skills/internal/commands"
	"github.com/sunitghub/canon-skills/internal/models"
	"github.com/sunitghub/canon-skills/internal/parsers"
)

// trivialTierRe matches a top-level frontmatter field `tier: trivial` (case-insensitive).
var trivialTierRe = regexp.MustCompile(`(?im)^tier\s*:\s*"?trivial"?\s*$`)

var verdictPassRe = regexp.MustCompile(`(?m)^pass:\s*\S`)
var runIDRe = regexp.MustCompile(`(?m)^evaluator-run-id:\s+(\S+)`)
var verdictLineRe = regexp.MustCompile(`(?m)^(pass|fail):`)

var frontmatterExtractRe = regexp.MustCompile(`(?s)^---\r?\n(.*?)\r?\n---`)

// hasFrontmatter reports whether content begins with a YAML frontmatter fence.
func hasFrontmatter(content string) (string, bool) {
	m := frontmatterExtractRe.FindStringSubmatch(content)
	if m == nil {
		return "", false
	}
	return m[1], true
}

func GetSprintBoard(projectRoot string) map[string]any {
	ticketsDir := filepath.Join(projectRoot, ".tickets")
	tickets, warnings := parsers.ParseTickets(ticketsDir)
	handoff := parsers.ParseHandoff(filepath.Join(projectRoot, "HANDOFF.md"))

	var ticketList []any
	for _, t := range tickets {
		planPath := filepath.Join(ticketsDir, t.ID, "plan.md")
		ticketList = append(ticketList, map[string]any{
			"id":                  t.ID,
			"status":              t.Status,
			"title":               t.Title,
			"description":         t.Description,
			"priority":            t.Priority,
			"acceptance_criteria": t.AcceptanceCriteria,
			"plan_approved":       parsers.ParsePlanApproved(planPath),
			"plan_decision":       parsers.ParsePlanDecision(planPath),
		})
	}
	if ticketList == nil {
		ticketList = []any{}
	}

	result := map[string]any{
		"tickets":      ticketList,
		"handoff":      handoff,
		"project_root": projectRoot,
	}
	if len(warnings) > 0 {
		result["warnings"] = warnings
	}
	return result
}

func LogSubagentRun(projectRoot, agentID, agentType, sessionID string) map[string]any {
	ts := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	entry := map[string]any{
		"ts":              ts,
		"session_id":      sessionID,
		"agent_id":        agentID,
		"agent_type":      agentType,
		"transcript_path": "",
	}
	rel := parsers.AgentRunLogPaths[0]
	logFile := filepath.Join(projectRoot, rel)
	if err := os.MkdirAll(filepath.Dir(logFile), 0755); err != nil {
		return map[string]any{"error": fmt.Sprintf("cannot create log dir: %v", err)}
	}
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("cannot open log: %v", err)}
	}
	defer f.Close()
	if err := json.NewEncoder(f).Encode(entry); err != nil {
		return map[string]any{"error": fmt.Sprintf("failed to encode log entry: %v", err)}
	}
	return map[string]any{"status": "ok", "entry": entry}
}

func StartSprint(projectRoot, title, ticketID, priority string) map[string]any {
	commands.Lock()
	defer commands.Unlock()
	ticketsDir := filepath.Join(projectRoot, ".tickets")

	var tid string
	if ticketID != "" {
		tdir := filepath.Join(ticketsDir, ticketID)
		if _, err := os.Stat(tdir); err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return map[string]any{"error": fmt.Sprintf("Cannot access ticket '%s': not found", ticketID)}
			}
			return map[string]any{"error": fmt.Sprintf("Cannot access ticket '%s': %v", ticketID, err)}
		}
		tid = ticketID
	} else {
		result := commands.CreateSprintTicketLocked(ticketsDir, title, priority)
		if err, ok := result["error"]; ok {
			return map[string]any{"error": err}
		}
		var ok bool
		tid, ok = result["ticket_id"].(string)
		if !ok {
			return map[string]any{"error": "internal error: CreateSprintTicket returned no ticket_id"}
		}
	}

	tdir := filepath.Join(ticketsDir, tid)
	planFile := filepath.Join(tdir, "plan.md")
	if _, err := os.Stat(planFile); err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			return map[string]any{"error": fmt.Sprintf("Cannot stat plan.md: %v", err)}
		}
		if err := os.WriteFile(planFile, []byte(
			fmt.Sprintf("---\nid: %s\n---\n\n# Plan\n\nTicket: `%s`\n\n## Sign-off\n\n- [ ] Plan approved — proceed to implementation\n\n## Approach\n\n\n## Files\n\n\n## Decisions\n\n", tid, tid),
		), 0644); err != nil {
			return map[string]any{"error": fmt.Sprintf("Failed to write plan.md: %v", err)}
		}
	}

	for _, pair := range [][2]string{
		{filepath.Join(projectRoot, "DECISIONS.md"), "# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n"},
		{filepath.Join(projectRoot, "HANDOFF.md"), "# Handoff\n\n## Current Focus\n\n## In Progress\n\n## Discoveries\n\n## Next Steps\n\n1. \n"},
	} {
		if _, err := os.Stat(pair[0]); err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				return map[string]any{"error": fmt.Sprintf("Cannot stat %s: %v", pair[0], err)}
			}
			if err := os.WriteFile(pair[0], []byte(pair[1]), 0644); err != nil {
				return map[string]any{"error": fmt.Sprintf("Failed to write %s: %v", pair[0], err)}
			}
		}
	}

	if err := os.WriteFile(filepath.Join(ticketsDir, "ACTIVE"), []byte(tid+"\n"), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write ACTIVE file: %v", err)}
	}

	return map[string]any{
		"ticket_id":  tid,
		"ticket_dir": tdir,
		"status":     "ok",
		"message":    fmt.Sprintf("Sprint started: %s", tid),
	}
}

func readActiveSprintID(ticketsDir string) string {
	activePath := filepath.Join(ticketsDir, "ACTIVE")
	content, err := os.ReadFile(activePath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(content))
}

func CloseSprint(projectRoot string) map[string]any {
	commands.Lock()
	defer commands.Unlock()
	ticketsDir := filepath.Join(projectRoot, ".tickets")
	handoffPath := filepath.Join(projectRoot, "HANDOFF.md")

	tickets, _ := parsers.ParseTickets(ticketsDir)

	if len(tickets) == 0 {
		return map[string]any{"status": "error", "message": "No tickets found. Nothing to close."}
	}

	// Sort by ID for deterministic fallback selection when ACTIVE is missing.
	sort.Slice(tickets, func(i, j int) bool { return tickets[i].ID < tickets[j].ID })

	var nonTrivial []models.Ticket
	for _, t := range tickets {
		planPath := filepath.Join(ticketsDir, t.ID, "plan.md")
		planContent, err := os.ReadFile(planPath)
		if err == nil {
			if fm, ok := hasFrontmatter(string(planContent)); ok && trivialTierRe.MatchString(fm) {
				continue
			}
		}
		nonTrivial = append(nonTrivial, t)
	}

	terminalStatuses := map[string]bool{"closed": true, "cancelled": true, "archived": true}
	var incomplete []string
	for _, t := range nonTrivial {
		if !terminalStatuses[strings.ToLower(t.Status)] {
			incomplete = append(incomplete, t.ID)
		}
	}
	if len(incomplete) > 0 {
		return map[string]any{
			"status":  "error",
			"message": fmt.Sprintf("Cannot close sprint. The following tickets are not terminal (closed/cancelled/archived): %s", strings.Join(incomplete, ", ")),
		}
	}

	for _, t := range nonTrivial {
		tdir := filepath.Join(ticketsDir, t.ID)
		reportPath := filepath.Join(tdir, "eval-report.md")

		reportContent, err := os.ReadFile(reportPath)
		if err != nil {
			return map[string]any{
				"status":  "error",
				"message": fmt.Sprintf("Ticket %s cannot close: eval-report.md is missing. Run the evaluator (eval skill) before closing, or mark the ticket as trivial via 'tier: trivial' in plan.md frontmatter.", t.ID),
			}
		}

		runIDMatch := runIDRe.FindStringSubmatch(string(reportContent))
		if runIDMatch == nil {
			return map[string]any{
				"status":  "error",
				"message": fmt.Sprintf("Ticket %s cannot close: eval-report.md is missing evaluator-run-id field.", t.ID),
			}
		}

		runID := runIDMatch[1]
		runIDParts := strings.SplitN(runID, "-", 3)
		if len(runIDParts) < 2 {
			return map[string]any{
				"status":  "error",
				"message": fmt.Sprintf("Ticket %s cannot close: evaluator-run-id '%s' format is invalid. Expected <epoch>-<counter>.", t.ID, runID),
			}
		}
		var runEpoch int64
		if _, err := fmt.Sscanf(runIDParts[0], "%d", &runEpoch); err != nil {
			return map[string]any{
				"status":  "error",
				"message": fmt.Sprintf("Ticket %s cannot close: evaluator-run-id '%s' has non-numeric epoch.", t.ID, runID),
			}
		}
		matched := parsers.CheckSubagentRun(projectRoot, runEpoch)
		if !matched {
			return map[string]any{
				"status":  "error",
				"message": fmt.Sprintf("Ticket %s cannot close: evaluator-run-id '%s' has no matching subagent entry in .canon/.claude/.opencode subagent-runs.jsonl (±10 min window).", t.ID, runID),
			}
		}

		if !verdictPassRe.Match(reportContent) {
			verdictLine := "(no verdict line found)"
			if m := verdictLineRe.FindString(string(reportContent)); m != "" {
				verdictLine = m
			}
			return map[string]any{
				"status":  "error",
				"message": fmt.Sprintf("Ticket %s cannot close: eval-report.md verdict is not pass. %s", t.ID, verdictLine),
			}
		}
	}

	var receiptLines []string
	receiptLines = append(receiptLines, "## Delivery Receipt", "| Ticket ID | Status | Title |", "| --- | --- | --- |")
	for _, t := range tickets {
		esc := func(s string) string { return strings.ReplaceAll(s, "|", "\\|") }
		receiptLines = append(receiptLines, fmt.Sprintf("| %s | %s | %s |", esc(t.ID), esc(t.Status), esc(t.Title)))
	}
	receiptContent := strings.Join(receiptLines, "\n")

	handoffBytes, err := os.ReadFile(handoffPath)
	if err != nil {
		return map[string]any{"status": "error", "message": "HANDOFF.md not found"}
	}
	handoffContent := string(handoffBytes)

	sprintID := readActiveSprintID(ticketsDir)
	if sprintID == "" {
		for _, t := range nonTrivial {
			if terminalStatuses[strings.ToLower(t.Status)] {
				sprintID = t.ID
				break
			}
		}
		if sprintID == "" {
			sprintID = tickets[0].ID
		}
	}
	summaryHeading := fmt.Sprintf("## Sprint Summary (%s)", sprintID)
	if regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(summaryHeading) + `$`).MatchString(handoffContent) {
		return map[string]any{
			"status":  "error",
			"message": fmt.Sprintf("Sprint %s already has a summary in HANDOFF.md. Remove the existing section first if you need to re-close.", sprintID),
		}
	}

	summarySection := fmt.Sprintf("\n\n%s\n%s\n", summaryHeading, receiptContent)
	newHandoff := strings.TrimRight(handoffContent, " \t\r\n") + summarySection
	tmpPath := handoffPath + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(newHandoff), 0644); err != nil {
		return map[string]any{"status": "error", "message": fmt.Sprintf("Failed to write HANDOFF.md: %v", err)}
	}
	if err := os.Rename(tmpPath, handoffPath); err != nil {
		os.Remove(tmpPath)
		return map[string]any{"status": "error", "message": fmt.Sprintf("Failed to atomically write HANDOFF.md: %v", err)}
	}

	return map[string]any{
		"status":  "ok",
		"message": "Sprint closed successfully and HANDOFF.md updated.",
		"receipt": receiptContent,
	}
}
