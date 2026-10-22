package board

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// t-d40b: the guarded fetch behind Admin > Model Tiers > Refresh. The board fetches a URL the user saved as a source, so the fetch is
// built to refuse anything that is not a public https page: https only, the default port, no credentials in the URL, every resolved address
// checked at dial time (so a name that resolves to a private address, or flips after a check, still fails), every redirect hop re-checked,
// at most 3 redirects, a 10 s total timeout, a 2 MB body cap, and only text, html or json answers. No proxy is used (a proxy would
// connect on our behalf and skip the address check), no cookies are kept, and nothing the page says is run.

const (
	fetchMaxBody      = 2 << 20
	fetchTimeout      = 10 * time.Second
	fetchMaxRedirects = 3
)

var fetchOKTypes = []string{"text/html", "application/json", "text/plain", "application/xhtml+xml"}

// fetchOpts are the seams a test needs; production passes the zero value.
type fetchOpts struct {
	resolve    func(ctx context.Context, host string) ([]net.IP, error) // default: the system resolver
	testDial   string                                                   // tests only: connect here whatever the address says (the address checks still run on the resolved IPs)
	tlsConfig  *tls.Config                                              // tests only: trusts the stub's certificate
	timeout    time.Duration                                            // tests only: shortens the 10 s cap
	headers    map[string]string                                        // set on the first request only; the API sources put a key here
	noRedirect bool                                                     // a request that carries a key is never redirected
}

var blockedNets = func() []*net.IPNet {
	var nets []*net.IPNet
	for _, c := range []string{
		"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
		"192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4", "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
	} {
		_, n, _ := net.ParseCIDR(c)
		nets = append(nets, n)
	}
	return nets
}()

// blockedIP: loopback, private, link-local (the cloud metadata address included), shared (100.64/10, Tailscale), multicast and
// unspecified addresses. An IPv4-mapped IPv6 address is judged by its IPv4 form.
func blockedIP(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	for _, n := range blockedNets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// checkFetchURL is the part of the guard that needs no network: scheme, host, credentials and port.
func checkFetchURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("not a valid address")
	}
	switch {
	case u.Scheme != "https":
		return nil, fmt.Errorf("only https addresses are fetched")
	case u.Hostname() == "":
		return nil, fmt.Errorf("the address has no host")
	case u.User != nil:
		return nil, fmt.Errorf("an address with a user name or password is refused")
	case u.Port() != "" && u.Port() != "443":
		return nil, fmt.Errorf("only the default https port is fetched")
	}
	if ip := net.ParseIP(u.Hostname()); ip != nil && blockedIP(ip) {
		return nil, fmt.Errorf("a private, loopback or link-local address is refused")
	}
	return u, nil
}

// guardedGet fetches raw and returns the body, never more than fetchMaxBody bytes.
func guardedGet(ctx context.Context, raw string, o fetchOpts) ([]byte, error) {
	u, err := checkFetchURL(raw)
	if err != nil {
		return nil, err
	}
	resolve := o.resolve
	if resolve == nil {
		resolve = func(ctx context.Context, host string) ([]net.IP, error) {
			addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
			ips := make([]net.IP, 0, len(addrs))
			for _, a := range addrs {
				ips = append(ips, a.IP)
			}
			return ips, err
		}
	}
	timeout := o.timeout
	if timeout == 0 {
		timeout = fetchTimeout
	}
	dialer := &net.Dialer{Timeout: timeout}
	transport := &http.Transport{
		Proxy:           nil, // a proxy would dial for us and skip the address check
		TLSClientConfig: o.tlsConfig,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips := []net.IP{}
			if ip := net.ParseIP(host); ip != nil {
				ips = append(ips, ip)
			} else if ips, err = resolve(ctx, host); err != nil {
				return nil, err
			}
			if len(ips) == 0 {
				return nil, fmt.Errorf("%s did not resolve", host)
			}
			for _, ip := range ips { // every address must be public, so a mixed answer cannot slip a private one in
				if blockedIP(ip) {
					return nil, fmt.Errorf("%s resolves to a private, loopback or link-local address", host)
				}
			}
			target := net.JoinHostPort(ips[0].String(), port) // dial the checked address itself, never the name again
			if o.testDial != "" {
				target = o.testDial
			}
			return dialer.DialContext(ctx, network, target)
		},
		ForceAttemptHTTP2:     false,
		DisableKeepAlives:     true,
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
	}
	client := &http.Client{
		Timeout:   timeout,
		Transport: transport,
		Jar:       nil,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if o.noRedirect {
				return fmt.Errorf("a redirect on a request that carries a key is refused")
			}
			if len(via) > fetchMaxRedirects {
				return fmt.Errorf("more than %d redirects", fetchMaxRedirects)
			}
			if _, err := checkFetchURL(req.URL.String()); err != nil {
				return fmt.Errorf("redirected to %s: %v", req.URL.Host, err)
			}
			return nil
		},
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "canon-model-refresh")
	req.Header.Set("Accept", "text/html, application/json;q=0.9, text/plain;q=0.5")
	for k, v := range o.headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the server answered %s", resp.Status)
	}
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	okType := false
	for _, t := range fetchOKTypes {
		if strings.HasPrefix(ct, t) {
			okType = true
		}
	}
	if !okType {
		return nil, fmt.Errorf("an answer of type %q is not read", strings.TrimSpace(strings.SplitN(ct, ";", 2)[0]))
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, fetchMaxBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > fetchMaxBody {
		return nil, fmt.Errorf("the page is larger than %d MB", fetchMaxBody>>20)
	}
	return body, nil
}
