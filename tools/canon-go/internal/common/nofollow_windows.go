//go:build windows

package common

// noFollow: Windows has no O_NOFOLLOW; notRegular's Lstat refusal and underLink's junction check stand alone there (t-f5e4).
const noFollow = 0
