import pytest
from mcp_server.utils.models import Ticket


def test_minimal():
    t = Ticket(id="TKT-1", status="open")
    assert t.id == "TKT-1"
    assert t.status == "open"
    assert t.title is None
    assert t.acceptance_criteria is None
    assert t.description is None
    assert t.priority is None


def test_full():
    t = Ticket(
        id="TKT-2",
        status="closed",
        title="My ticket",
        acceptance_criteria="Must work",
        description="Do the thing",
        priority="high",
    )
    assert t.id == "TKT-2"
    assert t.status == "closed"
    assert t.title == "My ticket"
    assert t.acceptance_criteria == "Must work"
    assert t.description == "Do the thing"
    assert t.priority == "high"


def test_required_fields():
    with pytest.raises(Exception):
        Ticket()
    with pytest.raises(Exception):
        Ticket(id="TKT-3")
    with pytest.raises(Exception):
        Ticket(status="open")
