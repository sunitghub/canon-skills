//go:build !darwin && !linux && !windows

package machine

func readOS(*Facts) {}
