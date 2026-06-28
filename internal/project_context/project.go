package project_context

import (
	"os"
	"path/filepath"
)

func FindProjectRoot(start string) string {
	d, err := filepath.Abs(start)
	if err != nil {
		return start
	}
	for depth := 0; depth < 50; depth++ {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return d
		}
		if _, err := os.Stat(filepath.Join(d, ".tickets")); err == nil {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return start
		}
		d = parent
	}
	return start
}
