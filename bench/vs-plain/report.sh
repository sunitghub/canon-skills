#!/usr/bin/env bash
# report.sh — t-e85f: the canon-vs-plain table from run.sh's rows, as Markdown. Per arm and step: kept rows (status ok) and dropped
# ones (failed, incomplete, contaminated, named with their reasons below the table), mean $, mean minutes, hidden tests passed,
# $ per passing test (sum of $ over sum of passes; n/a when nothing passed), and for canon the mean token-spend phases and gate tokens.
#   bench/vs-plain/report.sh [results.tsv]
set -euo pipefail
BENCH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
f="${1:-$BENCH/results/results.tsv}"
[[ -f "$f" ]] || { echo "report.sh: no results file: $f" >&2; exit 1; }
command -v node >/dev/null || { echo "report.sh: needs node" >&2; exit 1; }
node - "$f" <<'EOF'
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean);
const head = lines.shift().split('\t');
const rows = lines.map(l => Object.fromEntries(l.split('\t').map((v, i) => [head[i], v])));
const num = v => { const m = /^([0-9.]+)([kM]?)$/.exec(v || ''); return m ? Number(m[1]) * ({ k: 1e3, M: 1e6 }[m[2]] || 1) : null; };
const mean = xs => { const v = xs.filter(x => x !== null); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };
const fmt = (x, d = 2) => x === null ? 'n/a' : x.toFixed(d);
const tok = x => x === null ? 'n/a' : x >= 1e6 ? (x / 1e6).toFixed(1) + 'M' : Math.round(x / 1e3) + 'k';
const gateTok = (r, names) => { if (!r.gate_runs || r.gate_runs === 'n/a') return null; let s = 0, any = false;
  for (const g of r.gate_runs.split(';')) { const m = /^([^=]+)=([0-9]+)tok/.exec(g); if (m && names.includes(m[1])) { s += Number(m[2]); any = true; } } return any ? s : null; };
const groups = new Map();
for (const r of rows) { const k = `${r.arm}\t${r.step}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r); }
const out = ['| arm | step | kept | dropped | mean $ | mean min | passed (mean / total) | $ per passing test | planning | implementation | gates | spec check + reviewer tok |',
             '|---|---|---|---|---|---|---|---|---|---|---|---|'];
const notes = [];
for (const k of [...groups.keys()].sort()) {
  const all = groups.get(k), kept = all.filter(r => r.status === 'ok'), dropped = all.filter(r => r.status !== 'ok');
  for (const r of dropped) notes.push(`- ${r.arm} run ${r.run} step ${r.step}: ${r.status} (${r.reason || 'no reason'})`);
  const [arm, step] = k.split('\t');
  const sumCost = kept.reduce((a, r) => a + (num(r.cost_usd) || 0), 0), sumPass = kept.reduce((a, r) => a + (num(r.passed) || 0), 0);
  const canon = arm === 'canon';
  out.push(`| ${arm} | ${step} | ${kept.length} | ${dropped.length} | ${fmt(mean(kept.map(r => num(r.cost_usd))))} | ${fmt(mean(kept.map(r => num(r.minutes))), 1)} | ` +
    `${fmt(mean(kept.map(r => num(r.passed))), 1)} / ${kept[0] ? kept[0].total : 'n/a'} | ${kept.length && sumPass > 0 ? (sumCost / sumPass).toFixed(3) : 'n/a'} | ` +
    (canon ? `${tok(mean(kept.map(r => num(r.planning))))} | ${tok(mean(kept.map(r => num(r.implementation))))} | ${tok(mean(kept.map(r => num(r.gates))))} | ${tok(mean(kept.map(r => gateTok(r, ['speccheck', 'reviewer']))))} |`
           : 'n/a | n/a | n/a | n/a |'));
}
console.log(out.join('\n'));
if (notes.length) console.log('\nDropped rows (not in the means):\n' + notes.join('\n'));
EOF
