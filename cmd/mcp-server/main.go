package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/sunitghub/canon-skills/internal/commands"
	"github.com/sunitghub/canon-skills/internal/project_context"
	"github.com/sunitghub/canon-skills/internal/sprint"
)

var (
	projectRoot     string
	projectRootOnce sync.Once
)

func getProjectRoot() string {
	projectRootOnce.Do(func() {
		projectRoot = project_context.FindProjectRoot(".")
	})
	return projectRoot
}

func main() {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "PANIC: %v\n", r)
			debug.PrintStack()
			os.Exit(2)
		}
	}()

	s := server.NewMCPServer("canon-mcp-server", "1.0.0",
		server.WithResourceCapabilities(true, true),
		server.WithLogging(),
	)

	s.AddTool(mcp.NewTool("ticket",
		mcp.WithDescription(`Manage tickets. Actions: get, status, doc, add_criterion. Hint: for doc action, doc_name=body reads/writes the ticket body. Leave content empty to read, provide text to write/overwrite.`),
		mcp.WithString("action", mcp.Required(), mcp.Description("Action: get, status, doc, add_criterion")),
		mcp.WithString("ticket_id", mcp.Required(), mcp.Description("The ticket ID")),
		mcp.WithString("new_status", mcp.Description("New status: open, in_progress, closed, cancelled, archived")),
		mcp.WithString("doc_name", mcp.Description("Document name: acceptance, plan, test_plan, summary, body")),
		mcp.WithString("content", mcp.Description("Document content (leave empty to read)")),
		mcp.WithString("criterion", mcp.Description("Acceptance criterion text to add")),
	), handleTicket)

	s.AddTool(mcp.NewTool("sprint",
		mcp.WithDescription(`Manage sprints. Actions: start, board, close. sprint(close) verifies that every non-trivial ticket has a passing eval-report.md and a corresponding subagent-run entry in .canon/.claude/.opencode/subagent-runs.jsonl.`),
		mcp.WithString("action", mcp.Required(), mcp.Description("Action: start, board, close")),
		mcp.WithString("title", mcp.Description("Title for new sprint ticket")),
		mcp.WithString("ticket_id", mcp.Description("Existing ticket ID to resume")),
		mcp.WithString("priority", mcp.Description("Priority: low, medium, high")),
	), handleSprint)

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}

func handleTicket(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	action := req.GetString("action", "")
	ticketID := req.GetString("ticket_id", "")
	ticketsDir := filepath.Join(getProjectRoot(), ".tickets")

	switch action {
	case "get":
		return jsonResult(commands.GetTicket(ticketsDir, ticketID)), nil

	case "status":
		newStatus := req.GetString("new_status", "")
		if newStatus == "" {
			return jsonResult(errMap("new_status required for status action")), nil
		}
		return jsonResult(commands.UpdateTicketStatus(ticketsDir, ticketID, newStatus)), nil

	case "doc":
		docName := req.GetString("doc_name", "")
		content := req.GetString("content", "")
		if docName == "" {
			return jsonResult(errMap("doc_name required: acceptance, plan, test_plan, summary, or body")), nil
		}
		if content == "" {
			if docName == "body" {
				return jsonResult(commands.GetTicketBody(ticketsDir, ticketID)), nil
			}
			return jsonResult(commands.ReadDoc(ticketsDir, ticketID, docName+".md")), nil
		}
		if docName == "body" {
			return jsonResult(commands.UpdateTicketBody(ticketsDir, ticketID, content)), nil
		}
		return jsonResult(commands.WriteDoc(ticketsDir, ticketID, docName+".md", content)), nil

	case "add_criterion":
		criterion := req.GetString("criterion", "")
		if criterion == "" {
			return jsonResult(errMap("criterion text required for add_criterion action")), nil
		}
		return jsonResult(commands.AddAcceptanceCriterion(ticketsDir, ticketID, criterion)), nil

	default:
		return jsonResult(errMap(fmt.Sprintf("Unknown action: %s", action))), nil
	}
}

func handleSprint(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	action := req.GetString("action", "")

	switch action {
	case "start":
		title := req.GetString("title", "")
		ticketID := req.GetString("ticket_id", "")
		priority := req.GetString("priority", "medium")

		if title == "" && ticketID == "" {
			return jsonResult(errMap("Provide title (new ticket) or ticket_id (existing), not both.")), nil
		}
		if title != "" && ticketID != "" {
			return jsonResult(errMap("Provide title or ticket_id, not both.")), nil
		}
		validPriorities := map[string]bool{"low": true, "medium": true, "high": true}
		if !validPriorities[priority] {
			return jsonResult(errMap("Priority must be low, medium, or high")), nil
		}
		return jsonResult(sprint.StartSprint(getProjectRoot(), title, ticketID, priority)), nil

	case "board":
		return jsonResult(sprint.GetSprintBoard(getProjectRoot())), nil

	case "close":
		return jsonResult(sprint.CloseSprint(getProjectRoot())), nil

	default:
		return jsonResult(errMap(fmt.Sprintf("Unknown action: %s", action))), nil
	}
}

func jsonResult(data map[string]any) *mcp.CallToolResult {
	payload, err := json.Marshal(data)
	if err != nil {
		payload = []byte(`{"status":"error","data":{},"message":"serialization error"}`)
	}
	return mcp.NewToolResultText(string(payload))
}

func errMap(msg string) map[string]any {
	return map[string]any{"status": "error", "data": map[string]any{}, "message": msg}
}
