package project_context

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindsGit(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	sub := filepath.Join(dir, "a", "b")
	os.MkdirAll(sub, 0755)
	root := FindProjectRoot(sub)
	if root != dir {
		t.Fatalf("expected %s, got %s", dir, root)
	}
}

func TestFindsTickets(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".tickets"), 0755)
	sub := filepath.Join(dir, "x", "y")
	os.MkdirAll(sub, 0755)
	root := FindProjectRoot(sub)
	if root != dir {
		t.Fatalf("expected %s, got %s", dir, root)
	}
}

func TestGitTakesPrecedence(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	os.MkdirAll(filepath.Join(dir, ".tickets"), 0755)
	sub := filepath.Join(dir, "deep")
	os.MkdirAll(sub, 0755)
	root := FindProjectRoot(sub)
	if root != dir {
		t.Fatalf("expected %s, got %s", dir, root)
	}
}

func TestReturnsStartWhenNoMarker(t *testing.T) {
	dir := t.TempDir()
	root := FindProjectRoot(dir)
	if root != dir {
		t.Fatalf("expected %s, got %s", dir, root)
	}
}

func TestStartIsRoot(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	root := FindProjectRoot(dir)
	if root != dir {
		t.Fatalf("expected %s, got %s", dir, root)
	}
}
