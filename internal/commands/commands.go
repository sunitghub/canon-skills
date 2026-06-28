package commands

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/chightow/canon-skills/internal/parsers"
)

var mu sync.Mutex

var winReserved = []string{"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"}

func validTicketID(id string) error {
	if id == "" || strings.Contains(id, "..") || strings.ContainsAny(id, "/\\") {
		return errors.New("invalid ticket ID")
	}
	cleaned := filepath.Clean(id)
	if cleaned != id {
		return errors.New("invalid ticket ID")
	}
	for _, r := range winReserved {
		if strings.EqualFold(id, r) {
			return errors.New("invalid ticket ID")
		}
	}
	return nil
}

var ValidStatuses = map[string]bool{
	"open": true, "in_progress": true, "closed": true,
	"cancelled": true, "archived": true,
}

func AddAcceptanceCriterion(ticketsDir, ticketID, criterionText string) map[string]any {
	if err := validTicketID(ticketID); err != nil {
		return map[string]any{"error": fmt.Sprintf("Invalid ticket ID '%s'", ticketID)}
	}
	mu.Lock()
	defer mu.Unlock()
	acceptanceFile := filepath.Join(ticketsDir, ticketID, "acceptance.md")
	content, err := os.ReadFile(acceptanceFile)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("acceptance.md not found for ticket %s", ticketID)}
	}

	acceptanceHeading := "## Acceptance Criteria"
	headingIdx := strings.Index(string(content), acceptanceHeading)
	if headingIdx == -1 {
		newContent := fmt.Sprintf("%s\n- [ ] %s\n", acceptanceHeading, criterionText)
		if err := os.WriteFile(acceptanceFile, []byte(newContent), 0644); err != nil {
			return map[string]any{"error": fmt.Sprintf("Failed to write acceptance.md: %v", err)}
		}
		return map[string]any{"ticket_id": ticketID, "criterion": criterionText, "status": "ok"}
	}

	listStart := headingIdx + len(acceptanceHeading)
	listSection := strings.TrimSpace(string(content)[listStart:])
	if listSection == "" {
		newContent := strings.TrimRight(string(content), " \t\r\n") + fmt.Sprintf("\n- [ ] %s\n", criterionText)
		if err := os.WriteFile(acceptanceFile, []byte(newContent), 0644); err != nil {
			return map[string]any{"error": fmt.Sprintf("Failed to write acceptance.md: %v", err)}
		}
		return map[string]any{"ticket_id": ticketID, "criterion": criterionText, "status": "ok"}
	}

	lines := strings.Split(listSection, "\n")
	listStartIdx := 0
	for listStartIdx < len(lines) && strings.TrimSpace(lines[listStartIdx]) == "" {
		listStartIdx++
	}

	lastNum := 0
	isNumbered := false
	foundExisting := false
	numRe := regexp.MustCompile(`^(\d+)\.\s*`)
	bulletRe := regexp.MustCompile(`^[-*]\s*`)

	for i := listStartIdx; i < len(lines); i++ {
		stripped := strings.TrimSpace(lines[i])
		if stripped == "" {
			continue
		}
		if m := numRe.FindStringSubmatch(stripped); m != nil {
			isNumbered = true
			fmt.Sscanf(m[1], "%d", &lastNum)
			foundExisting = true
		} else if bulletRe.MatchString(stripped) {
			foundExisting = true
		} else {
			break
		}
	}

	base := strings.TrimRight(string(content), " \t\r\n")
	var newContent string
	if !foundExisting {
		newContent = base + fmt.Sprintf("\n- [ ] %s\n", criterionText)
	} else if isNumbered {
		newContent = base + fmt.Sprintf("\n%d. [ ] %s\n", lastNum+1, criterionText)
	} else {
		newContent = base + fmt.Sprintf("\n- [ ] %s\n", criterionText)
	}
	if err := os.WriteFile(acceptanceFile, []byte(newContent), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write acceptance.md: %v", err)}
	}
	return map[string]any{"ticket_id": ticketID, "criterion": criterionText, "status": "ok"}
}

func CreateSprintTicket(ticketsDir, description, priority string) map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if err := os.MkdirAll(ticketsDir, 0755); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to create tickets directory: %v", err)}
	}
	var ticketID string
	for i := 0; i < 10; i++ {
		b := make([]byte, 4)
		if _, err := rand.Read(b); err != nil {
			return map[string]any{"error": fmt.Sprintf("Failed to generate random ticket ID: %v", err)}
		}
		id := fmt.Sprintf("t-%x", b)
		ticketDir := filepath.Join(ticketsDir, id)
		if err := os.Mkdir(ticketDir, 0755); err == nil {
			ticketID = id
			break
		}
	}
	if ticketID == "" {
		return map[string]any{"error": "Failed to generate unique ticket ID after 10 attempts"}
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

	ticketFile := filepath.Join(ticketsDir, ticketID, "ticket.md")
	if err := os.WriteFile(ticketFile, []byte(fmt.Sprintf(
		"---\nid: %s\ntitle: \"%s\"\nstatus: open\npriority: %s\n---\n\n## Description\n%s\n\n## Acceptance Criteria\n",
		ticketID, safeTitle, priority, description,
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
	fmRe := regexp.MustCompile(`(?s)^(---\n.*?\n---)\n?(.*)$`)
	m := fmRe.FindStringSubmatch(string(content))
	if m == nil {
		return map[string]any{"error": "ticket.md has no frontmatter"}
	}
	statusRe := regexp.MustCompile(`(?m)^status:.*$`)
	newFrontmatter := statusRe.ReplaceAllString(m[1], "status: "+newStatus)
	newContent := newFrontmatter + "\n\n" + strings.TrimLeft(m[2], "\n")
	if err := os.WriteFile(ticketFile, []byte(newContent), 0644); err != nil {
		return map[string]any{"error": fmt.Sprintf("Failed to write ticket.md: %v", err)}
	}
	return map[string]any{"ticket_id": ticketID, "new_status": newStatus, "status": "ok"}
}

func GetTicket(ticketsDir, ticketID string) map[string]any {
	mu.Lock()
	defer mu.Unlock()
	ticketDir := filepath.Join(ticketsDir, ticketID)
	if _, err := os.Stat(ticketDir); os.IsNotExist(err) {
		return map[string]any{"error": fmt.Sprintf("Ticket '%s' not found at %s", ticketID, ticketDir)}
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

func UpdateTicketBody(ticketsDir, ticketID, body string) map[string]any {
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

	re := regexp.MustCompile(`(?s)^(---\n.*?\n---)\n?`)
	var newContent string
	if m := re.FindStringSubmatch(string(content)); m != nil {
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
	mu.Lock()
	defer mu.Unlock()
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
	mu.Lock()
	defer mu.Unlock()
	docName = strings.ToLower(docName)
	validDocs := map[string]bool{"acceptance.md": true, "plan.md": true, "test_plan.md": true, "summary.md": true}
	if !validDocs[docName] {
		return map[string]any{"error": fmt.Sprintf("Invalid doc_name '%s'. Must be one of: acceptance.md, plan.md, test_plan.md, summary.md", docName)}
	}
	ticketDir := filepath.Join(ticketsDir, ticketID)
	if _, err := os.Stat(ticketDir); os.IsNotExist(err) {
		return map[string]any{"error": fmt.Sprintf("Ticket %s not found", ticketID)}
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
