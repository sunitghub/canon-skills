//go:build windows

package common

// noFollow: Windows has no O_NOFOLLOW; notRegular's Lstat refusal and underLink's junction check stand alone there (t-f5e4).
const noFollow = 0

// NonblockFlag: none on Windows, which has no FIFO a file could be swapped for (t-f889).
const NonblockFlag = 0
