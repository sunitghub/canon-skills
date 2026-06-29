package commands

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/sunitghub/canon-skills/internal/parsers"
)

// ticketIDRe matches the sequential TKT-NNNN format.
var ticketIDRe = regexp.MustCompile(`^TKT-(\d+)$`)

// nextTicketID scans the tickets directory and returns the next sequential
// ticket number. Returns 1 when the directory is empty or missing.
func nextTicketID(ticketsDir string) uint64 {
	entries, err := os.ReadDir(ticketsDir)
	if err != nil {
		return 1
	}
	var maxN uint64
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if m := ticketIDRe.FindStringSubmatch(e.Name()); m != nil {
			if n, err := strconv.ParseUint(m[1], 10, 64); err == nil && n > maxN {
				maxN = n
			}
		}
	}
	return maxN + 1
}

var mu sync.RWMutex

func Lock()   { mu.Lock() }
func Unlock() { mu.Unlock() }

var winReserved = []string{"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"}

var validTicketIDRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

var frontmatterRe = regexp.MustCompile(`(?s)^(---\r?\n.*?\r?\n---)\r?\n?(.*)$`)
var statusLineRe = regexp.MustCompile(`(?m)^status:.*$`)

var numRe = regexp.MustCompile(`^(\d+)\.\s`)
var bulletRe = regexp.MustCompile(`^[-*]\s`)

func validTicketID(id string) error {
	if id == "" {
		return errors.New("invalid ticket ID: empty")
	}
	if strings.Contains(id, "..") || strings.ContainsAny(id, "/\\") {
		return errors.New("invalid ticket ID: illegal characters")
	}
	cleaned := filepath.Clean(id)
	if cleaned != id {
		return errors.New("invalid ticket ID")
	}
	for _, r := range winReserved {
		if strings.EqualFold(id, r) {
			return errors.New("invalid ticket ID: reserved name")
		}
	}
	if !validTicketIDRe.MatchString(id) {
		return errors.New("invalid ticket ID: must match ^[A-Za-z0-9][A-Za-z0-9_-]*$")
	}
	return nil
}

var ValidStatuses = map[string]bool{
	"open": true, "in_progress": true, "closed": true,
	"cancelled": true, "archived": true,
}

func AddAcceptanceCriterion(ticketsDir, ticketID, criterionText string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	mu.Lock()
	defer mu.Unlock()
	acceptanceFile := filepath.Join(ticketsDir, ticketID, "acceptance.md")
	content, err := os.ReadFile(acceptanceFile)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("acceptance.md not found for ticket %s", ticketID)}
	}
	body := string(content)

	acceptanceHeading := "## Acceptance Criteria"
	headingIdx := strings.Index(body, acceptanceHeading)
	if headingIdx == -1 {
		newContent := fmt.Sprintf("%s\n- [ ] %s\n", acceptanceHeading, criterionText)
		if err := os.WriteFile(acceptanceFile, []byte(newContent), 0644); err != nil {
			return map[string]any{"error": fmt.Sprintf("Failed to write acceptance.md: %v", err)}
		}
		return map[string]any{"ticket_id": ticketID, "criterion": criterionText, "status": "ok"}
	}

	sectionStart := headingIdx + len(acceptanceHeading)
	after := body[sectionStart:]
	nextHeadingIdx := strings.Index(after, "\n## ")
	sectionEnd := len(body)
	if nextHeadingIdx >= 0 {
		sectionEnd = sectionStart + nextHeadingIdx
	}
	section := body[sectionStart:sectionEnd]

	lines := strings.Split(section, "\n")
	lineStart := 0
	for lineStart < len(lines) && strings.TrimSpace(lines[lineStart]) == "" {
		lineStart++
	}

	lastNum := 0
	isNumbered := false
	foundExisting := false
	lastItemLineIdx := -1

	for i := lineStart; i < len(lines); i++ {
		stripped := strings.TrimSpace(lines[i])
		if stripped == "" {
			continue
		}
		if m := numRe.FindStringSubmatch(stripped); m != nil {
			isNumbered = true
			lastNum, _ = strconv.Atoi(m[1])
			foundExisting = true
			lastItemLineIdx = i
		} else if bulletRe.MatchString(stripped) {
			foundExisting = true
			lastItemLineIdx = i
		} else {
			break
		}
	}

	var newItem string
	if !foundExisting {
		newItem = fmt.Sprintf("\n- [ ] %s", criterionText)
	} else if isNumbered {
		newItem = fmt.Sprintf("\n%d. [ ] %s", lastNum+1, criterionText)
	} else {
		newItem = fmt.Sprintf("\n- [ ] %s", criterionText)
	}

	var insertOffset int
	if lastItemLineIdx >= 0 {
		sectionPrefix := strings.Join(lines[:lastItemLineIdx+1], "\n")
		insertOffset = sectionStart + len(sectionPrefix)
	} else {
		insertOffset = sectionStart
	}

	before := body[:insertOffset]
	afterPart := body[insertOffset:]
	newContent := before + newItem + afterPart
	if err := os.WriteFile(acceptanceFile, []byte(newContent), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write acceptance.md: %v", err)}
	}
	return map[string]any{"ticket_id": ticketID, "criterion": criterionText, "status": "ok"}
}

func CreateSprintTicket(ticketsDir, description, priority string) map[string]any {
	mu.Lock()
	defer mu.Unlock()
	return createSprintTicketLocked(ticketsDir, description, priority)
}

// CreateSprintTicketLocked must be called with mu held.
func CreateSprintTicketLocked(ticketsDir, description, priority string) map[string]any {
	return createSprintTicketLocked(ticketsDir, description, priority)
}

func createSprintTicketLocked(ticketsDir, description, priority string) map[string]any {
	if err := os.MkdirAll(ticketsDir, 0755); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to create tickets directory: %v", err)}
	}
	var ticketID string
	nextID := nextTicketID(ticketsDir)
	for i := 0; i < 100; i++ {
		candidate := fmt.Sprintf("TKT-%04d", nextID+uint64(i))
		ticketDir := filepath.Join(ticketsDir, candidate)
		if err := os.Mkdir(ticketDir, 0755); err == nil {
			ticketID = candidate
			break
		}
	}
	if ticketID == "" {
		return map[string]any{"error": "Failed to generate unique ticket ID after 100 attempts"}
	}

	title := description
	if len(title) > 50 {
		trunc := title[:47]
		if idx := strings.LastIndex(trunc, " "); idx > 0 {
			title = trunc[:idx] + "..."
		} else {
			title = trunc + "..."
		}
	}
	safeTitle := yamlEscape(title)
	safePriority := yamlEscape(priority)

	ticketFile := filepath.Join(ticketsDir, ticketID, "ticket.md")
	if err := os.WriteFile(ticketFile, []byte(fmt.Sprintf(
		"---\nid: %s\ntitle: \"%s\"\nstatus: open\npriority: %s\n---\n\n## Description\n%s\n\n## Acceptance Criteria\n",
		ticketID, safeTitle, safePriority, description,
	)), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write ticket.md: %v", err)}
	}

	if err := os.WriteFile(filepath.Join(ticketsDir, ticketID, "acceptance.md"), []byte("## Acceptance Criteria\n"), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write acceptance.md: %v", err)}
	}
	if err := os.WriteFile(filepath.Join(ticketsDir, ticketID, "test_plan.md"), []byte("## Test Plan\n"), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write test_plan.md: %v", err)}
	}

	return map[string]any{"ticket_id": ticketID, "status": "ok"}
}

func UpdateTicketStatus(ticketsDir, ticketID, newStatus string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	if !ValidStatuses[newStatus] {
		return map[string]any{"error": fmt.Sprintf("Invalid status '%s'. Must be one of: open, in_progress, closed, cancelled, archived", newStatus)}
	}
	mu.Lock()
	defer mu.Unlock()
	ticketFile := filepath.Join(ticketsDir, ticketID, "ticket.md")
	content, err := os.ReadFile(ticketFile)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("Ticket %s not found", ticketID)}
	}
	m := frontmatterRe.FindStringSubmatch(string(content))
	if m == nil {
		return map[string]any{"error": "ticket.md has no frontmatter"}
	}
	newFrontmatter := statusLineRe.ReplaceAllString(m[1], "status: "+newStatus)
	newContent := newFrontmatter + "\n\n" + strings.TrimLeft(m[2], "\n")
	if err := os.WriteFile(ticketFile, []byte(newContent), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write ticket.md: %v", err)}
	}
	return map[string]any{"ticket_id": ticketID, "new_status": newStatus, "status": "ok"}
}

func GetTicket(ticketsDir, ticketID string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	mu.RLock()
	defer mu.RUnlock()
	ticketDir := filepath.Join(ticketsDir, ticketID)
	if _, err := os.Stat(ticketDir); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return map[string]any{"error": fmt.Sprintf("Ticket '%s' not found at %s", ticketID, ticketDir)}
		}
		return map[string]any{"error": fmt.Sprintf("Cannot stat ticket '%s': %v", ticketID, err)}
	}

	result := map[string]any{"ticket_id": ticketID, "files": map[string]string{}}
	files := result["files"].(map[string]string)

	for _, fname := range []string{"ticket.md", "acceptance.md", "plan.md", "summary.md", "test_plan.md"} {
		fpath := filepath.Join(ticketDir, fname)
		content, err := os.ReadFile(fpath)
		if err == nil {
			files[fname] = string(content)
		}
	}

	planPath := filepath.Join(ticketDir, "plan.md")
	result["plan"] = map[string]any{
		"approved": parsers.ParsePlanApproved(planPath),
		"decision": parsers.ParsePlanDecision(planPath),
	}
	return result
}

func GetTicketBody(ticketsDir, ticketID string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	mu.RLock()
	defer mu.RUnlock()
	ticketFile := filepath.Join(ticketsDir, ticketID, "ticket.md")
	content, err := os.ReadFile(ticketFile)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("Ticket %s not found", ticketID)}
	}
	m := frontmatterRe.FindStringSubmatch(string(content))
	if m == nil {
		return map[string]any{"content": strings.TrimSpace(string(content))}
	}
	return map[string]any{"content": strings.TrimSpace(m[2])}
}

func UpdateTicketBody(ticketsDir, ticketID, body string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	mu.Lock()
	defer mu.Unlock()
	ticketFile := filepath.Join(ticketsDir, ticketID, "ticket.md")
	content, err := os.ReadFile(ticketFile)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("Ticket %s not found", ticketID)}
	}
	if strings.TrimSpace(body) == "" {
		return map[string]any{"error": "Ticket body cannot be empty"}
	}

	var newContent string
	if m := frontmatterRe.FindStringSubmatch(string(content)); m != nil {
		newContent = m[1] + "\n\n" + strings.TrimLeft(body, "\n")
	} else {
		newContent = body
	}
	if err := os.WriteFile(ticketFile, []byte(newContent), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write ticket.md: %v", err)}
	}
	return map[string]any{"ticket_id": ticketID, "status": "ok"}
}

func ReadDoc(ticketsDir, ticketID, docName string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	mu.RLock()
	defer mu.RUnlock()
	docName = strings.ToLower(docName)
	validDocs := map[string]bool{"acceptance.md": true, "plan.md": true, "test_plan.md": true, "summary.md": true}
	if !validDocs[docName] {
		return map[string]any{"error": fmt.Sprintf("Invalid doc_name '%s'. Must be one of: acceptance.md, plan.md, test_plan.md, summary.md", docName)}
	}
	docPath := filepath.Join(ticketsDir, ticketID, docName)
	content, err := os.ReadFile(docPath)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("Document '%s' not found for ticket %s", docName, ticketID)}
	}
	return map[string]any{"ticket_id": ticketID, "doc_name": docName, "content": string(content)}
}

func WriteDoc(ticketsDir, ticketID, docName, content string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s': %v", ticketID, err)}
	}
	mu.Lock()
	defer mu.Unlock()
	docName = strings.ToLower(docName)
	validDocs := map[string]bool{"acceptance.md": true, "plan.md": true, "test_plan.md": true, "summary.md": true}
	if !validDocs[docName] {
		return map[string]any{"error": fmt.Sprintf("Invalid doc_name '%s'. Must be one of: acceptance.md, plan.md, test_plan.md, summary.md", docName)}
	}
	ticketDir := filepath.Join(ticketsDir, ticketID)
	if _, err := os.Stat(ticketDir); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return map[string]any{"error": fmt.Sprintf("Ticket %s not found", ticketID)}
		}
		return map[string]any{"error": fmt.Sprintf("Cannot stat ticket %s: %v", ticketID, err)}
	}
	docPath := filepath.Join(ticketDir, docName)
	if err := os.MkdirAll(filepath.Dir(docPath), 0755); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to create directory: %v", err)}
	}
	if err := os.WriteFile(docPath, []byte(content), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write %s: %v", docName, err)}
	}
	return map[string]any{"ticket_id": ticketID, "doc_name": docName, "status": "ok"}
}

func yamlEscape(value string) string {
	r := strings.NewReplacer(
		"\\", "\\\\",
		"\"", "\\\"",
		"\n", "\\n",
		"\r", "\\r",
		"\t", "\\t",
	)
	return r.Replace(value)
}
