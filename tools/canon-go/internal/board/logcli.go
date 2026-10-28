package board

import (
	"fmt"
	"io"
	"time"

	"canon/internal/events"
)

// logCLI is `sprint-check log verify|seal`, reached as `canon log verify|seal` (t-3137). It prints a validated day and a fixed result
// word per line, never file content. verify exits 1 when any day is broken or missing; seal exits 1 when it could not finish.
func logCLI(args []string, stdout, stderr io.Writer) int {
	usage := "usage: canon log verify | seal   (verify reads the activity log; seal seals every closed day not yet sealed)"
	if len(args) != 1 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	home, at := events.Home(), time.Now().UTC()
	switch args[0] {
	case "verify":
		results, ok := events.Verify(home, at)
		counts := map[string]int{}
		for _, r := range results {
			counts[r.Result]++
			line := fmt.Sprintf("%-12s %s", r.Day, r.Result)
			if r.Why != "" {
				line += "  (" + r.Why + ")"
			}
			fmt.Fprintln(stdout, line)
		}
		if len(results) == 0 {
			fmt.Fprintln(stdout, "no activity log yet")
		}
		fmt.Fprintf(stdout, "%d intact, %d broken, %d missing, %d unsealed. A seal shows a day was not changed after it was sealed; it does not show who wrote it.\n",
			counts["intact"], counts["broken"], counts["missing"], counts["unsealed"])
		if !ok {
			return 1
		}
		return 0
	case "seal":
		n, err := events.Seal(home, at)
		if err != nil {
			fmt.Fprintln(stderr, "canon log seal:", err)
			return 1
		}
		fmt.Fprintf(stdout, "sealed %d day(s)\n", n)
		return 0
	}
	fmt.Fprintln(stderr, usage)
	return 2
}
