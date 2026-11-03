//go:build !windows

package common

import "syscall"

// noFollow makes an open fail on a symlink at the last path component (t-f5e4).
const noFollow = syscall.O_NOFOLLOW
