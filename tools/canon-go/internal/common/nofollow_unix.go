//go:build !windows

package common

import "syscall"

// noFollow makes an open fail on a symlink at the last path component (t-f5e4).
const noFollow = syscall.O_NOFOLLOW

// NonblockFlag opens a file swapped for a FIFO after its Lstat without blocking the request forever (t-f889, t-2800).
const NonblockFlag = syscall.O_NONBLOCK
