//go:build !darwin && !linux && !windows

package machine

func nativeArch() string { return "" }

func readOS(*Facts) {}
