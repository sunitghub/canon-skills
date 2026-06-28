from pathlib import Path, PosixPath
from mcp_server.utils.project_context import find_project_root


def test_finds_git(tmp_path: Path):
    (tmp_path / ".git").mkdir()
    sub = tmp_path / "a" / "b"
    sub.mkdir(parents=True)
    assert find_project_root(sub) == tmp_path.resolve()


def test_finds_tickets(tmp_path: Path):
    (tmp_path / ".tickets").mkdir()
    sub = tmp_path / "x" / "y"
    sub.mkdir(parents=True)
    assert find_project_root(sub) == tmp_path.resolve()


def test_git_takes_precedence(tmp_path: Path):
    (tmp_path / ".git").mkdir()
    (tmp_path / ".tickets").mkdir()
    sub = tmp_path / "deep"
    sub.mkdir()
    assert find_project_root(sub) == tmp_path.resolve()


def test_returns_start_when_no_marker(tmp_path: Path):
    result = find_project_root(tmp_path)
    assert result == tmp_path.resolve()


def test_start_is_root(tmp_path: Path):
    (tmp_path / ".git").mkdir()
    assert find_project_root(tmp_path) == tmp_path.resolve()
