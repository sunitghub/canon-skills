import pytest
from pathlib import Path


@pytest.fixture
def tickets_dir(tmp_path: Path) -> Path:
    d = tmp_path / ".tickets"
    d.mkdir()
    _write_ticket(d / "TKT-0001" / "ticket.md",
        "---\nid: TKT-0001\ntitle: Setup CI\nstatus: open\npriority: high\n---\n\n## Description\nSet up continuous integration.\n\n## Acceptance Criteria\n- [ ] Green build\n")
    _write_ticket(d / "TKT-0001" / "acceptance.md",
        "## Acceptance Criteria\n- [ ] Green build\n")
    _write_ticket(d / "TKT-0002" / "ticket.md",
        "---\nid: TKT-0002\ntitle: Add tests\nstatus: closed\npriority: medium\n---\n\n## Description\nWrite unit tests.\n")
    _write_ticket(d / "TKT-0002" / "acceptance.md",
        "## Acceptance Criteria\n- [ ] All tests pass\n")
    return d


@pytest.fixture
def skills_dir(tmp_path: Path) -> Path:
    d = tmp_path / "skills"
    d.mkdir()
    _write_ticket(d / "sprint" / "SKILL.md",
        "---\nname: sprint\ndescription: Sprint management\ntags: [agile, workflow]\nhidden: false\n---\n# Sprint skill\n")
    _write_ticket(d / "hidden-test" / "SKILL.md",
        "---\nname: hidden-test\ndescription: Hidden skill\ntags: []\nhidden: true\n---\n")
    return d


@pytest.fixture
def project_root(tmp_path: Path) -> Path:
    (tmp_path / ".git").mkdir()
    tickets = tmp_path / ".tickets"
    tickets.mkdir()
    _write_ticket(tickets / "TKT-0001" / "ticket.md",
        "---\nid: TKT-0001\ntitle: Test ticket\nstatus: open\npriority: high\n---\n\n## Description\nA test.\n")
    (tmp_path / "HANDOFF.md").write_text(
        "# Handoff\n\n## Active Tasks\n- Task one\n- Task two\n", encoding="utf-8")
    (tmp_path / "DECISIONS.md").write_text(
        "# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n", encoding="utf-8")
    return tmp_path


@pytest.fixture
def plan_path(tmp_path: Path) -> Path:
    p = tmp_path / "plan.md"
    p.write_text(
        "---\nid: TKT-0001\n---\n\n# Plan\n\n## Approach\nDo it.\n\n## Sign-off\n\n- [x] Plan approved\n\n## Decisions\n\n### Use FastMCP\n\nReason: Quick to implement.\n", encoding="utf-8")
    return p


def _write_ticket(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
