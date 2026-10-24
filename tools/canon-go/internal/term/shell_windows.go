//go:build windows

package term

import "context"

// RealShell is nil on Windows: su is not available there yet (t-57ab; the restricted prompt itself works).
var RealShell func(ctx context.Context, root string) error
