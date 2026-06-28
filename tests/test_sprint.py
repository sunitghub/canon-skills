import json
import re
from pathlib import Path

import pytest

from mcp_server.utils.sprint import (
    get_sprint_board,
    start_sprint,
    close_sprint,
    log_subagent_run,
)
from mcp_server.utils.parsers import AGENT_RUN_LOG_PATHS


# ── get_sprint_board ─────────────────────────────────────────────────────


class TestGetSprintBoard:
    def test_empty(self, tmp_path: Path):
        (tmp_path / ".tickets").mkdir()
        (tmp_path / ".git").mkdir()
        result = get_sprint_board(tmp_path)
        assert result["tickets"] == []
        assert result["handoff"] is not None

    def test_with_tickets(self, project_root: Path):
        result = get_sprint_board(project_root)
        assert len(result["tickets"]) == 1
        assert result["tickets"][0]["id"] == "TKT-0001"
        assert result["handoff"]["active_tasks"] == ["Task one", "Task two"]


# ── start_sprint ─────────────────────────────────────────────────────────


class TestStartSprint:
    def test_new_ticket(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        result = start_sprint(tmp_path, "Sprint task", priority="high")
        assert result["status"] == "ok"
        tid = result["ticket_id"]
        assert (tmp_path / ".tickets" / tid).exists()
        assert (tmp_path / ".tickets" / tid / "plan.md").exists()
        assert (tmp_path / "DECISIONS.md").exists()
        assert (tmp_path / "HANDOFF.md").exists()
        assert (tmp_path / ".tickets" / "ACTIVE").read_text().strip() == tid

    def test_existing_ticket(self, project_root: Path):
        result = start_sprint(project_root, "", ticket_id="TKT-0001")
        assert result["status"] == "ok"
        assert result["ticket_id"] == "TKT-0001"

    def test_existing_ticket_not_found(self, project_root: Path):
        result = start_sprint(project_root, "", ticket_id="NONEXIST")
        assert "error" in result


# ── close_sprint ─────────────────────────────────────────────────────────


def _make_closable_ticket(tickets_dir: Path, tid: str, run_epoch: int = 1705314600):
    tdir = tickets_dir / tid
    tdir.mkdir(parents=True, exist_ok=True)
    (tdir / "ticket.md").write_text(
        f"---\nid: {tid}\ntitle: {tid}\nstatus: closed\n---\n\nDone.\n",
        encoding="utf-8",
    )
    (tdir / "acceptance.md").write_text("## Acceptance Criteria\n- [x] Done\n", encoding="utf-8")
    (tdir / "plan.md").write_text(
        "---\n---\n\n# Plan\n\n## Sign-off\n\n- [x] Approved\n\n## Decisions\n\n### Some decision\n",
        encoding="utf-8",
    )
    (tdir / "eval-report.md").write_text(
        f"evaluator-run-id: {run_epoch}-0001\npass: all checks ok\n",
        encoding="utf-8",
    )


def _seed_subagent_log(project_root: Path, run_epoch: int):
    entry = json.dumps({"ts": "2024-01-15T10:30:00Z", "agent_id": f"{run_epoch}-0001"})
    for rel in AGENT_RUN_LOG_PATHS:
        path = project_root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(entry + "\n", encoding="utf-8")


class TestCloseSprint:
    def test_no_tickets(self, tmp_path: Path):
        (tmp_path / ".tickets").mkdir()
        (tmp_path / ".git").mkdir()
        (tmp_path / "HANDOFF.md").write_text("# Handoff\n", encoding="utf-8")
        result = close_sprint(tmp_path)
        assert result["status"] == "error"
        assert "No tickets" in result["message"]

    def test_incomplete_tickets(self, project_root: Path):
        result = close_sprint(project_root)
        assert result["status"] == "error"
        assert "not terminal" in result["message"]

    def test_missing_eval_report(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        tickets = tmp_path / ".tickets"
        tickets.mkdir()
        _make_closable_ticket(tickets, "TKT-1", 1705314600)
        (tickets / "TKT-1" / "eval-report.md").unlink()
        (tmp_path / "HANDOFF.md").write_text("# Handoff\n", encoding="utf-8")
        result = close_sprint(tmp_path)
        assert result["status"] == "error"
        assert "eval-report.md is missing" in result["message"]

    def test_missing_evaluator_run_id(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        tickets = tmp_path / ".tickets"
        tickets.mkdir()
        tdir = tickets / "TKT-1"
        tdir.mkdir()
        (tdir / "ticket.md").write_text(
            "---\nid: TKT-1\ntitle: TKT-1\nstatus: closed\n---\n", encoding="utf-8"
        )
        (tdir / "eval-report.md").write_text("pass: ok\n", encoding="utf-8")
        (tmp_path / "HANDOFF.md").write_text("# Handoff\n", encoding="utf-8")
        result = close_sprint(tmp_path)
        assert result["status"] == "error"
        assert "evaluator-run-id" in result["message"]

    def test_verdict_not_pass(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        tickets = tmp_path / ".tickets"
        tickets.mkdir()
        tdir = tickets / "TKT-1"
        tdir.mkdir()
        (tdir / "ticket.md").write_text(
            "---\nid: TKT-1\ntitle: TKT-1\nstatus: closed\n---\n", encoding="utf-8"
        )
        (tdir / "eval-report.md").write_text(
            "evaluator-run-id: 1705314600-0001\nfail: broke everything\n",
            encoding="utf-8",
        )
        _seed_subagent_log(tmp_path, 1705314600)
        (tmp_path / "HANDOFF.md").write_text("# Handoff\n", encoding="utf-8")
        result = close_sprint(tmp_path)
        assert result["status"] == "error"
        assert "verdict" in result["message"].lower()

    def test_subagent_run_not_found(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        tickets = tmp_path / ".tickets"
        tickets.mkdir()
        _make_closable_ticket(tickets, "TKT-1", 1705314600)
        (tmp_path / "HANDOFF.md").write_text("# Handoff\n", encoding="utf-8")
        result = close_sprint(tmp_path)
        assert result["status"] == "error"
        assert "subagent" in result["message"]

    def test_successful_close(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        tickets = tmp_path / ".tickets"
        tickets.mkdir()
        handoff = tmp_path / "HANDOFF.md"
        handoff.write_text("# Handoff\n\n## Active Tasks\n- Something\n", encoding="utf-8")
        _make_closable_ticket(tickets, "TKT-1", 1705314600)
        _seed_subagent_log(tmp_path, 1705314600)
        result = close_sprint(tmp_path)
        assert result["status"] == "ok"
        receipt = result["receipt"]
        assert "Delivery Receipt" in receipt
        assert "TKT-1" in receipt
        handoff_content = handoff.read_text(encoding="utf-8")
        assert "Sprint Summary" in handoff_content

    def test_duplicate_summary_guard(self, tmp_path: Path):
        (tmp_path / ".git").mkdir()
        tickets = tmp_path / ".tickets"
        tickets.mkdir()
        handoff = tmp_path / "HANDOFF.md"
        handoff.write_text(
            "# Handoff\n\n## Sprint Summary (TKT-1)\nAlready closed.\n", encoding="utf-8"
        )
        _make_closable_ticket(tickets, "TKT-1", 1705314600)
        _seed_subagent_log(tmp_path, 1705314600)
        result = close_sprint(tmp_path)
        assert result["status"] == "error"
        assert "already has a summary" in result["message"]


# ── log_subagent_run ─────────────────────────────────────────────────────


class TestLogSubagentRun:
    def test_writes_to_all_paths(self, tmp_path: Path):
        result = log_subagent_run(tmp_path, "eval-run-1", "evaluator", "sess-1")
        assert result["status"] == "ok"
        for rel in AGENT_RUN_LOG_PATHS:
            path = tmp_path / rel
            assert path.exists(), f"{rel} was not created"
            content = path.read_text(encoding="utf-8").strip()
            assert content, f"{rel} is empty"
            entry = json.loads(content)
            assert entry["agent_id"] == "eval-run-1"
            assert entry["agent_type"] == "evaluator"
            assert entry["session_id"] == "sess-1"
