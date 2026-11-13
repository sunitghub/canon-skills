# Research: path identity, rule registries, small data tables, and testing a cross-OS rule

Report for t-9915, written 2026-11-13. It feeds t-141a, which builds from it. It changes no code.

**What this is.** canon has lost nine tickets to one mistake: a folder has several spellings (macOS `/var` and `/private/var`; Windows `C:\x`, `C:/x` and `/c/x`), and code compared the spellings as text. This report reads how mature tools and standards handle four related questions, then states what each source supports and what it does not.

**How to read the evidence.** Every claim cites a source number (S1, S2, ...). The source table at the end gives each URL, the date it was read (all `read 2026-11-13`), and how:

- **raw** means the author fetched the raw page or file and confirmed the quoted wording, with line numbers where the file allows.
- **digest** means a research agent read it through WebFetch, which returns a model-written summary, not byte-exact text. A digest quote may differ slightly from the live page. A digest claim is evidence of what the page says, not a verified quotation.
- Anything not read is listed under "Not verified" and is never cited as read.

A source that says nothing about a question is reported as "no guidance found", not as support.

## Summary of recommendations

1. **No standard says "compare by file identity when both paths exist, a normalised string otherwise".** None of the Go, Python, Rust or Node docs read says it (S8-S15; the Node `fs` page, S16, was read only in part). That rule is canon's own design choice, built on real primitives (Go `os.SameFile`, Python `os.path.samefile`). Call it a design, not a standard.
2. **Make the string key a pure function** (no filesystem, no OS branch, no environment), the way Python's `ntpath` and Node's `path.win32` are. A pure function runs the same corpus on every OS (S36, S37). Go's own tests cannot do this: they pick Windows cases by `runtime.GOOS` (S35).
3. **Keep the existing key form `/c/x`** (drive letter lower-cased, nothing else folded). Delete the other three Go and awk definitions; there should be exactly one per language, with the same output (section 1.1).
4. **Never lower-case the whole path in a key.** The Windows case rules are uncertain (S2, S3), and the failure direction matters: a key that misses a match is safe, a key that merges two real folders is not.
5. **Do not map canon's finding data onto SARIF as storage.** If an export is ever wanted, `ruleId` takes the permanent `P-nnn` id and the slug is the rule name (S17). No source gives a recurrence counting method, so the recurrence counter stays canon's own.
6. **Keep a TSV for the 13-row finding-class table**, with a validation test (constant tab count, unique key, known values, no stray whitespace). Do not turn the promoted rules into a second TSV now.
7. **Test the key with one shared corpus file read by both the bash and the Go tests**, on every OS, plus a small real-Windows check for what only Git Bash does (the argument conversion).

## 1. Path identity across operating systems

### 1.1 What canon does today

canon has four definitions of "the same path", with three different output forms. This is the mistake class itself.

| Where | What it does | `C:\x` and `/c/x` become |
|---|---|---|
| `canon_awk_pkey` in `tools/platform-lib.sh` (awk, used by `sprint token-spend`) | backslashes to `/`, drive letter lower-cased, trailing slash dropped, UNC kept as `//host/share`; nothing else folded | both `/c/x` |
| `pathKey` in `tools/canon-go/internal/board/main.go` | resolves symlinks, then lower-cases the **whole path on every OS**, backslashes to `/` | `c:/x` and `/c/x` (still different) |
| `samePath` in `tools/canon-go/internal/board/skilleval.go` | `strings.EqualFold` on Windows only (by `runtime.GOOS`), `filepath.Clean` | no `/c/x` handling |
| `normPath` in `tools/canon-go/internal/board/machine.go` | `/c/x` to `C:/x`, drive-letter paths lower-cased, trailing slash trimmed, no symlink resolution | both `c:/x` |

There are also 26 ad-hoc `filepath.EvalSymlinks` calls in the Go board code (counted 2026-11-13) and 53 uses of `pwd -P`, `cygpath`, `realpath` or `readlink -f` in the shell tools. The awk version states the intended contract: "A key is for comparing, never a path to hand to another program", and it lists what it does not handle (`\\?\` and device paths, drive-relative `C:x`, 8.3 names, per-folder case sensitivity).

### 1.2 What the Windows sources say

- **Seven path kinds exist** before normalising: DOS, UNC, fully qualified DOS, legacy device, root-relative `\`, drive-relative `C:`, and relative; device paths begin with two separators and `?` or `.` (S1, raw for the key sentences below).
- **Drive-relative paths depend on hidden state.** `C:Projects\x` is "a relative path from the current directory of the C: drive", and "use of the second form when the first is intended is a common source of bugs" (S1, raw). The drive's current directory is per process, so no pure string function can resolve it (S1, S2).
- **Normalisation steps** are: identify the path kind, apply the current directory, canonicalise separators, evaluate `.` and `..`, trim certain characters (S1). Forward slashes become backslashes and "a series of slashes that follow the first two slashes are collapsed into a single slash" (S1). If the path does not end in a separator, all trailing periods and spaces are removed (S1, raw). A segment of three or more periods is a real name (S1).
- **`\\?\` skips normalisation**, but only when the path starts exactly with it (S1, raw: "Unless the path starts exactly with `\\?\` ... it is normalized"). `\\.\` addresses the device namespace, not files, and most APIs do not accept it (S2).
- **The same file has several spellings.** The page opens one file through six: `c:\`, `\\127.0.0.1\c$\`, `\\LOCALHOST\c$\`, `\\.\c:\`, `\\?\c:\` and `\\.\UNC\LOCALHOST\c$\` (S1, digest). A UNC path's volume is `\\server\share`. A text comparison cannot tell these apart.
- **Case.** "Directory and file name comparisons are case-insensitive" (S1, raw), drive letters included ("`D:\` and `d:\` refer to the same volume", S2, raw). But Win32 also says "Do not assume case sensitivity" (S2, raw), and NTFS can mark a directory case-sensitive since Windows 10 build 17107; children inherit it, and Windows tools may then fail on such folders (S3, digest).
- **8.3 short names** may not exist or be stable: "do not make the assumption that the 8.3 alias already exists on-disk" (S2, raw). Resolving them needs `GetLongPathName` or `cygpath -l`, which read the filesystem (S2, S7).
- **Linked files.** NTFS supports linked files and directories that follow the same naming rules (S2); the pages on junctions and reparse points were not read.

### 1.3 What MSYS2, Cygwin and Git for Windows say

- **Argument conversion exists.** When MSYS2 launches a native program, "all the arguments that look like Unix paths will get auto converted to Windows", and the page admits "it's also not perfect" (S4, raw for the first sentence).
- **Opt-outs.** `MSYS2_ARG_CONV_EXCL` excludes arguments by prefix, or everything with `*`; `MSYS2_ENV_CONV_EXCL` does the same for environment variables (S4, raw for the variable names). The MSYS2 page does **not** mention `MSYS_NO_PATHCONV` (S4: zero matches on the raw page). Git for Windows' own runtime does honour it: `getenv("MSYS_NO_PATHCONV")` at `msys2_path_conv.cc:347-349` (S5, raw). The same file leaves some arguments unconverted on purpose: Git's `:file.txt` and `<rev>:./name` forms, IPv6 addresses, `~/.file`, and strings containing `*`, `?`, `[`, `]` or quotes (S5, digest).
- **Release notes.** Git for Windows lists "command-line options starting with a slash" as a known issue (S6, digest, first 100,000 of about 260,000 characters only).
- **`cygpath` converts the three forms**: `-u` Unix, `-w` Windows, `-m` Windows with forward slashes (S7, digest). MSYS2's page shows `cygpath -u C:\foo` giving `/c/foo` and `cygpath -m /ucrt64/bin` giving `C:/msys64/ucrt64/bin` (S4, raw).
- **Not shown by any documentation read:** that a `/c/Users/x` argument becomes `C:/Users/x` for a native exe. The general rule and the cygpath examples support it, and canon observed it on the Windows VM (t-134b), but no page shows that exact conversion. It stays "observed, not documented" here.

### 1.4 What the language libraries say

- **Go.** `filepath.Clean` is "purely lexical" and `IsLocal` too (S8, raw in `path.go` lines 29 and 70). `Abs` is "not guaranteed to be unique" (S8, digest). `os.SameFile` compares `Stat` results: "on Unix this means that the device and inode fields of the two underlying structures are identical; on other systems the decision may be based on the path names" (S9, raw, `src/os/types.go` lines 64-66). No statement on case folding in `filepath` (S8). The Windows rule for `SameFile` is not documented in the pages read.
- **Python.** `os.path.samefile` is "determined by the device number and i-node number" and, since 3.4, "Windows now uses the same implementation as all other platforms" (S10, raw). `normcase` on Windows lower-cases and converts `/` to `\`, and returns the path unchanged elsewhere (S10, raw). `normpath` "may change the meaning of a path that contains symbolic links" (S10, raw). `realpath` on Windows resolves 8.3 names, junctions and symlinks (3.8+) and reports the case the OS stores (S10, digest). `pathlib` compares paths by their flavour's case rules: `PureWindowsPath('foo') == PureWindowsPath('FOO')` is true (S11, digest).
- **Rust.** `fs::canonicalize` resolves symlinks and, on Windows, uses `GetFinalPathNameByHandle` and "extended length path syntax" (S12, raw), which "may be incompatible with other applications". `Path` equality compares components; trailing separators do not matter, and `a/c` and `a/b/../c` are distinct (S13, digest). The `dunce` crate converts UNC paths to ordinary ones only when "unambiguously expressed in a simpler way", otherwise returns them unchanged (S14, digest).
- **Node.** `path.win32` and `path.posix` are separate implementations of the same methods (S15, raw), so Windows behaviour is reachable on any OS. `path.basename` is documented as case-sensitive on Windows even though Windows is not (S15, digest). Nothing was found on whether `relative` or `resolve` fold case.
- **Guidance on identity first, string second: none found** in Go, Python, Rust or Node (the pages above). The libraries give both primitives; none recommends an order.

### 1.5 Contract for the path key (proposed name `canon_path_key`; today's awk function is `canon_awk_pkey`) and the Go owner

This is the recommendation; the sources above support each clause as noted.

**Purpose.** Compare two spellings of the same folder when at least one may not exist yet, or when identity cannot be read. A key is for comparing only. It is never a path to hand to another program: even Rust's canonical form "may be incompatible with other applications" (S12, raw), and `dunce` converts only when the result is unambiguous (S14, digest).

**Two steps, in this order.**

1. **Identity, when both paths exist.** Compare file identity: Go `os.SameFile` on two `os.Stat` results, shell `[ a -ef b ]`, never raw text (S9, S10). Resolve symlinks and junctions only here, because a string cannot (S1, S10, S13). Whether `-ef` works on Git Bash for Windows is not verified here.
2. **Key, otherwise.** A pure function of the string. Same output on every OS. No filesystem, no environment, no `runtime.GOOS`.

**The key function** (today's awk contract, plus two additions):

| Step | Rule | Source |
|---|---|---|
| 1 | two or more leading backslashes followed by a non-backslash mark a UNC path (a JSON-escaped one has four); it stays `//host/share` | S1 |
| 2 | every run of backslashes becomes one `/` | S1 |
| 3 | `^[A-Za-z]:(/\|$)` becomes `/` + lower-case drive + the rest: `C:\x`, `C:/x` and `/c/x` give `/c/x` | S1, S2, S4 |
| 4 | **(addition)** collapse runs of `/` after a UNC prefix or a drive, as Windows does | S1 |
| 5 | a trailing slash is dropped; a bare `/` stays | S13 |
| 6 | **(addition)** document that a `.` or `..` segment makes a key non-canonical; do **not** resolve `..` lexically | S10, S13 |

**What the key handles:** the three drive spellings, repeated and mixed separators, a trailing slash, the drive letter's case.

**What the key does not handle, and says so in its contract:** UNC and device paths equal to drive paths (`\\LOCALHOST\c$\x` and `\\?\C:\x` name the same file as `C:\x`, S1), drive-relative `C:x` (needs the process's per-drive directory, S1), 8.3 names (S2), trailing dots and spaces (S1), per-folder case sensitivity (S3), and symlinks or junctions (step 1 only).

**Case.** The key lower-cases the drive letter and nothing else. Windows compares case-insensitively but cannot be assumed to (S1, S2, S3), and lower-casing a whole path would merge `/c/Foo` and `/c/foo` on macOS and Linux, which is wrong (the current Go `pathKey` does exactly that). The key may fail to match two spellings of one Windows folder (a safe miss) and must never merge two real folders. Step 1 handles case when both paths exist.

**The Go owner.** One pure function in `tools/canon-go/internal/common` with the same output as the awk function, plus one `SamePath(a, b)` that tries identity and falls back to the key. It replaces `normPath`, `pathKey` and `samePath`; the `EvalSymlinks` calls that only compare paths go through it.

## 2. Rule and finding registries

### 2.1 What the sources say

- **SARIF 2.1.0** (S17, digest, errata01 text read to about 300,000 of 403,000 characters). A rule is a `reportingDescriptor` in `tool.driver.rules[]`; a result carries `ruleId` and, when the rule is described, `ruleIndex`; "Direct producers SHALL emit either or both of `ruleId` and `rule.id`". "A rule id is more likely to remain stable if it is a symbolic or numeric value, as opposed to a descriptive string" (a NOTE, not a requirement). A `fingerprint` is a "stable value ... to uniquely identify a result over time". Taxonomies are `toolComponent.taxa`, each taxon itself a `reportingDescriptor`; tags "SHOULD NOT" be used to put a result or rule into a classification system.
- **ESLint** (S18, digest): a rule id is the plugin namespace plus the name (`local/my-rule`); `meta.type` has three values; no statement that ids are permanent.
- **Semgrep** (S19, digest): `id` is required and "unique, descriptive"; CWE and OWASP go in optional free-form `metadata`.
- **Ruff** (S20, digest): a code is a letter prefix naming the source linter plus digits; removed rules stay listed with a removal note ("Rule was removed in 0.8.0"); the page does not say codes are permanent or never reused.
- **CWE** (S21, digest): four abstraction levels, Pillar, Class, Base, Variant, from most to least abstract; deprecated entries are "kept for historical traceability"; the glossary does not state that ids are stable.
- **OWASP Top 10 2021** (S22, digest): categories group CWEs, and the team "decided to focus on the root cause whenever possible".
- **SRE** (S23, S24, digest): postmortems are blameless; reviewers ask "Was the root cause sufficiently deep?"; unlearned incidents "may recur ad infinitum"; completed postmortems go to a repository and are aggregated to find common themes; action items need an owner, a tracking number and a verifiable end state. Neither page gives a method for counting recurrence of the same cause.
- **MADR** (S25, digest): a record holds one decision and its rationale; status can read "superseded by ADR-0123". No recurrence concept.
- **NASA** (S26, S41, S42). The software handbook suggests "recidivism rates (e.g., how often similar non-conformances recur)" as a process-improvement indicator and separates "root cause" from "contributing factors" (S26, digest). NASA's lessons-learned system keeps a recurrence field per lesson: "Each LLIS entry is in a format specifically designed for learning. They contain an abstract, description of the driving event, summary of the key lesson learned, recommendations, and the evidence of recurrence" (S42, raw, text lines 175-181 of the PDF); and each lesson "includes a summary of the original driving event and recommendations, which feed into NASA's continual improvement through training, best practices, policies, and procedures" (S41, raw). So LLIS records *evidence that a cause recurred* inside each lesson; none of the three sources gives a method for counting recurrence across lessons. The LLIS database itself could not be read (its pages are client-rendered and return no text), so the field list rests on S42 and S41; a search summary says other NASA documents list a fuller set of fields (UNVERIFIED).

### 2.2 Recommendations

- **Keep canon's own scheme.** A finding class has a slug and a concern; a promoted rule has a permanent `P-nnn` id and a class. SARIF's advice that a numeric or symbolic id is more stable than a descriptive one (S17) agrees with using `P-nnn` as the identity and the slug as a label.
- **SARIF is an export format, not storage.** If an export is ever wanted: `ruleId` = the `P-nnn` id, the slug in `name`, the concern as a taxon in a canon taxonomy (S17). Building that now has no reader; the ticket should not.
- **Never reuse an id.** Ruff and CWE both keep retired entries listed (S20, S21). That is observed practice, not a stated rule in either source, so canon should state it as its own rule.
- **Name a class by the mistake, not the OS.** This matches the user's 2026-11-12 decision and the practice of naming categories by root cause where possible (S22) and asking whether a cause is "sufficiently deep" (S23). It extends `P-027 path-alias-compare` rather than adding a Windows-only class.
- **Recurrence counting is canon's own design.** No source read gives a counting method or a recurrence key (S23-S26, S42). `canon-go finding-classes` already counts later tickets that name the class or cite the id; NASA's per-lesson "evidence of recurrence" (S42) is the closest practice read, and the handbook's "recidivism rate" (S26) names the metric, not a method. Keep canon's counter, and back-fill the nine past path tickets under the one id so the count is true from the start.

## 3. Small data tables that bash, awk and Go all read

The constraint: bash, awk and Go on Windows (Git Bash), no new dependency. `go.mod` has no TOML library (0 matches).

### 3.1 Formats

| Format | Escaping and structure | What a hand parser (awk) must cope with | Fit |
|---|---|---|---|
| **TSV** | "Fields that contain tabs are not allowable"; "the number of tabs per line must be constant"; each record is one line (S27, raw, IANA lines 24-28 and 46). No escape mechanism and no newline-in-field rule is defined. | split on tab | best for short single-line columns |
| **CSV** (RFC 4180) | fields with line breaks, quotes or commas must be quoted; a quote inside is doubled; "each line should contain the same number of fields" (S28, raw, lines 100 and 136) | quote handling in awk is a bug source | worse than TSV for text with commas |
| **JSON Lines** | one JSON value per line; a blank line is not valid; no byte-order mark (S29, digest) | needs a JSON reader in awk | right for the event log, wrong for a table bash reads |
| **TOML 1.0** | four string forms with different escapes, strings and arrays that span lines, `#` comments except inside strings, array of tables `[[x]]`, duplicate keys are an error (S30, digest) | a subset dialect, or a library | a dependency in Go; about five times the lines (the ticket's estimate: 13 rows become about 65) |
| **Markdown table** | a pipe in a cell must be escaped; rows may have more or fewer cells than the header (S31, digest) | escaping and ragged rows | readable, loose |

### 3.2 Validation, which is the reusable idea

Frictionless Table Schema expresses `required`, `unique`, `enum` and `pattern` constraints and a `primaryKey`, but column count is only a SHOULD (S32, digest). The W3C tabular metadata spec adds a primary-key uniqueness check (S34, digest, partial). Neither is a format canon could use; the constraints are what to copy. A TSV needs a small bash test that checks, per line:

1. a **constant number of tabs** (IANA's own condition, S27), so a tab-to-spaces edit fails loudly;
2. **no tab or newline inside a field** (S27);
3. the **key column is unique** and matches `^[a-z0-9-]+$` (S32 `unique`, `pattern`);
4. **enum columns hold known values** (S32 `enum`), such as the concern from a fixed list;
5. **no leading or trailing whitespace** in a field (`pattern`);
6. rows are **sorted by key**, so a diff shows only the real change (canon's own rule).

### 3.3 Recommendation

Keep a TSV for the finding-class table and add the validation test above. **Do not convert the promoted rules to a TSV now.** The promoted lines are prose spread over about ten files (standards, skills, tools, docs and the critique log), tagged `(t-xxxx; class: slug; id: P-nnn)`, and a regular expression already counts all 86 ids. A rule needs a list of tickets and a rationale, which do not fit "no tab or newline in a field" without inventing a separator. Reconsider when a reader other than the promoted-rules report needs the rules as data; then JSON Lines for machines or a TSV with a `;`-joined ticket column are the options to compare.

## 4. Testing a cross-OS rule on one OS

### 4.1 What mature projects do

- **Go's `path/filepath` tests choose Windows cases by `runtime.GOOS`.** `wincleantests` is defined at `path_test.go:84` and appended only `if runtime.GOOS == "windows"` (lines 151-157), and the Windows split and volume-name tables work the same way: `winsplittests` at line 409 is appended under `runtime.GOOS` at line 425, and `TestVolumeName` returns at once unless the OS is Windows (lines 1655-1658) (S35, raw). Go tests Windows rules on Windows.
- **Python's `ntpath` tests run on any OS.** `test_ntpath.py` does `import ntpath` (line 3) and a comment says "Most tests can complete without the nt module" (line 22); only tests that need the real `nt` module or junction creation are skipped (S36, raw, lines 1238, 1517, 1547, 1563).
- **Node's `path.win32` tests assert unconditionally.** `test-path-normalize.js` lines 6-12 call `path.win32.normalize(...)` and compare to expected strings with no platform check (S37, raw).
- **git's tests set prerequisites from `uname -s`.** `t/test-lib.sh` line 1708 runs `uname_s=$(uname -s)` and line 1731 sets the `MINGW` prerequisite; Windows-only tests run only on a real MSYS system (S38, raw). Whether any git test stubs `uname` to fake Windows is not verified.
- **Windows in CI.** GitHub's workflow syntax says "when specifying a bash shell on Windows, the bash shell included with Git for Windows is used" (S40, digest). The `windows-latest` runner label and its default shell were not verified from the pages read.

### 4.2 Recommendation for the planned path-forms test

1. **Make the key pure so the corpus runs everywhere**, like `ntpath` and `path.win32`, not like Go's `filepath` (S35, S36, S37).
2. **One corpus file, read by both the bash test and the Go test**: a TSV of input, expected key and a note, covering every spelling in section 1.5, including the ones that must not match. Each line names the failure it prevents.
3. **Test step 1 (identity) with real directories and symlinks** where the OS has them, and with a stub of `git worktree list --porcelain` that prints `C:/...` and `/c/...` worktrees (the guard t-134b's evaluator asked for).
4. **Keep a small real-Windows check** (the Windows VM, or a Windows runner) only for what a string function cannot reproduce: Git Bash converting a `/c/x` argument for a native program, and `-ef` behaviour. This is the behaviour section 1.3 could only call observed.
5. **A guard counts only if it fails when reverted.** Delete the key's drive step in a scratch copy and confirm the corpus test fails.

## 5. What t-141a should do

**Decisions this research supports**

1. Write the key contract of section 1.5 once, in the awk function's comment and here, and add the two additions (collapse slashes; `..` is never resolved).
2. Add one Go owner with the same output; replace `normPath`, `pathKey` and `samePath`; stop lower-casing whole paths.
3. Add the identity step as the only place that resolves symlinks for comparison.
4. Extend `P-027 path-alias-compare` to the OS spellings (the 2026-11-12 decision), back-fill the nine tickets, and add one sentence to the Platforms rule: name a finding class by the mistake, never by the OS.
5. Build the shared corpus test of section 4.2 and its revert-proof.
6. Keep the finding-class table a TSV with the validation test of section 3.2; leave the promoted rules as they are.

**Questions the research leaves open**

- **Case in the string fallback.** The shipped contract may fail to match `C:\Users\X` and `c:/users/x`. Is that miss acceptable, or should a Windows-origin key fold case? The sources show Windows is case-insensitive by default but not always (S1-S3).
- **Does `-ef` work on Git Bash for Windows?** Not verified here.
- **`/c/x` conversion.** Documented only in general terms; the exact behaviour is canon's own observation (t-134b).
- **Go `SameFile` on Windows.** The pages read do not document how a Windows file is identified.
- **A shared corpus under `tests/`.** Where it lives and its name are t-141a's call.

## Sources

Every line was read on 2026-11-13. "raw" means the author checked the quoted wording against the raw page or file; "digest" means a research agent read a model-written summary of the page.

| # | Source | Read | How |
|---|---|---|---|
| S1 | https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats | read 2026-11-13 | raw (4 quotes checked) + agent read in full |
| S2 | https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file | read 2026-11-13 | raw (4 quotes checked) |
| S3 | https://learn.microsoft.com/en-us/windows/wsl/case-sensitivity | read 2026-11-13 | digest |
| S4 | https://www.msys2.org/docs/filesystem-paths/ | read 2026-11-13 | raw (quote and variable names checked; `MSYS_NO_PATHCONV` absent) |
| S5 | https://raw.githubusercontent.com/git-for-windows/msys2-runtime/main/winsup/cygwin/msys2_path_conv.cc | read 2026-11-13 | raw (lines 347-349); exceptions list digest |
| S6 | https://raw.githubusercontent.com/git-for-windows/build-extra/main/ReleaseNotes.md | read 2026-11-13 | digest, first 100,000 of about 260,000 characters |
| S7 | https://www.cygwin.com/cygwin-ug-net/cygpath.html | read 2026-11-13 | digest |
| S8 | https://pkg.go.dev/path/filepath | read 2026-11-13 | digest; "purely lexical" raw in `src/path/filepath/path.go` lines 29 and 70 |
| S9 | https://raw.githubusercontent.com/golang/go/master/src/os/types.go (and https://pkg.go.dev/os) | read 2026-11-13 | raw (lines 64-66); the pkg.go.dev page digest |
| S10 | https://docs.python.org/3/library/os.path.html | read 2026-11-13 | raw (4 quotes checked) |
| S11 | https://docs.python.org/3/library/pathlib.html | read 2026-11-13 | digest |
| S12 | https://doc.rust-lang.org/std/fs/fn.canonicalize.html | read 2026-11-13 | raw (2 phrases checked) |
| S13 | https://doc.rust-lang.org/std/path/struct.Path.html and https://doc.rust-lang.org/std/path/index.html | read 2026-11-13 | digest |
| S14 | https://docs.rs/dunce/latest/dunce/ | read 2026-11-13 | digest |
| S15 | https://nodejs.org/api/path.html | read 2026-11-13 | raw (2 phrases checked); case notes digest |
| S16 | https://nodejs.org/api/fs.html | read 2026-11-13 | digest, characters 200,000-300,000 only |
| S17 | https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/sarif-v2.1.0-errata01-os-complete.html (and the root spec URL) | read 2026-11-13 | digest, to about 300,000 of 403,053 characters |
| S18 | https://eslint.org/docs/latest/extend/custom-rules | read 2026-11-13 | digest |
| S19 | https://docs.semgrep.dev/writing-rules/rule-syntax | read 2026-11-13 | digest |
| S20 | https://docs.astral.sh/ruff/rules/ | read 2026-11-13 | digest, first 100,000 of about 213,000 characters |
| S21 | https://cwe.mitre.org/documents/glossary/ | read 2026-11-13 | digest |
| S22 | https://top10.owasp.org/2021/A00_2021_Introduction | read 2026-11-13 | digest |
| S23 | https://sre.google/sre-book/postmortem-culture/ | read 2026-11-13 | digest |
| S24 | https://sre.google/workbook/postmortem-culture/ | read 2026-11-13 | digest |
| S25 | https://adr.github.io/madr/ | read 2026-11-13 | digest |
| S26 | https://swehb.nasa.gov/x/cgIfBg | read 2026-11-13 | digest |
| S27 | https://www.iana.org/assignments/media-types/text/tab-separated-values | read 2026-11-13 | raw (lines 24-28, 46) |
| S28 | https://www.rfc-editor.org/rfc/rfc4180 | read 2026-11-13 | raw (text lines 100, 136) |
| S29 | https://jsonlines.org/ | read 2026-11-13 | digest |
| S30 | https://toml.io/en/v1.0.0 | read 2026-11-13 | digest |
| S31 | https://github.github.com/gfm/ | read 2026-11-13 | digest, first 100,000 of 217,893 characters |
| S32 | https://specs.frictionlessdata.io/table-schema/ | read 2026-11-13 | digest |
| S33 | https://specs.frictionlessdata.io/csv-dialect/ | read 2026-11-13 | digest |
| S34 | https://www.w3.org/TR/tabular-metadata/ | read 2026-11-13 | digest, first 100,000 of 150,372 characters |
| S35 | https://raw.githubusercontent.com/golang/go/master/src/path/filepath/path_test.go | read 2026-11-13 | raw (lines 77, 84, 151-157, 409, 425, 1655-1658) |
| S36 | https://raw.githubusercontent.com/python/cpython/main/Lib/test/test_ntpath.py | read 2026-11-13 | raw (lines 3, 22, 1238, 1517, 1547, 1563) |
| S37 | https://raw.githubusercontent.com/nodejs/node/main/test/parallel/test-path-normalize.js | read 2026-11-13 | raw (lines 6-12) |
| S38 | https://raw.githubusercontent.com/git/git/master/t/test-lib.sh | read 2026-11-13 | raw (lines 1708, 1709, 1731) |
| S39 | https://raw.githubusercontent.com/git/git/master/t/test-lib-functions.sh | read 2026-11-13 | digest |
| S40 | https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax | read 2026-11-13 | digest, first 100,000 of 236,283 characters |
| S41 | https://www.nasa.gov/nasa-lessons-learned/ | read 2026-11-13 | raw (the "original driving event and recommendations" sentence) |
| S42 | https://ntrs.nasa.gov/api/citations/20120017921/downloads/20120017921.pdf ("Lessons Learned for Improving Spacecraft Ground Operations", NASA technical paper, 2012) | read 2026-11-13 | raw (PDF text lines 175-181) |

## Not verified

- That Git for Windows converts `/c/Users/x` to `C:/Users/x` for a native program: observed in canon (t-134b), not shown by any page read.
- Whether `MSYS2_ARG_CONV_EXCL` takes effect in Git for Windows' runtime (documented by MSYS2, absent from the runtime excerpt seen); the cases where the opt-outs do not work.
- The Git for Windows FAQ and the remaining 160,000 characters of its release notes.
- Microsoft's pages on hard links, junctions and reparse points, `GetFullPathName` and `GetLongPathName`.
- How `os.SameFile` identifies a file on Windows; Node `path.win32.relative` and `resolve` case handling; Rust's `Prefix` documentation; whether any git test stubs `uname`.
- SARIF: the text of `reportingDescriptor.id` (3.49.3), `isComprehensive`, the `reportingDescriptorRelationship` properties, and `result.taxa` (the last 100,000 characters of the errata text were not read).
- Whether ESLint, Ruff and CWE ids are permanent; Semgrep's id format rules; the OWASP 2025 edition.
- The LLIS database entries themselves (llis.nasa.gov pages are client-rendered and returned no text) and the claim that cause codes should refer only to causes (a search snippet). The LLIS field list rests on S42 and S41; a search summary says other NASA documents list more fields.
- Table Schema whitespace handling; W3C `trim`, `enum`, `pattern` and `minLength` beyond the first 100,000 characters.
- GitHub's `windows-latest` label and default Windows shell.
- That `[ a -ef b ]` compares file identity on Git Bash for Windows.
