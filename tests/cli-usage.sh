#!/usr/bin/env bash
# cli-usage — t-ffa8: `sprint` and `tkt` help come from tools/sprint-usage.tsv and tools/tkt-usage.tsv through one printer
# (canon_usage, tools/platform-lib.sh). Protects the shipped `sprint`/`tkt` help (bare, help, -h, --help): every command the
# dispatcher accepts is listed once, grouped in the declared order, descriptions at column 29, plain ASCII.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# dispatch_words <cli script> — every command word main()'s dispatch case accepts (help and version words left out).
dispatch_words() {
  awk '/^main\(\) \{/ { m = 1 } m && /^  case "\$cmd" in$/ { c = 1; next } c && /^  esac/ { exit }
       c && match($0, /^    [-a-z|]+\)/) { n = split(substr($0, 5, RLENGTH - 5), w, "|"); for (i = 1; i <= n; i++) print w[i] }' "$1" |
    grep -vxE 'help|--help|-h|--version|-v' | sort
}
# table_words <tsv> — the command words of the table's rows (an alias row `ls|list` gives both).
table_words() { awk -F'\t' '!/^#/ && $1 !~ /^@/ && NF >= 2 { split($2, s, " "); n = split(s[1], w, "|"); for (i = 1; i <= n; i++) print w[i] }' "$1" | sort; }
# drift <cli script> <tsv> — prints each word in one and not the other, or listed twice; silent when they match.
drift() {
  local d t; d="$(dispatch_words "$1")"; t="$(table_words "$2")"
  [[ -n "$d" ]] || { echo "no dispatch words parsed from $1"; return; }
  comm -23 <(echo "$d") <(echo "$t" | sort -u) | sed 's/^/not in the table: /'
  comm -13 <(echo "$d") <(echo "$t" | sort -u) | sed 's/^/not dispatched: /'
  echo "$t" | uniq -d | sed 's/^/listed twice: /'
}
usage() { bash -c 'source "$1"; canon_usage "$2"' _ "$TOOLS_DIR/platform-lib.sh" "$1"; }

for cli in sprint tkt; do
  bin="$TOOLS_DIR/$cli"; tsv="$TOOLS_DIR/$cli-usage.tsv"

  # 1. the table and the dispatcher list the same commands, each once
  assert_eq "" "$(drift "$bin" "$tsv")"
  [[ "$(dispatch_words "$bin" | wc -l)" -ge 20 ]] || fail "$cli: parsed too few dispatch words"

  # 2. bare, help, -h and --help print the same text; it is the table's
  out="$(cd "$W" && "$bin")"
  for a in help -h --help; do assert_eq "$out" "$(cd "$W" && "$bin" "$a")"; done
  assert_eq "$out" "$(usage "$tsv")"

  # 3. plain ASCII, no colour; a line over 80 is only a synopsis that is itself over 78
  if LC_ALL=C grep -n '[^ -~]' <<<"$out"; then fail "$cli: help has a non-ASCII or control byte"; fi
  while IFS= read -r line; do
    [[ ${#line} -le 80 ]] && continue
    awk -F'\t' -v l="$line" '"  " $2 == l { f = 1 } END { exit !f }' "$tsv" || fail "$cli: line over 80 that is not a synopsis: $line"
  done <<<"$out"

  # 4. headings at column 0 in the declared order; each row under its heading, description at column 29, at most 2 lines
  assert_eq "$(awk -F'\t' '$1 == "@group" { print $2 ":" }' "$tsv")" "$(grep -E '^[A-Z][^:]*:$' <<<"$out")"
  printf '%s\n' "$out" > "$W/out"
  awk -F'\t' -v cli="$cli" '
    FNR == NR { L[++n] = $0; next }
    $1 == "@group" || /^#/ || $1 ~ /^@/ || NF < 3 { next }
    {
      g = $1 ":"; syn = $2; head = 0; at = 0
      for (i = 1; i <= n; i++) { if (L[i] == g) head = i; else if (head && L[i] ~ /^[A-Z][^:]*:$/ && !at) break
        if (head && !at && (L[i] == "  " syn || index(L[i], sprintf("  %-26s", syn)) == 1)) at = i }
      if (!at) { printf "%s: %s not under %s\n", cli, syn, g; bad = 1; next }
      d = at; want = sprintf("  %-26s", syn)
      if (length(syn) >= 26) { if (L[at] != "  " syn) { printf "%s: %s shares its line\n", cli, syn; bad = 1 }; d = at + 1; want = sprintf("%28s", "") }
      if (substr(L[d], 1, 28) != want || substr(L[d], 29, 1) !~ /[^ ]/) { printf "%s: %s description not at column 29\n", cli, syn; bad = 1 }
      k = 0; for (j = d + 1; j <= n && substr(L[j], 1, 28) ~ /^ {28}$/ && substr(L[j], 29, 1) != " "; j++) k++
      if (k > 1) { printf "%s: %s description over 2 lines\n", cli, syn; bad = 1 }
    }
    END { exit bad }' "$W/out" "$tsv" || fail "$cli: layout check failed"
done

# 5. a row appended out of order still prints under its own group; an undeclared group fails loudly
s="$W/order.tsv"
printf '@group\tFirst\n@group\tSecond\nSecond\tbeta\tb\nFirst\talpha\ta\nFirst\tlate-one\tadded at the end of the file\n' > "$s"
assert_eq $'\nFirst:\n  alpha                     a\n  late-one                  added at the end of the file\n\nSecond:\n  beta                      b' "$(usage "$s")"
printf 'Nowhere\tx\ty\n' >> "$s"
rc=0; err="$(usage "$s" 2>&1)" || rc=$?
[[ $rc -ne 0 ]] || fail "an undeclared group printed help (rc 0)"
assert_contains "$err" 'group "Nowhere" has no @group row'

# 6. the drift guard can fail: a dropped row and a new dispatcher arm are each caught (scratch copies)
grep -v $'\tpr-ready ' "$TOOLS_DIR/tkt-usage.tsv" > "$W/tkt-usage.tsv"
assert_contains "$(drift "$TOOLS_DIR/tkt" "$W/tkt-usage.tsv")" "not in the table: pr-ready"
sed 's/^    current)        cmd_current ;;$/&\n    brand-new)      cmd_current ;;/' "$TOOLS_DIR/tkt" > "$W/tkt"
assert_contains "$(drift "$W/tkt" "$TOOLS_DIR/tkt-usage.tsv")" "not in the table: brand-new"
printf 'Status\tghost <id>\tnot a command\n' >> "$W/tkt-usage.tsv"
assert_contains "$(drift "$TOOLS_DIR/tkt" "$W/tkt-usage.tsv")" "not dispatched: ghost"

echo "cli-usage: ok"
