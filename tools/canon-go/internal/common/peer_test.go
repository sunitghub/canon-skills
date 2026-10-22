package common

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const tcpHeader = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

// procRow renders one /proc/net/tcp row for an IPv4 local/remote pair owned by uid.
func procRow(local, remote string, uid int) string {
	return fmt.Sprintf("   0: %s %s 01 00000000:00000000 00:00000000 00000000 %5d        0 12345 1 0000000000000000 20 4 30 10 -1\n", local, remote, uid)
}

func writeTables(t *testing.T, tcp, tcp6 string) string {
	t.Helper()
	dir := t.TempDir()
	if tcp != "" {
		os.WriteFile(filepath.Join(dir, "tcp"), []byte(tcp), 0o644)
	}
	if tcp6 != "" {
		os.WriteFile(filepath.Join(dir, "tcp6"), []byte(tcp6), 0o644)
	}
	return dir
}

var (
	server = &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 8455}  // 0100007F:2107
	client = &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 40000} // 0100007F:9C40
)

func TestPeerUIDFindsClientRow(t *testing.T) {
	// The server-side row (local=server) belongs to the server's uid; only the client-side row names the peer.
	tables := tcpHeader + procRow("0100007F:2107", "0100007F:9C40", 1000) + procRow("0100007F:9C40", "0100007F:2107", 1001)
	uid, err := peerUID(writeTables(t, tables, ""), server, client)
	if err != nil || uid != 1001 {
		t.Fatalf("peerUID = %d, %v; want 1001 (the client end's owner)", uid, err)
	}
}

func TestPeerUIDIPv4MappedInTCP6(t *testing.T) {
	// A dual-stack client socket shows 127.0.0.1 as ::ffff:127.0.0.1 in tcp6.
	mapped := func(port string) string { return "0000000000000000FFFF00000100007F:" + port }
	tcp6 := tcpHeader + fmt.Sprintf("   0: %s %s 01 00000000:00000000 00:00000000 00000000  1002        0 9 1\n", mapped("9C40"), mapped("2107"))
	uid, err := peerUID(writeTables(t, tcpHeader, tcp6), server, client)
	if err != nil || uid != 1002 {
		t.Fatalf("peerUID = %d, %v; want 1002 from tcp6", uid, err)
	}
}

func TestPeerUIDFailsClosed(t *testing.T) {
	if _, err := peerUID(writeTables(t, tcpHeader+procRow("0100007F:2107", "0100007F:9C40", 1000), ""), server, client); err == nil {
		t.Fatal("no client-side row must be an error (deny), not a match")
	}
	if _, err := peerUID(t.TempDir(), server, client); err == nil || !strings.Contains(err.Error(), "cannot read") {
		t.Fatalf("unreadable tables must be an error, got %v", err)
	}
}

func TestRequireSamePeerDeniesWithoutVerdict(t *testing.T) {
	h := RequireSamePeer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("a request with no peer verdict got %d, want 403", rec.Code)
	}
	rec = httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil).WithContext(context.WithValue(context.Background(), peerKey{}, peerVerdict{reason: "connection owned by uid 1001, not 1000"}))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "uid 1001") {
		t.Fatalf("another user's connection got %d %q, want 403 naming the uid", rec.Code, rec.Body.String())
	}
}

// A real loopback connection from this process (the same OS user) passes the whole chain on Linux, and on every
// other OS where the check is a no-op.
func TestSameUserLiveConnectionAllowed(t *testing.T) {
	srv := httptest.NewUnstartedServer(RequireSamePeer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })))
	srv.Config.ConnContext = PeerConnContext
	srv.Start()
	defer srv.Close()
	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("same-user connection got %d on %s, want 200", resp.StatusCode, runtime.GOOS)
	}
}

func TestPeerCheckWarning(t *testing.T) {
	if !peerSupported {
		if w := PeerCheckWarning(); w != "" {
			t.Fatalf("no-op platform must not warn, got %q", w)
		}
		return
	}
	old := procNetDir
	defer func() { procNetDir = old }()
	procNetDir = t.TempDir()
	if w := PeerCheckWarning(); !strings.Contains(w, "every request will be refused") {
		t.Fatalf("unreadable /proc/net/tcp must warn, got %q", w)
	}
}
