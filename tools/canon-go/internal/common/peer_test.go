package common

import (
	"context"
	"fmt"
	"io"
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
	if _, err := peerUID(writeTables(t, tcpHeader+procRow("0100007F:2107", "0100007F:9C40", 1000), ""), server, client); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("no client-side row must be a not-found error (deny), got %v", err)
	}
	if _, err := peerUID(t.TempDir(), server, client); err == nil || !strings.Contains(err.Error(), "cannot read") {
		t.Fatalf("unreadable tables must be an error, got %v", err)
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	if _, err := peerUID(t.TempDir(), a.LocalAddr(), b.LocalAddr()); err == nil || !strings.Contains(err.Error(), "not a TCP connection") {
		t.Fatalf("a non-TCP connection must be an error, got %v", err)
	}
	if _, err := peerUID(t.TempDir(), server, b.LocalAddr()); err == nil || !strings.Contains(err.Error(), "not a TCP connection") {
		t.Fatalf("a connection with one non-TCP end must be an error, got %v", err)
	}
}

// Only the row matching BOTH ends counts; one-sided matches and malformed rows (short, no colon, bad hex, wrong
// length, bad port, non-numeric uid) are skipped, never matched or crashed on.
func TestFindUIDSkipsPartialAndMalformedRows(t *testing.T) {
	rows := tcpHeader +
		procRow("0100007F:9C40", "0100007F:1F90", 2001) + // client end matches, server end on another port
		procRow("0100007F:9C41", "0100007F:2107", 2002) + // server end matches, another client port
		"   1: 0100007F:9C40\n" + // short row
		procRow("0100007F9C40", "0100007F:2107", 2003) + // no colon
		procRow("ZZ00007F:9C40", "0100007F:2107", 2004) + // bad hex
		procRow("01007F:9C40", "0100007F:2107", 2005) + // 3-byte address
		procRow("0100007F:XYZW", "0100007F:2107", 2006) // bad port
	if uid, found := findUID([]byte(rows), client, server); found {
		t.Fatalf("no row matches both ends, but findUID returned uid %d", uid)
	}
	badUID := tcpHeader + "   0: 0100007F:9C40 0100007F:2107 01 00000000:00000000 00:00000000 00000000 nobody\n"
	if _, found := findUID([]byte(badUID), client, server); found {
		t.Fatal("a non-numeric uid must not count as a match")
	}
	exact8 := tcpHeader + "   0: 0100007F:9C40 0100007F:2107 01 00000000:00000000 00:00000000 00000000 1003\n"
	if uid, found := findUID([]byte(exact8), client, server); !found || uid != 1003 {
		t.Fatalf("an 8-field row (uid last) must match, got %d %v", uid, found)
	}
}

func TestVerdictForOtherUserDenied(t *testing.T) {
	dir := writeTables(t, tcpHeader+procRow("0100007F:9C40", "0100007F:2107", 1001), "")
	if v := verdictFor(dir, 1001, server, client); !v.ok {
		t.Fatalf("own connection denied: %s", v.reason)
	}
	v := verdictFor(dir, 1000, server, client)
	if v.ok || !strings.Contains(v.reason, "uid 1001, not 1000") {
		t.Fatalf("another user's connection must be denied naming both uids, got %+v", v)
	}
	if v := verdictFor(t.TempDir(), 1001, server, client); v.ok {
		t.Fatal("an unreadable table must deny (fail closed)")
	}
}

// The check is live on Linux and a no-op elsewhere; a flipped constant would silently disable it.
func TestPeerCheckActiveOnLinuxOnly(t *testing.T) {
	if peerSupported != (runtime.GOOS == "linux") {
		t.Fatalf("peerSupported = %v on %s", peerSupported, runtime.GOOS)
	}
}

func TestRequireSamePeerDeniesWithoutVerdict(t *testing.T) {
	served := false
	h := RequireSamePeer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { served = true }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusForbidden || served || !strings.Contains(rec.Body.String(), "its own OS user (no peer check") {
		t.Fatalf("a request with no peer verdict got %d served=%v %q, want 403 without serving", rec.Code, served, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil).WithContext(context.WithValue(context.Background(), peerKey{}, peerVerdict{reason: "connection owned by uid 1001, not 1000"}))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden || served || !strings.Contains(rec.Body.String(), "forbidden: this server only accepts connections from its own OS user (connection owned by uid 1001, not 1000)") {
		t.Fatalf("another user's connection got %d served=%v %q, want 403 naming the uid", rec.Code, served, rec.Body.String())
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
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "ok" {
		t.Fatalf("same-user connection got %d %q on %s, want 200 ok", resp.StatusCode, body, runtime.GOOS)
	}
}

// A refused connection is logged once to stderr with its remote address and the reason (audit trail, t-68ae).
func TestPeerConnContextLogsRefusal(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("peer check is a no-op here")
	}
	r, w, _ := os.Pipe()
	old := os.Stderr
	os.Stderr = w
	a, b := net.Pipe() // not TCP: the owner cannot be checked, so it must be refused
	defer a.Close()
	defer b.Close()
	ctx := PeerConnContext(context.Background(), a)
	os.Stderr = old
	w.Close()
	logged := make([]byte, 512)
	n, _ := r.Read(logged)
	if v := ctx.Value(peerKey{}).(peerVerdict); v.ok {
		t.Fatal("a connection whose owner cannot be checked must be refused")
	}
	if got := string(logged[:n]); !strings.Contains(got, "canon: refused") || !strings.Contains(got, "not a TCP connection") {
		t.Fatalf("refusal log = %q", got)
	}
}

func TestPeerCheckWarning(t *testing.T) {
	if runtime.GOOS != "linux" {
		if w := PeerCheckWarning(); w != "" {
			t.Fatalf("no-op platform must not warn, got %q", w)
		}
		return
	}
	old := procNetDir
	defer func() { procNetDir = old }()
	procNetDir = writeTables(t, tcpHeader, "")
	if w := PeerCheckWarning(); w != "" {
		t.Fatalf("a readable tcp table must not warn, got %q", w)
	}
	procNetDir = t.TempDir()
	if w := PeerCheckWarning(); !strings.HasPrefix(w, "canon: cannot read "+filepath.Join(procNetDir, "tcp")+" (") || !strings.Contains(w, "every request will be refused") {
		t.Fatalf("unreadable /proc/net/tcp must warn, got %q", w)
	}
}
