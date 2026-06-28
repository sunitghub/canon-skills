import re
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from mcp_server.utils.commands import (
    add_acceptance_criterion,
    create_sprint_ticket,
    update_ticket_status,
    list_skills,
    get_ticket,
    update_ticket_body,
    read_doc,
    write_doc,
    _yaml_escape,
    _parse_yaml_list,
    git_info,
)


# ── add_acceptance_criterion ─────────────────────────────────────────────


class TestAddAcceptanceCriterion:
    def test_file_not_found(self, tmp_path: Path):
        result = add_acceptance_criterion(tmp_path / "tickets", "TKT-1", "criterion")
        assert "error" in result

    def test_heading_not_found(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "acceptance.md").write_text("# No heading\n", encoding="utf-8")
        result = add_acceptance_criterion(tmp_path, "TKT-1", "New criterion")
        assert result["status"] == "ok"
        content = (d / "acceptance.md").read_text(encoding="utf-8")
        assert "New criterion" in content

    def test_append_bullet(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "acceptance.md").write_text(
            "## Acceptance Criteria\n- [ ] Existing item\n", encoding="utf-8"
        )
        add_acceptance_criterion(tmp_path, "TKT-1", "New item")
        content = (d / "acceptance.md").read_text(encoding="utf-8")
        assert "- [ ] New item" in content

    def test_append_numbered(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "acceptance.md").write_text(
            "## Acceptance Criteria\n1. [ ] First\n", encoding="utf-8"
        )
        add_acceptance_criterion(tmp_path, "TKT-1", "Second")
        content = (d / "acceptance.md").read_text(encoding="utf-8")
        assert "2. [ ] Second" in content

    def test_blank_lines_between_items(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "acceptance.md").write_text(
            "## Acceptance Criteria\n- [ ] Item 1\n\n- [ ] Item 2\n",
            encoding="utf-8",
        )
        add_acceptance_criterion(tmp_path, "TKT-1", "Item 3")
        content = (d / "acceptance.md").read_text(encoding="utf-8")
        assert "- [ ] Item 3" in content
        assert "- [ ] Item 1" in content
        assert "- [ ] Item 2" in content

    def test_empty_list_section(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "acceptance.md").write_text(
            "## Acceptance Criteria\n", encoding="utf-8"
        )
        add_acceptance_criterion(tmp_path, "TKT-1", "Only item")
        content = (d / "acceptance.md").read_text(encoding="utf-8")
        assert "- [ ] Only item" in content


# ── create_sprint_ticket ─────────────────────────────────────────────────


class TestCreateSprintTicket:
    def test_creates_ticket(self, tmp_path: Path):
        result = create_sprint_ticket(tmp_path, "My new ticket", "high")
        assert result["status"] == "ok"
        tid = result["ticket_id"]
        assert (tmp_path / tid / "ticket.md").exists()
        assert (tmp_path / tid / "acceptance.md").exists()
        assert (tmp_path / tid / "test_plan.md").exists()

    def test_ticket_has_frontmatter(self, tmp_path: Path):
        result = create_sprint_ticket(tmp_path, "Test title", "low")
        tid = result["ticket_id"]
        content = (tmp_path / tid / "ticket.md").read_text(encoding="utf-8")
        assert "id: " + tid in content
        assert "title: \"Test title\"" in content
        assert "status: open" in content
        assert "priority: low" in content

    def test_long_title_truncated(self, tmp_path: Path):
        long_title = "A" * 60
        result = create_sprint_ticket(tmp_path, long_title, "medium")
        tid = result["ticket_id"]
        content = (tmp_path / tid / "ticket.md").read_text(encoding="utf-8")
        assert "..." in content
        assert len(re.search(r'title: "(.*?)"', content).group(1)) == 50


# ── update_ticket_status ─────────────────────────────────────────────────


class TestUpdateTicketStatus:
    def test_updates_status(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "ticket.md").write_text(
            "---\nid: TKT-1\nstatus: open\n---\n\nBody\n", encoding="utf-8"
        )
        result = update_ticket_status(tmp_path, "TKT-1", "closed")
        assert result["status"] == "ok"
        content = (d / "ticket.md").read_text(encoding="utf-8")
        assert "status: closed" in content

    def test_invalid_status(self, tmp_path: Path):
        result = update_ticket_status(tmp_path, "TKT-1", "bogus")
        assert "error" in result

    def test_ticket_not_found(self, tmp_path: Path):
        result = update_ticket_status(tmp_path, "NONEXIST", "closed")
        assert "error" in result

    def test_only_frontmatter_status_changed(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "ticket.md").write_text(
            "---\nid: TKT-1\nstatus: open\n---\n\nStatus: do not touch this\n",
            encoding="utf-8",
        )
        update_ticket_status(tmp_path, "TKT-1", "closed")
        content = (d / "ticket.md").read_text(encoding="utf-8")
        frontmatter = content.split("---")[1]
        assert "status: closed" in frontmatter
        assert "Status: do not touch this" in content


# ── list_skills ──────────────────────────────────────────────────────────


class TestListSkills:
    def test_dir_not_found(self, tmp_path: Path):
        result = list_skills(tmp_path / "nope")
        assert "error" in result

    def test_lists_skills(self, skills_dir: Path):
        result = list_skills(skills_dir)
        assert result["status"] == "ok"
        names = [s["name"] for s in result["skills"]]
        assert "sprint" in names
        assert "hidden-test" not in names

    def test_get_by_name(self, skills_dir: Path):
        result = list_skills(skills_dir, "sprint")
        assert result["name"] == "sprint"
        assert "content" in result

    def test_get_by_name_not_found(self, skills_dir: Path):
        result = list_skills(skills_dir, "nope")
        assert "error" in result


# ── get_ticket ───────────────────────────────────────────────────────────


class TestGetTicket:
    def test_not_found(self, tmp_path: Path):
        result = get_ticket(tmp_path, "NONEXIST")
        assert "error" in result

    def test_returns_ticket(self, tickets_dir: Path):
        result = get_ticket(tickets_dir, "TKT-0001")
        assert "ticket.md" in result["files"]
        assert "acceptance.md" in result["files"]
        assert "plan" in result


# ── update_ticket_body ───────────────────────────────────────────────────


class TestUpdateTicketBody:
    def test_replaces_body(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "ticket.md").write_text(
            "---\nid: TKT-1\n---\n\nOld body\n", encoding="utf-8"
        )
        result = update_ticket_body(tmp_path, "TKT-1", "New body")
        assert result["status"] == "ok"
        content = (d / "ticket.md").read_text(encoding="utf-8")
        assert "New body" in content
        assert "Old body" not in content

    def test_empty_body_rejected(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "ticket.md").write_text(
            "---\nid: TKT-1\n---\n\nBody\n", encoding="utf-8"
        )
        result = update_ticket_body(tmp_path, "TKT-1", "")
        assert "error" in result

    def test_no_frontmatter(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        (d / "ticket.md").write_text("Body\n", encoding="utf-8")
        update_ticket_body(tmp_path, "TKT-1", "New body")
        content = (d / "ticket.md").read_text(encoding="utf-8")
        assert content == "New body"

    def test_ticket_not_found(self, tmp_path: Path):
        result = update_ticket_body(tmp_path, "NONEXIST", "Body")
        assert "error" in result


# ── read_doc / write_doc ─────────────────────────────────────────────────


class TestReadDoc:
    def test_invalid_doc_name(self, tmp_path: Path):
        result = read_doc(tmp_path, "TKT-1", "invalid.md")
        assert "error" in result

    def test_doc_not_found(self, tickets_dir: Path):
        result = read_doc(tickets_dir, "TKT-0001", "plan.md")
        assert "error" in result

    def test_reads_doc(self, tickets_dir: Path):
        result = read_doc(tickets_dir, "TKT-0001", "acceptance.md")
        assert "Green build" in result["content"]


class TestWriteDoc:
    def test_invalid_doc_name(self, tmp_path: Path):
        result = write_doc(tmp_path, "TKT-1", "invalid.md", "content")
        assert "error" in result

    def test_ticket_not_found(self, tmp_path: Path):
        result = write_doc(tmp_path, "NONEXIST", "acceptance.md", "content")
        assert "error" in result

    def test_writes_doc(self, tmp_path: Path):
        d = tmp_path / "TKT-1"
        d.mkdir()
        result = write_doc(tmp_path, "TKT-1", "acceptance.md", "## New\n- [ ] Item\n")
        assert result["status"] == "ok"
        content = (d / "acceptance.md").read_text(encoding="utf-8")
        assert "New" in content


# ── helpers ──────────────────────────────────────────────────────────────


class TestYamlEscape:
    def test_backslash(self):
        assert _yaml_escape("a\\b") == "a\\\\b"

    def test_quotes(self):
        assert _yaml_escape('say "hello"') == 'say \\"hello\\"'

    def test_newline(self):
        assert _yaml_escape("line1\nline2") == "line1\\nline2"

    def test_multiple(self):
        result = _yaml_escape("a\tb\nc")
        assert "\\t" in result
        assert "\\n" in result


class TestParseYamlList:
    def test_bracket_list(self):
        assert _parse_yaml_list("[a, b, c]") == ["a", "b", "c"]

    def test_single_value(self):
        assert _parse_yaml_list("foo") == ["foo"]

    def test_empty(self):
        assert _parse_yaml_list("") == []


# ── git_info ─────────────────────────────────────────────────────────────


class TestGitInfo:
    @patch("mcp_server.utils.commands.subprocess.check_output")
    def test_normal(self, mock_check_output):
        mock_check_output.side_effect = [
            "main\n",
            "abc123|Alice|Initial commit\ndef456|Bob|\n",
            " M file1.py\n",
        ]
        result = git_info(Path("/fake"))
        assert result["branch"] == "main"
        assert len(result["commits"]) == 2
        assert result["commits"][0]["hash"] == "abc123"
        assert result["commits"][0]["author"] == "Alice"
        assert result["modified_file_count"] == 1

    @patch("mcp_server.utils.commands.subprocess.check_output")
    def test_git_fails(self, mock_check_output):
        from subprocess import CalledProcessError

        mock_check_output.side_effect = CalledProcessError(128, "git")
        result = git_info(Path("/fake"))
        assert result["branch"] == "unknown"
        assert result["commits"] == []
        assert result["modified_file_count"] == 0

    @patch("mcp_server.utils.commands.subprocess.check_output")
    def test_partial_git_output(self, mock_check_output):
        mock_check_output.side_effect = [
            "main\n",
            "abc123|Alice|Subject\n",
            "",
        ]
        result = git_info(Path("/fake"))
        assert result["branch"] == "main"
        assert len(result["commits"]) == 1
        assert result["modified_file_count"] == 0
