package common

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Same-user peer check (t-68ae). The board and the cockpit daemon listen on 127.0.0.1, which every account on the
// machine can reach. On Linux the kernel's socket tables (/proc/net/tcp, tcp6) name the uid that owns the client end
// of each connection, so each server refuses a connection another OS user opened. The verdict is taken once per
// connection (http.Server.ConnContext) and enforced by one wrapper around the top-level handler, so no route is
// exempt. It fails closed: an unreadable table or a missing row denies. Elsewhere (macOS, Windows) peerSupported is
// false and every connection is allowed, as before.

type peerKey struct{}

type peerVerdict struct {
	ok     bool
	reason string
}

// PeerConnContext is an http.Server.ConnContext: it records whether c was opened by this process's OS user, and
// logs a refused connection once.
func PeerConnContext(ctx context.Context, c net.Conn) context.Context {
	v := peerVerdict{ok: true}
	if peerSupported {
		v = verdictFor(procNetDir, os.Getuid(), c.LocalAddr(), c.RemoteAddr())
		if !v.ok {
			fmt.Fprintf(os.Stderr, "canon: refused %s: %s\n", c.RemoteAddr(), v.reason)
		}
	}
	return context.WithValue(ctx, peerKey{}, v)
}

// verdictFor allows a connection only when the socket tables in dir show its client end owned by self.
func verdictFor(dir string, self int, local, remote net.Addr) peerVerdict {
	uid, err := peerUID(dir, local, remote)
	if err != nil {
		return peerVerdict{reason: err.Error()}
	}
	if uid != self {
		return peerVerdict{reason: fmt.Sprintf("connection owned by uid %d, not %d", uid, self)}
	}
	return peerVerdict{ok: true}
}

// RequireSamePeer serves next only on a connection PeerConnContext approved. A request without a verdict (the
// server was built without PeerConnContext) is refused too.
func RequireSamePeer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		v, ok := r.Context().Value(peerKey{}).(peerVerdict)
		if !ok {
			v = peerVerdict{reason: "no peer check on this server"}
		}
		if !v.ok {
			http.Error(w, "forbidden: this server only accepts connections from its own OS user ("+v.reason+")", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// PeerCheckWarning is a one-line startup warning when the peer check cannot work here (every request would then be
// refused), else "".
func PeerCheckWarning() string {
	if !peerSupported {
		return ""
	}
	if _, err := os.ReadFile(filepath.Join(procNetDir, "tcp")); err != nil {
		return "canon: cannot read " + filepath.Join(procNetDir, "tcp") + " (" + err.Error() + "); every request will be refused because its OS user cannot be checked"
	}
	return ""
}

// peerUID finds the uid that owns the client end of a connection whose server end is local and client end is
// remote: the row whose local address is remote and whose remote address is local, in dir/tcp or dir/tcp6.
func peerUID(dir string, local, remote net.Addr) (int, error) {
	l, ok1 := local.(*net.TCPAddr)
	r, ok2 := remote.(*net.TCPAddr)
	if !ok1 || !ok2 {
		return 0, errors.New("not a TCP connection")
	}
	read := 0
	for _, name := range []string{"tcp", "tcp6"} {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		read++
		if uid, found := findUID(raw, r, l); found {
			return uid, nil
		}
	}
	if read == 0 {
		return 0, errors.New("cannot read the kernel socket table")
	}
	return 0, errors.New("connection owner not found in the kernel socket table")
}

// findUID scans one /proc/net/tcp{,6} table for the row with local address src and remote address dst and returns
// its uid column.
func findUID(table []byte, src, dst *net.TCPAddr) (int, bool) {
	sc := bufio.NewScanner(bytes.NewReader(table))
	sc.Scan() // header
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 8 {
			continue
		}
		la, ok1 := parseProcAddr(f[1])
		ra, ok2 := parseProcAddr(f[2])
		if !ok1 || !ok2 || !sameAddr(la, src) || !sameAddr(ra, dst) {
			continue
		}
		uid, err := strconv.Atoi(f[7])
		if err != nil {
			return 0, false
		}
		return uid, true
	}
	return 0, false
}

func sameAddr(a, b *net.TCPAddr) bool { return a.Port == b.Port && a.IP.Equal(b.IP) }

// parseProcAddr decodes "0100007F:1F90" (IPv4) or a 32-hex-digit IPv6 address: the IP is stored as 32-bit words in
// host (little-endian) order, the port as big-endian hex.
func parseProcAddr(s string) (*net.TCPAddr, bool) {
	hexIP, hexPort, ok := strings.Cut(s, ":")
	if !ok {
		return nil, false
	}
	b, err := hex.DecodeString(hexIP)
	if err != nil || (len(b) != 4 && len(b) != 16) {
		return nil, false
	}
	for i := 0; i < len(b); i += 4 {
		b[i], b[i+1], b[i+2], b[i+3] = b[i+3], b[i+2], b[i+1], b[i]
	}
	port, err := strconv.ParseUint(hexPort, 16, 16)
	if err != nil {
		return nil, false
	}
	return &net.TCPAddr{IP: net.IP(b), Port: int(port)}, true
}
