import json
from pathlib import Path

import pytest

from mcp_server.utils.parsers import (
    _parse_timestamp,
    parse_tickets,
    parse_handoff,
    _get_section,
    _parse_plan_approved,
    _parse_plan_decision,
    _check_subagent_run,
    AGENT_RUN_LOG_PATHS,
)


class TestParseTimestamp:
    def test_z_suffix(self):
        ts = _parse_timestamp("2024-01-15T10:30:00Z")
        assert ts == 1705314600

    def test_utc_offset(self):
        ts = _parse_timestamp("2024-01-15T10:30:00+00:00")
        assert ts == 1705314600

    def test_fractional(self):
        ts = _parse_timestamp("2024-01-15T10:30:00.123456Z")
        assert ts == 1705314600


class TestParseTickets:
    def test_empty_dir(self, tmp_path: Path):
        d = tmp_path / ".tickets"
        d.mkdir()
        assert parse_tickets(d) == []

    def test_nonexistent_dir(self, tmp_path: Path):
        assert parse_tickets(tmp_path / "nope") == []

    def test_parses_tickets(self, tickets_dir: Path):
        result = parse_tickets(tickets_dir)
        assert len(result) == 2
        t1 = next(t for t in result if t.id == "TKT-0001")
        assert t1.status == "open"
        assert t1.title == "Setup CI"
        assert t1.priority == "high"
        assert "Green build" in t1.acceptance_criteria
        assert "continuous integration" in t1.description
        t2 = next(t for t in result if t.id == "TKT-0002")
        assert t2.status == "closed"
        assert t2.description == "Write unit tests."

    def test_no_frontmatter(self, tmp_path: Path):
        d = tmp_path / ".tickets"
        d.mkdir()
        ticket_dir = d / "TKT-X"
        ticket_dir.mkdir()
        (ticket_dir / "ticket.md").write_text(
            "TKT-X\n## Description\nSomething\n", encoding="utf-8"
        )
        tickets = parse_tickets(d)
        assert len(tickets) == 1
        assert tickets[0].id == "TKT-X"


class TestParseHandoff:
    def test_missing_file(self, tmp_path: Path):
        result = parse_handoff(tmp_path / "HANDOFF.md")
        assert result == {"active_tasks": []}

    def test_with_tasks(self, tmp_path: Path):
        p = tmp_path / "HANDOFF.md"
        p.write_text(
            "# Handoff\n\n## Active Tasks\n- Task one\n- Task two\n\n## Next\n",
            encoding="utf-8",
        )
        result = parse_handoff(p)
        assert result["active_tasks"] == ["Task one", "Task two"]

    def test_bold_markup_stripped(self, tmp_path: Path):
        p = tmp_path / "HANDOFF.md"
        p.write_text(
            "# Handoff\n\n## Active Tasks\n- **bold** task\n- *italic* task\n",
            encoding="utf-8",
        )
        result = parse_handoff(p)
        assert result["active_tasks"] == ["bold task", "italic task"]

    def test_no_tasks_section(self, tmp_path: Path):
        p = tmp_path / "HANDOFF.md"
        p.write_text("# Handoff\n\nNothing here.\n", encoding="utf-8")
        result = parse_handoff(p)
        assert result["active_tasks"] == []


class TestGetSection:
    def test_section_found(self):
        content = "## Sign-off\n\n- [x] Approved\n"
        assert _get_section(content, "Sign-off") == "- [x] Approved"

    def test_section_missing(self):
        assert _get_section("## Other\n\nstuff\n", "Sign-off") == ""

    def test_section_at_end(self):
        content = "# Doc\n\n## Last Section\n\nfinal content\n"
        assert _get_section(content, "Last Section") == "final content"


class TestParsePlanApproved:
    def test_no_file(self, tmp_path: Path):
        assert _parse_plan_approved(tmp_path / "nope.md") is False

    def test_approved(self, plan_path: Path):
        assert _parse_plan_approved(plan_path) is True

    def test_not_approved(self, tmp_path: Path):
        p = tmp_path / "plan.md"
        p.write_text("## Sign-off\n\n- [ ] Not yet\n", encoding="utf-8")
        assert _parse_plan_approved(p) is False


class TestParsePlanDecision:
    def test_no_file(self, tmp_path: Path):
        assert _parse_plan_decision(tmp_path / "nope.md") == ""

    def test_has_decision(self, plan_path: Path):
        assert _parse_plan_decision(plan_path) == "Use FastMCP"

    def test_no_decision(self, tmp_path: Path):
        p = tmp_path / "plan.md"
        p.write_text("## Decisions\n\nNothing decided.\n", encoding="utf-8")
        assert _parse_plan_decision(p) == ""


class TestCheckSubagentRun:
    def test_match_found(self, tmp_path: Path):
        epoch = 1705314600
        entry = json.dumps({"ts": "2024-01-15T10:30:00Z", "agent_id": "eval-1"})
        for rel in AGENT_RUN_LOG_PATHS:
            path = tmp_path / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(entry + "\n", encoding="utf-8")
        assert _check_subagent_run(tmp_path, epoch) is True

    def test_no_match(self, tmp_path: Path):
        epoch = 1705314600
        entry = json.dumps({"ts": "2024-01-15T12:30:00Z", "agent_id": "eval-1"})
        for rel in AGENT_RUN_LOG_PATHS:
            path = tmp_path / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(entry + "\n", encoding="utf-8")
        assert _check_subagent_run(tmp_path, epoch) is False

    def test_empty_log(self, tmp_path: Path):
        for rel in AGENT_RUN_LOG_PATHS:
            path = tmp_path / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("", encoding="utf-8")
        assert _check_subagent_run(tmp_path, 1705314600) is False

    def test_missing_log(self, tmp_path: Path):
        assert _check_subagent_run(tmp_path, 1705314600) is False

    def test_no_timestamp_field(self, tmp_path: Path):
        entry = json.dumps({"agent_id": "eval-1"})
        for rel in AGENT_RUN_LOG_PATHS:
            path = tmp_path / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(entry + "\n", encoding="utf-8")
        assert _check_subagent_run(tmp_path, 1705314600) is False
