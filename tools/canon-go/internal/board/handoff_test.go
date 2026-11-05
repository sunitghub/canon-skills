package board

import "testing"

// t-eecb: protects GET /api/handoff's `focus` (the board's left rail): an empty Current Focus must read as empty, never as the next
// heading, and a section with text reads its first three lines.
func TestCurrentFocusOf(t *testing.T) {
	cases := []struct{ name, text, want string }{
		{"empty then the next heading (the Windows case)", "<!-- canon:handoff:BEGIN -->\n## Current Focus\n\n## In Progress\n\n## Discoveries\n", ""},
		{"blank lines only", "## Current Focus\n\n\n   \n## Next Steps\ntext\n", ""},
		{"a comment line only", "## Current Focus\n<!-- fill this in -->\n## In Progress\n", ""},
		{"text then the next heading", "## Current Focus\nBuilding the board.\n\n## In Progress\nx\n", "Building the board."},
		{"three lines joined, a fourth dropped", "## Current Focus\none\ntwo\nthree\nfour\n## In Progress\n", "one two three"},
		{"text at the end of the file", "# Handoff\n## Current Focus\nlast section\n", "last section"},
		{"a missing section", "## In Progress\nsomething\n", ""},
		{"a deeper heading is not the section", "### Current Focus\ntext\n", ""},
		{"a ### line inside the section is content, not its end", "## Current Focus\n### Sub\ntext\n## Next\n", "### Sub text"},
		{"a tab after the hashes is still a heading", "##\tCurrent Focus\ntext\n", "text"},
		{"a heading that only starts like it", "## Current Focus Notes\ntext\n", ""},
		{"cut to 80 characters", "## Current Focus\n" + string(make([]byte, 0)) + "aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffgggggggggghhhhhhhhhhiiiiiiiiii\n", "aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffgggggggggghhhhhhhhhh"},
	}
	for _, c := range cases {
		if got := currentFocusOf(c.text); got != c.want {
			t.Errorf("%s: currentFocusOf = %q, want %q", c.name, got, c.want)
		}
	}
}
