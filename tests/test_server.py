import socket
from pathlib import Path
from unittest.mock import patch, MagicMock, PropertyMock

import pytest

from mcp_server.server import _find_free_port, _dashboard_port


class TestFindFreePort:
    def test_returns_port(self):
        port = _find_free_port(18523, 18523)
        assert port == 18523

    def test_raises_when_all_occupied(self):
        with patch("mcp_server.server.socket.socket") as mock_socket:
            inst = MagicMock()
            inst.bind.side_effect = OSError("in use")
            mock_socket.return_value.__enter__.return_value = inst
            with pytest.raises(RuntimeError, match="No free port"):
                _find_free_port(18523, 18523)


class TestDashboardPort:
    def test_no_server(self):
        with patch("mcp_server.server.urllib.request.urlopen") as mock_urlopen:
            mock_urlopen.side_effect = OSError("Connection refused")
            port = _dashboard_port()
            assert port is None

    def test_server_running(self):
        with patch("mcp_server.server.urllib.request.urlopen") as mock_urlopen:
            resp = MagicMock()
            resp.status = 200
            mock_urlopen.return_value = resp
            port = _dashboard_port()
            assert port == 8423
