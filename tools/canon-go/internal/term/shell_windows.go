//go:build windows

package term

import "context"

// RealShell is nil on Windows: su is not available there yet (t-57ab; the restricted prompt itself works).
var RealShell func(ctx context.Context, root string) error

// RunOnTerminal is nil on Windows for the same reason: tkt send-issue --launch is not available in this Terminal there yet.
var RunOnTerminal func(ctx context.Context, path string, args []string, dir string) error
