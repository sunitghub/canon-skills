package board

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Protects the Refresh fetch (t-d40b): the board fetches a URL the user saved, so each refusal below is a way a page could aim it at
// the machine or the network behind it. Every case runs the real guardedGet; none reaches a real network.

func resolveTo(m map[string][]string) func(ctx context.Context, host string) ([]net.IP, error) {
	return func(_ context.Context, host string) ([]net.IP, error) {
		var ips []net.IP
		for _, s := range m[host] {
			ips = append(ips, net.ParseIP(s))
		}
		if ips == nil {
			return nil, fmt.Errorf("no such host %s", host)
		}
		return ips, nil
	}
}

// stub starts a TLS server and returns opts that dial it for any name the resolver maps to a public address.
func stub(t *testing.T, h http.HandlerFunc) fetchOpts {
	t.Helper()
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	return fetchOpts{
		resolve:   resolveTo(map[string][]string{"ok.test": {"8.8.8.8"}, "evil.test": {"10.0.0.5"}, "api.anthropic.com": {"8.8.8.8"}, "api.openai.com": {"8.8.8.8"}}),
		testDial:  srv.Listener.Addr().String(),
		tlsConfig: &tls.Config{InsecureSkipVerify: true},
		timeout:   3 * time.Second,
	}
}

func TestFetchURLRefusals(t *testing.T) {
	cases := map[string]string{
		"http://ok.test/":                "only https",
		"ftp://ok.test/":                 "only https",
		"https://user:pw@ok.test/":       "user name or password",
		"https://ok.test:8443/":          "default https port",
		"https://127.0.0.1/":             "private",
		"https://10.1.2.3/":              "private",
		"https://172.16.0.9/":            "private",
		"https://192.168.1.1/":           "private",
		"https://169.254.169.254/latest": "private",
		"https://100.64.0.1/":            "private",
		"https://[::1]/":                 "private",
		"https://[fd00::1]/":             "private",
		"https://[fe80::1]/":             "private",
		"https://[::ffff:127.0.0.1]/":    "private",
		"https://0.0.0.0/":               "private",
		"https:///nohost":                "no host",
		"not a url":                      "only https",
	}
	for raw, want := range cases {
		_, err := guardedGet(context.Background(), raw, fetchOpts{timeout: time.Second})
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: err = %v, want it to mention %q", raw, err, want)
		}
	}
}

func TestFetchRefusesNamesThatResolvePrivate(t *testing.T) {
	for name, ips := range map[string][]string{
		"loop4": {"127.0.0.1"}, "rfc1918": {"10.1.2.3"}, "rfc1918b": {"172.16.0.9"}, "rfc1918c": {"192.168.1.1"}, "meta": {"169.254.169.254"},
		"loop6": {"::1"}, "ula": {"fd00::1"}, "cgnat": {"100.64.0.1"}, "mapped": {"::ffff:10.0.0.1"}, "mixed": {"8.8.8.8", "10.0.0.1"},
		"nat64": {"64:ff9b::a00:1"}, "6to4": {"2002:c0a8:101::1"}, "teredo": {"2001:0:4136:e378:8000:63bf:3fff:fdd2"}, "compat": {"::a00:1"},
	} {
		o := fetchOpts{resolve: resolveTo(map[string][]string{name + ".test": ips}), timeout: 2 * time.Second}
		_, err := guardedGet(context.Background(), "https://"+name+".test/", o)
		if err == nil || !strings.Contains(err.Error(), "resolves to a private") {
			t.Errorf("%s -> %v: err = %v", name, ips, err)
		}
	}
	if _, err := guardedGet(context.Background(), "https://localhost/", fetchOpts{timeout: 2 * time.Second}); err == nil || !strings.Contains(err.Error(), "private") {
		t.Errorf("localhost through the system resolver: %v", err)
	}
}

func TestFetchReadsAPublicPageAndSendsNoCookie(t *testing.T) {
	var mu sync.Mutex
	var seen http.Header
	o := stub(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = r.Header.Clone()
		mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "a", Value: "b"})
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, "<html>claude-haiku-5-5</html>")
	})
	o.headers = map[string]string{"x-test-key": "sk-secret"}
	body, err := guardedGet(context.Background(), "https://ok.test/models", o)
	if err != nil || string(body) != "<html>claude-haiku-5-5</html>" {
		t.Fatalf("body = %q, err = %v", body, err)
	}
	if seen.Get("User-Agent") != "canon-model-refresh" || seen.Get("Cookie") != "" || seen.Get("X-Test-Key") != "sk-secret" {
		t.Errorf("request headers: %v", seen)
	}
	if _, err := guardedGet(context.Background(), "https://ok.test/models", o); err != nil || seen.Get("Cookie") != "" { // the jar keeps nothing between requests
		t.Errorf("second request: %v / %v", err, seen.Get("Cookie"))
	}
}

func TestFetchRedirectsAreChecked(t *testing.T) {
	cases := map[string]struct{ to, want string }{
		"to http":            {"http://ok.test/x", "only https"},
		"to a private host":  {"https://evil.test/x", "resolves to a private"},
		"to the metadata ip": {"https://169.254.169.254/latest", "private"},
		"to another port":    {"https://ok.test:8443/", "default https port"},
	}
	for name, c := range cases {
		o := stub(t, func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, c.to, http.StatusFound) })
		if _, err := guardedGet(context.Background(), "https://ok.test/", o); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", name, err, c.want)
		}
	}
	hops := 0
	o := stub(t, func(w http.ResponseWriter, r *http.Request) {
		hops++
		http.Redirect(w, r, "https://ok.test/again", http.StatusFound)
	})
	if _, err := guardedGet(context.Background(), "https://ok.test/", o); err == nil || !strings.Contains(err.Error(), "more than 3 redirects") || hops != 4 {
		t.Errorf("a redirect loop: err = %v after %d requests", err, hops)
	}
	// a request that carries a key is never redirected, so the key cannot follow a redirect anywhere
	o = stub(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://ok.test/next", http.StatusFound)
	})
	o.noRedirect = true
	if _, err := guardedGet(context.Background(), "https://ok.test/", o); err == nil || !strings.Contains(err.Error(), "carries a key") {
		t.Errorf("noRedirect: %v", err)
	}
}

func TestFetchSizeTimeAndTypeCaps(t *testing.T) {
	big := stub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(strings.Repeat("a", fetchMaxBody+10)))
	})
	if _, err := guardedGet(context.Background(), "https://ok.test/", big); err == nil || !strings.Contains(err.Error(), "larger than 2 MB") {
		t.Errorf("an oversized page: %v", err)
	}
	edge := stub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(strings.Repeat("a", fetchMaxBody)))
	})
	if b, err := guardedGet(context.Background(), "https://ok.test/", edge); err != nil || len(b) != fetchMaxBody {
		t.Errorf("a page of exactly the cap should read: %d / %v", len(b), err)
	}
	slow := stub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		time.Sleep(2 * time.Second)
	})
	slow.timeout = 300 * time.Millisecond
	start := time.Now()
	if _, err := guardedGet(context.Background(), "https://ok.test/", slow); err == nil || time.Since(start) > 1500*time.Millisecond {
		t.Errorf("a slow body should time out quickly: %v after %v", err, time.Since(start))
	}
	for ct, want := range map[string]string{"image/png": "not read", "application/octet-stream": "not read", "": "not read", "text/plain": "not read", "application/xhtml+xml": "not read"} {
		o := stub(t, func(w http.ResponseWriter, r *http.Request) { w.Header().Set("Content-Type", ct); w.Write([]byte("x")) })
		if _, err := guardedGet(context.Background(), "https://ok.test/", o); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("content type %q: %v", ct, err)
		}
	}
	nf := stub(t, func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	if _, err := guardedGet(context.Background(), "https://ok.test/", nf); err == nil || !strings.Contains(err.Error(), "404") {
		t.Errorf("a 404: %v", err)
	}
}
