package board

import (
	"strings"
	"testing"
)

// Protects the stopped-session banner: a Terminal that ended with the daemon says it is a terminal and how to get another,
// instead of the scratch-session text about a conversation it never had.
func TestInterruptedReasonNamesATerminal(t *testing.T) {
	if got := interruptedReason("s-ab12", "/p", "/p", "term"); !strings.HasPrefix(got, "terminal") || strings.Contains(got, "conversation") {
		t.Errorf("terminal reason = %q", got)
	}
	if got := interruptedReason("s-ab12", "/p", "/p", "claude"); !strings.Contains(got, "conversation") {
		t.Errorf("scratch agent reason = %q", got)
	}
}
