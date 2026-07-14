package main

import "testing"

func TestFormatResult(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "plain success",
			input: `{"is_error":false,"session_id":"abc-123","result":"hello"}`,
			want:  "False\tabc-123\thello",
		},
		{
			name:  "default is_error true when field missing",
			input: `{"session_id":"abc-123","result":"hello"}`,
			want:  "True\tabc-123\thello",
		},
		{
			name:  "default session_id and empty result when missing",
			input: `{"is_error":false}`,
			want:  "False\tunknown\t",
		},
		{
			name:  "embedded quotes and backslashes unescaped correctly",
			input: `{"is_error":true,"session_id":"s1","result":"line1\nline2 \"quoted\" back\\slash"}`,
			want:  "True\ts1\tline1\x02line2 \"quoted\" back\\slash",
		},
		{
			name:  "multiple embedded newlines re-encoded to \\x02",
			input: `{"is_error":true,"session_id":"s1","result":"a\nb\nc"}`,
			want:  "True\ts1\ta\x02b\x02c",
		},
		{
			name:  "\\uXXXX escape decoded to UTF-8",
			input: `{"is_error":false,"session_id":"s1","result":"caf\u00e9"}`,
			want:  "False\ts1\tcafé",
		},
		{
			name:  "malformed JSON falls back to PARSE_ERROR, not a crash",
			input: `not json`,
			want:  "PARSE_ERROR\t\t",
		},
		{
			name:  "empty input falls back to PARSE_ERROR",
			input: ``,
			want:  "PARSE_ERROR\t\t",
		},
		{
			name:  "truncated JSON falls back to PARSE_ERROR",
			input: `{"is_error":false,"session_id":`,
			want:  "PARSE_ERROR\t\t",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := formatResult([]byte(tc.input))
			if got != tc.want {
				t.Errorf("formatResult(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}
