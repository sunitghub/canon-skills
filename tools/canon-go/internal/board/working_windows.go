//go:build windows

package board

// pidAlive: a beat records no process id under Git Bash (its ids are not Windows ids), so nothing asks.
func pidAlive(int) bool { return false }
