#!/usr/bin/env python3
"""mutant-sweep — generated mutants over a sprint's changed lines (t-1fac).

Usage: mutant-sweep [--base <ref>] [--jobs N] [--timeout S] [--report <md>] --map <file>=<test cmd> ...

Applies every operator in OPS at every occurrence on the lines added or changed since <base>
(default: git merge-base HEAD origin/main) in each mapped file, then runs that file's test command
on a fresh copy of the project, one mutant per copy. Shell, JS, Python and Go. Advisory: exit 0 after a
sweep, 1 when a test fails unmutated (baseline), 2 on a usage or base-ref error, 4 when the canary finds a
leak. The real tree is never written: copies, their HOME/TMPDIR/CANON_HOME/XDG_CONFIG_HOME and every
test's process group live under one temp root that is removed on exit, timeout or interrupt. Caches that
default under HOME (GOMODCACHE, GOPATH, GOCACHE, PLAYWRIGHT_BROWSERS_PATH) are resolved from the real
environment and passed through. Canary (t-eb40): after the sweep, the real ~/.canon is scanned for the
temp root's path; a hit is printed as `mutant-sweep: LEAK <file>` and exits 4, after the report.
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED

# (family, old, new, languages). Symbolic operators match only when no other operator character
# touches them, so `==` is not found inside `===`, `<=` or `=>`.
OPS = [
    ('cmp', '==', '!=', 'sh js py go'), ('cmp', '!=', '==', 'sh js py go'),
    ('cmp', '===', '!==', 'js'), ('cmp', '!==', '===', 'js'),
    ('cmp', ' -eq ', ' -ne ', 'sh'), ('cmp', ' -ne ', ' -eq ', 'sh'),
    ('cmp', ' -lt ', ' -ge ', 'sh'), ('cmp', ' -ge ', ' -lt ', 'sh'),
    ('cmp', ' -gt ', ' -le ', 'sh'), ('cmp', ' -le ', ' -gt ', 'sh'),
    ('cmp', '<', '>=', 'js py go'), ('cmp', '>=', '<', 'js py go'), ('cmp', '>', '<=', 'js py go'), ('cmp', '<=', '>', 'js py go'),
    ('off-by-one', ' -lt ', ' -le ', 'sh'), ('off-by-one', ' -le ', ' -lt ', 'sh'),
    ('off-by-one', ' -gt ', ' -ge ', 'sh'), ('off-by-one', ' -ge ', ' -gt ', 'sh'),
    ('off-by-one', '<', '<=', 'js py go'), ('off-by-one', '<=', '<', 'js py go'),
    ('off-by-one', '>', '>=', 'js py go'), ('off-by-one', '>=', '>', 'js py go'),
    ('bool', '&&', '||', 'sh js go'), ('bool', '||', '&&', 'sh js go'),
    ('bool', ' and ', ' or ', 'py'), ('bool', ' or ', ' and ', 'py'),
    ('bool', 'true', 'false', 'sh js go'), ('bool', 'false', 'true', 'sh js go'),
    ('bool', 'True', 'False', 'py'), ('bool', 'False', 'True', 'py'), ('const', 'None', 'False', 'py'),
    ('identity', ' is not ', ' is ', 'py'), ('identity', ' is ', ' is not ', 'py'),
    ('membership', ' not in ', ' in ', 'py'), ('membership', ' in ', ' not in ', 'py'),
    ('nil', '!= nil', '== nil', 'go'), ('nil', '== nil', '!= nil', 'go'),
    ('err', 'err != nil', 'err == nil', 'go'), ('err', 'err == nil', 'err != nil', 'go'),
    ('code', 'return 0', 'return 1', 'sh py go'), ('code', 'return 1', 'return 0', 'sh py go'),
    ('code', 'exit 0', 'exit 1', 'sh'), ('code', 'exit(0)', 'exit(1)', 'js py'),
    ('code', 'Exit(0)', 'Exit(1)', 'go'), ('code', 'Exit(1)', 'Exit(0)', 'go'),
    ('sort', 'sort -u', 'sort', 'sh'), ('sort', '.sort()', '', 'js py'),
]
SYM = set('=!<>&|')
WORD = re.compile(r'\w')
BLOCK = {'{', '}', 'fi', 'done', 'esac', 'then', 'else', 'do', ';;', '};', '});', ')', '])', '];'}
FAIL_LINE = re.compile(r'^\s*(FAIL\b|not ok\b|✗|✘)')


def lang_of(path, text):
    if path.endswith(('.js', '.mjs', '.cjs')):
        return 'js'
    if path.endswith('.go'):
        return 'go'
    first = text.split('\n', 1)[0]
    if path.endswith('.py') or re.match(r'#!.*\bpython[0-9.]*\b', first):
        return 'py'
    if path.endswith('.sh') or re.match(r'#!.*\b(bash|sh)\b', first):
        return 'sh'
    return None


def string_spans(line, lang):
    if lang == 'py':
        pat = r'"""(?:[^\\]|\\.)*?"""|\'\'\'(?:[^\\]|\\.)*?\'\'\'|"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\''
    elif lang == 'go':
        pat = r'"(?:[^"\\]|\\.)*"|`[^`]*`|\'(?:[^\'\\]|\\.)+\''
    else:
        pat = r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'' if lang == 'js' else r'"(?:[^"\\]|\\.)*"|\'[^\']*\''
    if lang == 'js':
        pat += r'|`(?:[^`\\]|\\.)*`'
    return [(m.start(), m.end()) for m in re.finditer(pat, line)]


def code_end(line, lang, spans):
    """Index where a trailing comment starts (outside strings), else len(line)."""
    inside = lambda i: any(a <= i < b for a, b in spans)
    if lang in ('js', 'go'):
        for m in re.finditer(r'//|/\*', line):
            if not inside(m.start()) and (m.start() == 0 or line[m.start() - 1] != ':'):
                return m.start()
    else:
        for m in re.finditer(r'#', line):
            i = m.start()
            if not inside(i) and (lang == 'py' or i == 0 or line[i - 1] in ' \t;'):
                return i
    return len(line)


def is_comment(stripped, lang):
    if lang == 'go':
        return stripped.startswith(('//', '/*')) or re.match(r'\*(\s|/|$)', stripped) is not None   # `*p = x` is code
    if lang == 'js':
        return stripped.startswith(('//', '/*', '*'))
    return stripped.startswith('#')


def blind_lines(src, lang):
    """0-based lines that open, sit inside or close a multi-line string or block comment: never mutated."""
    if lang not in ('py', 'go'):
        return set()
    text = '\n'.join(src)
    skip, line, i, n = set(), 0, 0, len(text)
    cur = start = None
    while i < n:
        c = text[i]
        if cur:
            if lang == 'py' and c == '\\':
                line += text[i + 1:i + 2] == '\n'
                i += 2
                continue
            if text.startswith(cur, i):
                i += len(cur)
                if start != line:
                    skip.update(range(start, line + 1))
                cur = None
                continue
            line += c == '\n'
            i += 1
            continue
        if c == '\n':
            line += 1
        elif (lang == 'py' and c == '#') or (lang == 'go' and text.startswith('//', i)):
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        elif lang == 'go' and text.startswith('/*', i):
            cur, start, i = '*/', line, i + 2
            continue
        elif lang == 'go' and c == '`':
            cur, start, i = '`', line, i + 1
            continue
        elif lang == 'py' and text.startswith(('"""', "'''"), i):
            cur, start, i = text[i:i + 3], line, i + 3
            continue
        elif c in '"\'':
            j = i + 1
            while j < n and text[j] not in (c, '\n'):
                j += 2 if text[j] == '\\' else 1
            i = j + 1
            continue
        i += 1
    return skip


def bounded(line, k, tok):
    """True when tok at k is a whole operator or word, not part of a longer one."""
    before = line[k - 1] if k else ''
    after = line[k + len(tok)] if k + len(tok) < len(line) else ''
    if tok[0] in SYM or tok[0] in '<>':
        return before not in SYM and after not in SYM
    if WORD.match(tok[0]) and before and WORD.match(before):
        return False
    if WORD.match(tok[-1]) and after and WORD.match(after):
        return False
    return True


def conjunct_drops(line, lo, hi, spans):
    """Drop one operand of a `&&`/`||` chain, within its innermost bracket group."""
    inside = lambda i: any(a <= i < b for a, b in spans)
    stack = [lo]
    group = []
    i = lo
    while i < hi:
        if inside(i):
            i += 1
            continue
        two = line[i:i + 2]
        if two == '[[' or line[i] in '([':
            step = 2 if two == '[[' else 1
            stack.append(i + step)
            i += step
            continue
        if two == ']]' or line[i] in ')]':
            if len(stack) > 1:
                stack.pop()
            i += 2 if two == ']]' else 1
            continue
        if two in ('&&', '||') and bounded(line, i, two):
            group.append((i, stack[-1], len(stack)))
            i += 2
            continue
        i += 1
    out = []
    for k, start, lvl in group:
        # right operand ends at the next operator on the same level or the group's close
        end = hi
        for k2, _, lvl2 in group:
            if k2 > k and lvl2 == lvl:
                end = k2
                break
        else:
            d = 0
            j = k + 2
            while j < hi:
                if not inside(j):
                    if line[j:j + 2] == '[[' or line[j] in '([':
                        d += 1
                    elif line[j:j + 2] == ']]' or line[j] in ')]':
                        if d == 0:
                            end = j
                            break
                        d -= 1
                    elif line[j] == ';' and d == 0 and lvl == 1:
                        end = j
                        break
                j += 2 if line[j:j + 2] in ('[[', ']]') else 1
        prev = start
        for k2, _, lvl2 in group:
            if k2 < k and lvl2 == lvl and k2 >= start:
                prev = k2 + 2
        left = line[prev:k]
        right = line[k + 2:end]
        if left.strip() and right.strip():
            lead = left[:len(left) - len(left.lstrip())]
            out.append((f'drop-conjunct: left of {line[k:k+2]}@{k+1}', line[:prev] + lead + right.lstrip() + line[end:]))
            out.append((f'drop-conjunct: right of {line[k:k+2]}@{k+1}', line[:k].rstrip() + (' ' if line[end:end + 1] in (']', ')') else '') + line[end:]))
    return out


SKIPPED = {'var': 0, 'out': 0}   # mutants the two shell rules left out (t-2602), reported by main
BARE_VAR = re.compile(r'^(?:\$\{[^}]*\}|\$\w+)(?:[/:](?:\$\{[^}]*\}|\$\w+))*$')
OUTPUT_ONLY = re.compile(r'^\s*(?:echo|printf)(?:\s+[^\s|;&<>(){}`$\\]*)*\s*(?:>&2)?\s*$')


def output_only(line, spans, hi):
    """A shell line that only prints: echo/printf, optionally >&2, nothing that does work."""
    if '$(' in line[:hi] or '`' in line[:hi]:
        return False
    code, last = '', 0
    for a, b in spans:
        if b > hi:
            break
        code += line[last:a] + 'S'
        last = b
    return bool(OUTPUT_ONLY.match(code + line[last:hi]))


def mutants_for_line(line, lang):
    spans = string_spans(line, lang)
    hi = code_end(line, lang, spans)
    inside = lambda i: any(a <= i < b for a, b in spans)
    out = []
    stripped = line.strip()
    if stripped not in BLOCK and not stripped.endswith('{'):
        out.append(('delete-line', ''))
    for fam, old, new, langs in OPS:
        if lang not in langs.split():
            continue
        j = 0
        while True:
            k = line.find(old, j, hi)
            if k < 0:
                break
            j = k + 1
            if inside(k) or not bounded(line, k, old):
                continue
            if lang == 'go' and old[0] == '<' and line[k + len(old):k + len(old) + 1] == '-':
                continue   # a channel receive, not a comparison
            out.append((f'{fam}: {old.strip() or old} -> {new.strip() or repr(new)}@{k+1}', line[:k] + new + line[k + len(old):]))
    # negation removal
    if lang == 'py':
        for m in re.finditer(r'(?<!\w)not (?!in\b)', line[:hi]):
            k = m.start()
            if not inside(k) and not line[:k].endswith('is '):
                out.append((f'negation: drop not@{k+1}', line[:k] + line[m.end():]))
    else:
        neg = r'(?:^\s*|\[\[ |\bif |\bwhile |; |&& |\|\| )(! )' if lang == 'sh' else r'(!)(?=[\w(!$])'
        for m in re.finditer(neg, line[:hi]):
            k = m.start(1)
            if not inside(k) and (lang == 'sh' or not k or line[k - 1] not in SYM):
                out.append((f'negation: drop !@{k+1}', line[:k] + line[m.end(1):]))
    if lang == 'py':
        m = re.match(r'(\s*)return (?!None\s*$)(\S.*?)\s*$', line[:hi])
        if m and not inside(m.start(2)):
            out.append((f'return-value: {m.group(2)[:20]} -> None@{m.start(2)+1}', line[:m.start(2)] + 'None' + line[m.end(2):]))
        for m in re.finditer(r'\b(sorted|set)\(', line[:hi]):
            if inside(m.start()):
                continue
            depth, j = 1, m.end()
            while j < hi and depth:
                if not inside(j):
                    depth += (line[j] in '([{') - (line[j] in ')]}')
                    if depth == 1 and line[j] == ',':
                        break
                j += 1
            if depth == 0:
                out.append((f'sort: drop {m.group(1)}()@{m.start()+1}', line[:m.start()] + line[m.end():j - 1] + line[j:]))
    if lang == 'sh':
        for m in re.finditer(r'\bexit ([1-9]\d*)\b', line[:hi]):
            if not inside(m.start()):
                out.append((f'code: exit {m.group(1)} -> exit 0@{m.start()+1}', line[:m.start()] + 'exit 0' + line[m.end():]))
        for m in re.finditer(r'\s*\|\s*uniq\b[^|;)]*', line[:hi]):
            if not inside(m.start()):
                out.append((f'sort: drop uniq@{m.start()+1}', line[:m.start()] + line[m.end():]))
        # widened literal: the pattern after == / != in [[ ]] loses its tail
        for m in re.finditer(r'(?<= )(?:==|!=) ("?)([^\s"\]]+)\1(?= )', line[:hi]):
            pat = m.group(2)
            cut = max(pat.rfind('/'), pat.rfind('.'), pat.rfind('-'))
            wide = pat[:cut + 1] + '*' if cut >= 0 and not pat.endswith('*') else ('*' if pat != '*' else None)
            if wide and wide != pat and '$' not in pat[cut + 1:]:
                s, e = m.start(2), m.end(2)
                if m.group(1):
                    s, e = s - 1, e + 1
                    wide = '"' + pat[:cut + 1] + '"*' if cut >= 0 else '*'
                out.append((f'widen: {pat} -> {wide.replace(chr(34), "")}@{s+1}', line[:s] + wide + line[e:]))
    # dropped anchors and emptied string constants
    for a, b in spans:
        if b > hi:
            continue
        n = 3 if line[a:a + 3] in ('"""', "'''") else 1
        body = line[a + n:b - n]
        q = line[a:a + n]
        if lang == 'go' and q == "'":
            continue   # a rune literal cannot be empty
        if body.startswith('^'):
            out.append((f'drop-anchor: ^@{a+n+1}', line[:a + n] + body[1:] + line[b - n:]))
        if body.endswith('$') and not body.endswith('\\$') and len(body) > 1:
            out.append((f'drop-anchor: $@{b-n}', line[:b - n - 1] + line[b - n:]))
        if lang == 'sh' and q == '"' and BARE_VAR.match(body):
            SKIPPED['var'] += 1   # emptying a lone variable only proves a fallback to the cwd or a default
            continue
        if body:
            out.append((f'empty-string: {q}{body[:20]}{q}@{a+1}', line[:a] + q + q + line[b:]))
    if lang == 'sh':
        m = re.search(r'=~ \^', line[:hi])
        if m and not inside(m.start()):
            out.append((f'drop-anchor: ^@{m.start()+4}', line[:m.start() + 3] + line[m.start() + 4:]))
        m = re.search(r'=~ \S*[^\\]\$(?= ]])', line[:hi])
        if m and not inside(m.start()):
            k = m.end() - 1
            out.append((f'drop-anchor: $@{k+1}', line[:k] + line[k + 1:]))
    if lang == 'js':
        for m in re.finditer(r'(?:(?<=[=(,:\[!&|?{;])|(?<=[=(,:\[!&|?{;]\s)|(?<=\breturn\s))/(\^?)((?:[^/\\\n]|\\.)+?)(\$?)/[gimsuy]*', line[:hi]):
            if inside(m.start()):
                continue
            if m.group(1):
                out.append((f'drop-anchor: ^@{m.start(1)+1}', line[:m.start(1)] + line[m.end(1):]))
            if m.group(3):
                out.append((f'drop-anchor: $@{m.start(3)+1}', line[:m.start(3)] + line[m.end(3):]))
    out.extend(conjunct_drops(line, 0, hi, spans))
    if lang == 'sh' and output_only(line, spans, hi):
        keep = [x for x in out if x[0] == 'delete-line']
        SKIPPED['out'] += len(out) - len(keep)
        return keep
    if lang in ('sh', 'js'):
        return out
    seen = {}   # py/go: two rows can yield the same text; keep the first position, the later (more specific) name
    for name, new in out:
        seen[new] = name
    return [(name, new) for new, name in seen.items()]


def git(*args, cwd=None):
    return subprocess.run(['git', *args], cwd=cwd, capture_output=True, text=True)


def changed_lines(base, path, untracked):
    if path in untracked:
        return None  # every line
    r = git('diff', '-U0', '--no-ext-diff', base, '--', path)
    if r.returncode:
        raise SystemExit(f'mutant-sweep: git diff failed for {path}: {r.stderr.strip()}')
    lines = set()
    for m in re.finditer(r'^@@ -\S+ \+(\d+)(?:,(\d+))? @@', r.stdout, re.M):
        start, count = int(m.group(1)), int(m.group(2) or 1)
        lines.update(range(start, start + count))
    return lines


def is_test_path(p):
    parts = p.split('/')
    return any(x in ('tests', 'test', '__tests__', 'spec') for x in parts[:-1]) or re.search(r'\.(test|spec)\.\w+$|_test\.(go|py)$|^test_\w+\.py$', parts[-1])


class Sweep:
    def __init__(self, root, top, files, env_base, timeout):
        self.root, self.top, self.files, self.timeout = root, top, files, timeout
        self.env_base = env_base
        self.lock = threading.Lock()
        self.groups = set()
        self.stopping = False
        self.n = 0

    def copy(self, dest):
        for rel in self.files:
            src = os.path.join(self.top, rel)
            dst = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.islink(src):
                os.symlink(os.readlink(src), dst)
            elif os.path.isfile(src):
                shutil.copy2(src, dst)

    def run(self, cmd, path=None, new_text=None, lang=None):
        """Returns (status, detail). One fresh copy, removed before returning."""
        with self.lock:
            if self.stopping:
                return ('STOPPED', '')
            self.n += 1
            d = os.path.join(self.root, f'm{self.n}')
        try:
            work = os.path.join(d, 'r')
            for sub in ('home', 'tmp', 'canon-home', 'xdg'):
                os.makedirs(os.path.join(d, sub))
            self.copy(work)
            if path is not None:
                f = os.path.join(work, path)
                with open(f, 'w') as fh:
                    fh.write(new_text)
                check = {'sh': ['bash', '-n', f], 'js': ['node', '--check', f], 'py': [sys.executable, '-m', 'py_compile', f],
                         'go': ['gofmt', '-e', f]}[lang]
                if subprocess.run(check, capture_output=True).returncode:
                    return ('INVALID', '')
            env = dict(self.env_base, HOME=os.path.join(d, 'home'), TMPDIR=os.path.join(d, 'tmp'), CANON_HOME=os.path.join(d, 'canon-home'),
                       XDG_CONFIG_HOME=os.path.join(d, 'xdg'))
            log = os.path.join(d, 'out.log')
            with open(log, 'wb') as out:
                p = subprocess.Popen(['bash', '-c', cmd], cwd=work, env=env, stdout=out, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
            with self.lock:
                self.groups.add(p.pid)
                if self.stopping:
                    self._kill(p.pid)
            timed_out = False
            try:
                rc = p.wait(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                rc = None
            # the test's own background children die with its group, finished or not
            self._kill(p.pid)
            p.wait()
            with self.lock:
                self.groups.discard(p.pid)
            with open(log, errors='replace') as fh:
                text = fh.read()
            if timed_out:
                return ('KILLED(timeout)', f'no exit in {self.timeout}s')
            if rc == 0:
                return ('SURVIVED', '')
            fl = [x.strip() for x in text.splitlines() if FAIL_LINE.match(x)]
            if fl:
                return ('KILLED', fl[0][:120])
            tail = [x for x in text.splitlines() if x.strip()]
            return ('KILLED(crash)', f'exit {rc}: ' + (tail[-1][:100] if tail else ''))
        finally:
            shutil.rmtree(d, ignore_errors=True)

    @staticmethod
    def _kill(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def stop(self):
        with self.lock:
            self.stopping = True
            for g in list(self.groups):
                self._kill(g)


def home_caches():
    """Cache locations that default under HOME, resolved from the real environment before HOME is pinned."""
    out = {}
    if shutil.which('go'):
        keys = ['GOMODCACHE', 'GOPATH', 'GOCACHE']
        try:
            r = subprocess.run(['go', 'env'] + keys, capture_output=True, text=True, timeout=30)
            vals = r.stdout.split('\n') if r.returncode == 0 else []
        except (OSError, subprocess.TimeoutExpired):
            vals = []
        out.update({k: v.strip() for k, v in zip(keys, vals) if v.strip()})
    pw = os.environ.get('PLAYWRIGHT_BROWSERS_PATH')
    if not pw:
        local = os.environ.get('LOCALAPPDATA', '')
        for c in (os.path.expanduser('~/Library/Caches/ms-playwright'), os.path.expanduser('~/.cache/ms-playwright'),
                  os.path.join(local, 'ms-playwright') if local else ''):
            if c and os.path.isdir(c):
                pw = c
                break
    if pw:
        out['PLAYWRIGHT_BROWSERS_PATH'] = pw
    return out


def canary(real_home, root, max_files=2000, max_bytes=5 << 20):
    """Files under the real ~/.canon that name the sweep root: anything a mutant wrote there carries that path.
    .git and node_modules are skipped, so a checkout's objects never use up the file budget before events/."""
    needles = {root.encode(), os.path.realpath(root).encode()}   # macOS: /var/... is /private/var/... to getcwd
    hits, seen = [], 0
    for dirpath, dirs, names in os.walk(os.path.join(real_home, '.canon')):
        dirs[:] = sorted(x for x in dirs if x not in ('.git', 'node_modules'))
        for n in sorted(names):
            f = os.path.join(dirpath, n)
            if seen >= max_files:
                return hits
            try:
                if os.path.islink(f) or not os.path.isfile(f) or os.path.getsize(f) >= max_bytes:
                    continue
                seen += 1
                with open(f, 'rb') as fh:
                    data = fh.read()
            except OSError:   # a real writer can remove or rotate a file mid-scan
                continue
            if b'\0' not in data and any(x in data for x in needles):
                hits.append(f)
    return hits


def main():
    real_home = os.path.expanduser('~')   # read at launch, before anything pins HOME
    ap = argparse.ArgumentParser(prog='mutant-sweep', description='Generated mutants over changed lines (advisory).')
    ap.add_argument('--base')
    ap.add_argument('--jobs', type=int, default=min(os.cpu_count() or 1, 8))
    ap.add_argument('--timeout', type=int, default=300)
    ap.add_argument('--report')
    ap.add_argument('--map', action='append', default=[], metavar='FILE=CMD')
    a = ap.parse_args()
    if not a.map:
        ap.error('at least one --map <file>=<test cmd> is required')
    if a.jobs < 1 or a.timeout < 1:
        ap.error('--jobs and --timeout must be at least 1')
    r = git('rev-parse', '--show-toplevel')
    if r.returncode:
        print('mutant-sweep: not inside a git work tree', file=sys.stderr)
        return 2
    top = r.stdout.strip()
    os.chdir(top)
    if a.base:
        r = git('rev-parse', '--verify', '--quiet', a.base + '^{commit}')
        what = f'--base {a.base} is not a commit'
    else:
        r = git('merge-base', 'HEAD', 'origin/main')
        what = 'git merge-base HEAD origin/main failed; pass --base <ref>'
    if r.returncode or not r.stdout.strip():
        print(f'mutant-sweep: {what}', file=sys.stderr)
        return 2
    base = r.stdout.strip()

    maps = {}
    for m in a.map:
        f, sep, cmd = m.partition('=')
        if not sep or not f or not cmd.strip():
            ap.error(f'--map needs <file>=<test cmd>: {m!r}')
        f = os.path.normpath(f)
        if os.path.isabs(f) or f == '..' or f.startswith('..' + os.sep):
            ap.error(f'--map file must be inside the project: {f}')
        maps[f] = cmd

    r = git('ls-files', '-z', '--cached', '--others', '--exclude-standard')
    files = [x for x in r.stdout.split('\0') if x]
    untracked = set(x for x in git('ls-files', '-z', '--others', '--exclude-standard').stdout.split('\0') if x)
    changed = set(x for x in git('diff', '-z', '--name-only', '--no-renames', base).stdout.split('\0') if x) | untracked

    unsupported, unmapped, todo = [], [], []
    for path in sorted(changed):
        if path in maps or not os.path.isfile(path) or os.path.islink(path) or is_test_path(path):
            continue
        with open(path, errors='replace') as fh:
            if lang_of(path, fh.read(4096)):
                unmapped.append(path)
    for path, cmd in maps.items():
        if not os.path.isfile(path) or os.path.islink(path):
            print(f'mutant-sweep: --map file not found: {path}', file=sys.stderr)
            return 2
        text = open(path, errors='replace').read()
        lang = lang_of(path, text)
        if lang is None:
            unsupported.append(path)
            continue
        if lang == 'js' and not shutil.which('node'):
            unsupported.append(path + ' (node not found)')
            continue
        if lang == 'go' and not shutil.which('gofmt'):
            unsupported.append(path + ' (gofmt not found)')
            continue
        want = changed_lines(base, path, untracked) if path in changed else set()
        src = text.split('\n')
        blind = blind_lines(src, lang)
        for i, line in enumerate(src):
            if (want is not None and i + 1 not in want) or i in blind:
                continue
            if not line.strip() or is_comment(line.strip(), lang):
                continue
            for name, new in mutants_for_line(line, lang):
                if new == line:
                    continue
                todo.append((path, i, name, '\n'.join(src[:i] + [new] + src[i + 1:]), lang, cmd))

    nskip = SKIPPED['var'] + SKIPPED['out']
    skipped_note = f"skipped by rule: {nskip} (bare-variable strings {SKIPPED['var']}, output-only lines {SKIPPED['out']})" if nskip else ''
    env = dict(os.environ, **home_caches())
    root = tempfile.mkdtemp(prefix='mutant-sweep.')
    if any(t[4] == 'go' for t in todo):
        env['GOCACHE'] = os.path.join(root, 'gocache')   # one cache for the sweep's builds (go's cache is safe for parallel use), gone with the root
    sweep = Sweep(root, top, files, env, a.timeout)

    def on_signal(sig, _frm):
        sweep.stop()
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    results = []
    ex = ThreadPoolExecutor(a.jobs)
    try:
        print(f'mutant-sweep: base {base[:12]}, {len(todo)} mutants in {len(maps) - len(unsupported)} file(s)', flush=True)
        if skipped_note:
            print(skipped_note, flush=True)
        for p in unsupported:
            print(f'unsupported: {p}')
        for p in unmapped:
            print(f'unmapped: {p}')
        # the main thread only waits, so a signal never lands between starting a test and recording its group
        base_futs = {ex.submit(sweep.run, cmd): cmd for cmd in sorted({t[5] for t in todo})}
        pending = set(base_futs)
        while pending:
            _, pending = wait(pending, timeout=0.5)
        for f, cmd in base_futs.items():
            st, why = f.result()
            if st != 'SURVIVED':
                print(f'baseline fails: {cmd} ({st} {why})'.rstrip(), file=sys.stderr)
                return 1
        futs = {ex.submit(sweep.run, cmd, path, new, lang): (path, i, name) for path, i, name, new, lang, cmd in todo}
        pending = set(futs)
        while pending:
            done, pending = wait(pending, timeout=0.5, return_when=FIRST_COMPLETED)
            for f in done:
                results.append((*futs[f], *f.result()))
    except KeyboardInterrupt:
        sweep.stop()
        ex.shutdown(wait=True, cancel_futures=True)
        print('mutant-sweep: interrupted; every test stopped and temp files removed', file=sys.stderr)
        return 130
    finally:
        sweep.stop()
        ex.shutdown(wait=True, cancel_futures=True)
        shutil.rmtree(root, ignore_errors=True)

    order = ['KILLED', 'KILLED(crash)', 'KILLED(timeout)', 'SURVIVED', 'INVALID']
    counts = {k: sum(1 for x in results if x[3] == k) for k in order}
    print('  '.join(f'{k} {v}' for k, v in counts.items()))
    results.sort(key=lambda x: (x[0], x[1], x[2]))
    srcs = {p: open(p, errors='replace').read().split('\n') for p in maps if p not in unsupported}
    surv = [x for x in results if x[3] == 'SURVIVED']
    for path, i, name, st, why in surv:
        print(f'{path}:{i + 1} {name} | {srcs[path][i].strip()[:100]}')
    leaks = canary(real_home, root)
    if a.report:
        with open(a.report, 'w') as fh:
            fh.write('# Mutation Report\n\n' + f'Base `{base[:12]}`. ' + ', '.join(f'{k} {v}' for k, v in counts.items()) + '.\n\n')
            fh.write('Each mutant ran in its own copy with HOME, TMPDIR, CANON_HOME and XDG_CONFIG_HOME pinned inside it. Canary: '
                     + (', '.join(f'LEAK `{f}`' for f in leaks) if leaks else 'real ~/.canon untouched') + '.\n\n')
            if skipped_note:
                fh.write(skipped_note + '\n\n')
            for p in unsupported:
                fh.write(f'- unsupported: `{p}`\n')
            for p in unmapped:
                fh.write(f'- unmapped: `{p}`\n')
            fh.write('\n| File:line | Mutation | Verdict | Source |\n|---|---|---|---|\n')
            cell = lambda t: t.replace('|', '\\|')
            for path, i, name, st, why in surv:
                fh.write(f'| {path}:{i + 1} | `{cell(name)}` | SURVIVED | `{cell(srcs[path][i].strip()[:80])}` |\n')
    for f in leaks:
        print(f'mutant-sweep: LEAK {f} names the sweep root {root}', file=sys.stderr)
    if leaks:
        return 4
    print('canary: real ~/.canon untouched')
    return 0


if __name__ == '__main__':
    sys.exit(main())
