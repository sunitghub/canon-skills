package models

type Ticket struct {
	ID                 string `json:"id"`
	Status             string `json:"status"`
	Title              string `json:"title"`
	Description        string `json:"description,omitempty"`
	Priority           string `json:"priority,omitempty"`
	AcceptanceCriteria string `json:"acceptance_criteria,omitempty"`
}

type Handoff struct {
	ActiveTasks []string `json:"active_tasks"`
	Context     string   `json:"context"`
}
