package parsers

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/sunitghub/canon-skills/internal/models"
)

var AgentRunLogPaths = []string{
	".canon/subagent-runs.jsonl",
	".claude/subagent-runs.jsonl",
	".opencode/subagent-runs.jsonl",
}

const subagentRunWindowSec = 600

func ParseTickets(ticketsDir string) (tickets []models.Ticket, warnings []string) {
	entries, err := os.ReadDir(ticketsDir)
	if err != nil {
		warnings = append(warnings, fmt.Sprintf("failed to read tickets dir: %v", err))
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		ticketFile := filepath.Join(ticketsDir, entry.Name(), "ticket.md")
		content, err := os.ReadFile(ticketFile)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("cannot read %s: %v", ticketFile, err))
			continue
		}
		data := ParseFrontmatterRaw(string(content))
		if data["id"] == "" {
			body := strings.ReplaceAll(string(content), "\r", "")
			firstLine := strings.SplitN(strings.TrimSpace(body), "\n", 2)[0]
			if firstLine != "" {
				firstLine = strings.TrimLeft(firstLine, "#")
				firstLine = strings.TrimSpace(firstLine)
				if firstLine != "" {
					data["id"] = firstLine
					data["title"] = firstLine
				}
			}
		}
		acceptance := extractSection(string(content), "Acceptance Criteria")
		description := extractSection(string(content), "Description")

		tickets = append(tickets, models.Ticket{
			ID:                 getStr(data, "id", "unknown"),
			Status:             getStr(data, "status", "unknown"),
			Title:              getStr(data, "title", "No Title"),
			Description:        description,
			AcceptanceCriteria: acceptance,
			Priority:           data["priority"],
		})
	}
	return
}

func ParseHandoff(handoffPath string) models.Handoff {
	content, err := os.ReadFile(handoffPath)
	if err != nil {
		return models.Handoff{ActiveTasks: []string{}, Context: "Extracted from HANDOFF.md"}
	}
	tasks := extractTasks(string(content))
	return models.Handoff{
		ActiveTasks: tasks,
		Context:     "Extracted from HANDOFF.md",
	}
}

func ParsePlanApproved(planPath string) bool {
	content, err := os.ReadFile(planPath)
	if err != nil {
		return false
	}
	signoff := extractSection(string(content), "Sign-off")
	re := regexp.MustCompile(`(?mi)^\s*[-*]\s+\[[xX]\]\s+Plan approved`)
	return re.MatchString(signoff)
}

func ParsePlanDecision(planPath string) string {
	content, err := os.ReadFile(planPath)
	if err != nil {
		return ""
	}
	decisions := extractSection(string(content), "Decisions")
	for _, line := range strings.Split(decisions, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "### ") {
			return strings.TrimPrefix(line, "### ")
		}
	}
	return ""
}

func CheckSubagentRun(projectRoot string, runEpoch int64) bool {
	for _, rel := range AgentRunLogPaths {
		if checkFile(projectRoot, rel, runEpoch) {
			return true
		}
	}
	return false
}

func checkFile(root, rel string, runEpoch int64) bool {
	f, err := os.Open(filepath.Join(root, rel))
	if err != nil {
		return false
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			continue
		}
		ts, ok := entry["ts"].(string)
		if !ok || ts == "" {
			continue
		}
		entryEpoch, err := parseTimestamp(ts)
		if err != nil {
			continue
		}
		diff := entryEpoch - runEpoch
		if diff < 0 {
			diff = -diff
		}
		if diff <= subagentRunWindowSec {
			return true
		}
	}
	if err := scanner.Err(); err != nil {
		return false
	}
	return false
}

func ParseFrontmatterRaw(content string) map[string]string {
	data := make(map[string]string)
	re := regexp.MustCompile(`(?s)^---\r?\n(.*?)\r?\n---`)
	m := re.FindStringSubmatch(content)
	if m == nil {
		return data
	}
	body := strings.ReplaceAll(m[1], "\r", "")
	for _, line := range strings.Split(body, "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(strings.ToLower(parts[0]))
			val := strings.TrimSpace(parts[1])
			if len(val) >= 2 && val[0] == '"' {
				if idx := strings.LastIndex(val, `"`); idx > 0 {
					val = val[1:idx]
				} else {
					val = val[1:]
				}
			}
			data[key] = val
		}
	}
	return data
}

var (
	headingRe    = regexp.MustCompile(`(?m)^## `)
	headingCache sync.Map
)

func headingPattern(heading string) *regexp.Regexp {
	if v, ok := headingCache.Load(heading); ok {
		return v.(*regexp.Regexp)
	}
	re := regexp.MustCompile(fmt.Sprintf(`(?m)^## %s\s*$`, regexp.QuoteMeta(heading)))
	actual, _ := headingCache.LoadOrStore(heading, re)
	return actual.(*regexp.Regexp)
}

func extractSection(content, heading string) string {
	pattern := headingPattern(heading)
	loc := pattern.FindStringIndex(content)
	if loc == nil {
		return ""
	}
	after := content[loc[1]:]
	nextLoc := headingRe.FindStringIndex(after)
	if nextLoc == nil {
		return strings.TrimSpace(after)
	}
	return strings.TrimSpace(after[:nextLoc[0]])
}

func extractTasks(content string) []string {
	var tasks []string
	pattern := headingPattern("Active Tasks")
	loc := pattern.FindStringIndex(content)
	if loc == nil {
		return tasks
	}
	after := content[loc[1]:]
	nextLoc := headingRe.FindStringIndex(after)
	var section string
	if nextLoc == nil {
		section = strings.TrimSpace(after)
	} else {
		section = strings.TrimSpace(after[:nextLoc[0]])
	}
	if section == "" {
		return tasks
	}
	for _, line := range strings.Split(section, "\n") {
		line = strings.TrimSpace(line)
		line = boldRe.ReplaceAllString(line, "$1")
		line = italicRe.ReplaceAllString(line, "$1")
		if line != "" && strings.HasPrefix(line, "- ") {
			tasks = append(tasks, strings.TrimPrefix(line, "- "))
		}
	}
	return tasks
}

var (
	boldRe   = regexp.MustCompile(`\*\*(.*?)\*\*`)
	italicRe = regexp.MustCompile(`\*(.*?)\*`)
)

func parseTimestamp(ts string) (int64, error) {
	normalized := ts
	if strings.HasSuffix(ts, "Z") {
		normalized = ts[:len(ts)-1] + "+00:00"
	}
	for _, format := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05"} {
		t, err := time.Parse(format, normalized)
		if err == nil {
			return t.Unix(), nil
		}
	}
	return 0, fmt.Errorf("cannot parse timestamp: %s", ts)
}

func getStr(data map[string]string, key, fallback string) string {
	if v, ok := data[key]; ok && v != "" {
		return v
	}
	return fallback
}
