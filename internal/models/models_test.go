package models

import "testing"

func TestMinimal(t *testing.T) {
	tr := Ticket{ID: "TKT-1", Status: "open"}
	if tr.ID != "TKT-1" {
		t.Fatalf("expected TKT-1, got %s", tr.ID)
	}
	if tr.Status != "open" {
		t.Fatalf("expected open, got %s", tr.Status)
	}
}

func TestFull(t *testing.T) {
	tr := Ticket{
		ID:                 "TKT-2",
		Status:             "closed",
		Title:              "My ticket",
		AcceptanceCriteria: "Must work",
		Description:        "Do the thing",
		Priority:           "high",
	}
	if tr.Title != "My ticket" {
		t.Fatalf("expected My ticket, got %s", tr.Title)
	}
	if tr.AcceptanceCriteria != "Must work" {
		t.Fatal("acceptance criterion mismatch")
	}
	if tr.Description != "Do the thing" {
		t.Fatal("description mismatch")
	}
	if tr.Priority != "high" {
		t.Fatal("priority mismatch")
	}
}
