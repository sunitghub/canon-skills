package board

import (
	"strings"
	"testing"
)

// Protects the list GitHub Sync's Create sends: 1 to 200 whole numbers from 1 to 999999999 become "5,7" for tkt sync-issues --only;
// anything else is refused before tkt runs, so nothing but digits is ever built from a payload.
func TestIssueNumbers(t *testing.T) {
	many := func(n int) []any {
		l := make([]any, n)
		for i := range l {
			l[i] = float64(i + 1)
		}
		return l
	}
	for _, c := range []struct {
		in   any
		want string
		ok   bool
	}{
		{[]any{float64(5), float64(7)}, "5,7", true},
		{[]any{float64(1)}, "1", true},
		{[]any{float64(999999999)}, "999999999", true},
		{many(200), strings.TrimSuffix(strings.Repeat("x,", 0), ","), true},
		{many(201), "", false},
		{[]any{}, "", false},
		{[]any{float64(0)}, "", false},
		{[]any{float64(-1)}, "", false},
		{[]any{float64(1.5)}, "", false},
		{[]any{float64(1000000000)}, "", false},
		{[]any{"7"}, "", false},
		{[]any{float64(7), "; rm"}, "", false},
		{"7", "", false},
		{nil, "", false},
		{float64(7), "", false},
	} {
		got, ok := issueNumbers(c.in)
		if ok != c.ok || (c.ok && c.want != "" && got != c.want) {
			t.Errorf("issueNumbers(%v) = %q, %v; want %q, %v", c.in, got, ok, c.want, c.ok)
		}
		if c.ok && c.want == "" && strings.Count(got, ",") != 199 {
			t.Errorf("200 numbers should give 199 commas: %q", got)
		}
	}
}
