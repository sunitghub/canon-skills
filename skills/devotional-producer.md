---
name: devotional-producer
description: Production auditor and planner for devotee anubhav (spiritual experience testimonial) long-form videos. Audits scripts, images, and renders against competitor-derived benchmarks. Works for any Hindustani folk-devotional video following the Scene-N-M.png + scene-script format.
category: media
tags: [video-production, devotional, hindi, audit, planning, anubhav]
---

# Devotional Producer

Invoke when the user wants to plan, audit, or check readiness for a devotee anubhav video — a real or claimed-real devotee experience with mantra, stotra, or sadhana practice.

## When to Invoke

**Master trigger** — runs the full content check in one pass:
- "check [script/video name] for content generation"
- "check @<filename> for content"
- "content check" / "check for content"

**Targeted triggers:**
- "audit scene N" / "check scene N" / "how many images do I need?"
- "production status" / "what's next" / "am I ready to render?"
- "check my script" / "does my narration fit?"
- "analyze my render" / "check my video" / "how does this compare?"
- "audit images" / "what images am I missing?"
- "critique the script" / "critique scene N" / "update the critique"
- "is the pacing right" / "check my narration timing"

---

## Mode 0 — Content Check (Master Mode)

**Trigger:** "check [script name] for content generation" / "content check" / "check @<filename> for content"

Runs the full sequence in one pass. No further input needed from the user.

### Sequence

**Step 1 — Run pacing + beat audit:**
```bash
render-scene --critic
```
Read both output tables before proceeding. Note each scene's Hold and Status.

**Step 2 — For every scene, in order:**

Do all sub-steps for one scene before moving to the next.

**2a. Read the scene script:**
- Read the Hindi narration and any English translation or suggested text in the scene block.
- Identify which beat(s) from the 8-beat spine this scene covers.
- List the key visual moments in the script that must have image coverage (e.g. "sadhak walking to cave", "guru listening", "pranam"). These are the content anchors.

**2b. Read and analyze each image prompt:**
- Read every numbered entry in `#### Images` for this scene.
- For each entry, note in one phrase what it depicts (e.g. "1a — courtroom wide shot", "3b — guru listening").
- Cross-check against the content anchors from 2a:
  - **Gap**: a key script moment has no image covering it → must add a prompt
  - **Redundant**: three or more consecutive images with the same framing and no new beat → flag (do not delete, just note)
  - **Off-beat**: image depicts something not in the script for this scene → flag
- Count total prompted images and compare to `ceil(narration_seconds / 7)` target.

**2c. Write or update the `### Critique` section** (Mode 4 rules), now informed by 2a + 2b:
- `NOT CRITIQUED` → write a new critique from scratch
- Existing critique + gap/redundancy found in 2b → update to address it
- Existing critique + pacing `❌` or `⚠` → update to address the pacing issue
- Existing critique + pacing `✓` + no content gaps → leave critique unchanged

**2d. Add missing image prompts** for any content gaps found in 2b, and to reach the `ceil(narration_seconds / 7)` count if still short:
- Insert new entries at the correct narrative position (not always at the end — place them where the gap is).
- Use the same prompt style as existing entries in that scene (art style tag, ref upload note format).
- Do not duplicate existing prompts.

**2e. Note any scenes that are entirely unwritten** (no Hindi text, no images). Do not write the scene — flag it for the user.

**Step 3 — Update `## Critique State` ToDo:**

After completing Step 2 for all scenes, update the `## Critique State` section at the top of the script file:
- For each scene in **ToDo**: mark resolved items ✓ or remove them; add newly discovered action items.
- If all ToDo items for a scene are resolved, move it to **Fixed**.
- Keep each bullet tight — one line per item.

**Step 4 — Print a summary:**

```
## Content Check — [Script Name]

### Pacing
Scene 1: 6.8s ✓ — good
Scene 2: 9.8s ⚠ — +2 prompts added (images 11, 12)
...

### Content Analysis
Scene 1: covers beats 1–3 | 13 images | gaps filled: walking (3a), guru listening (3b)
Scene 2: covers beat 4 | 12 images | no gaps
...

### Critiques
Scene 1: updated — pacing resolved, two pending items remain
Scene 3: written — beat 4 Guru Rules, emotional hook missing
...

### Image Prompts Added
Scene 2: +2 (images 11, 12) — clove insert, completed room at dawn
Scene 4: complete — no gaps found
...

### Not Yet Written
Scene 6, 7, 8 — write these next (vision, resolution, teaching close)

### Next Action
[One sentence: the single most important thing to do next]
```

---

## Content Format — Devotee Anubhav

This format is distinct from folk fiction. The narrative is positioned as testimony, not entertainment.

**Story spine (every episode):**
1. **Hook** — tease the outcome upfront ("This sadhak's court case was turning against him until...")
2. **Devotee + crisis** — who is this person, what impossible situation did they face
3. **Guru / practice** — what mantra, stotra, or sadhana was prescribed
4. **Ritual setup** — the specific rules and physical preparation
5. **Active sadhana** — the nightly or daily practice in detail
6. **The experience** — vision, dream, sign, or inexplicable event (this is the hero moment)
7. **Resolution** — how the crisis resolved through divine grace
8. **Teaching close** — what practice viewers can use, with the mantra or stotra named

**Character rules:**
- Deity reference image is **locked** across the entire channel (one image per deity)
- Devotee protagonist is **new per episode** — no face-lock needed, costume carries identity
- Guru (if present) is described by costume and physical markers, not face

---

## Process

### Mode 1 — Script Audit (Pacing)

**Trigger:** "audit script" / "check scene N" / "how many images do I need?" / "is the pacing right?"

**Step 1 — Run the terminal check (one command, works from any project directory):**
```bash
render-scene --critic
```

This prints two tables:
- **Beat/level table** — critique status per scene (High / Medium / Low / NOT CRITIQUED)
- **Pacing table** — words, estimated narration, prompted images, generated images, planned hold, status

**Step 2 — Read the pacing table columns:**

| Column | Meaning |
|---|---|
| Words | Hindi/Hinglish word count from the scene text (auto-counted) |
| Narr | Estimated narration at 85 WPM |
| Prompted | Total image entries in `#### Images` section |
| Generated | PNG files on disk (`Scene-N-*.png`) |
| Hold | Narr ÷ Prompted — planned hold per image |
| Status | ❌ <5s too fast · ⚠ 5–6s below target · ✓ 6–8s good · ⚠ 8–10s slightly slow · ❌ >10s too slow |

**Step 3 — Report the findings.** Use the table output directly. For each flagged scene:
- Hold too fast (<5s): expand narration OR reduce image count
- Hold slightly slow (8–10s): add 1–2 images OR trim narration
- Hold too slow (>10s): add images if scene has more to show, otherwise tighten narration

**Benchmarks:**
- Hindi devotional narration: **85 WPM** (80–90 range)
- Target hold: **6–8s per image**
- Images per minute of narration: **8–10**
- 10-minute video: **75–100 unique images**
- 20-minute video: **150–200 unique images** (with ~20% reuse from repeated location/altar shots)

---

### Mode 2 — Image Audit

**Trigger:** "audit images" / "check images for scene N" / "what's missing?"

**Steps:**

1. Find all scene images in the project folder:
```bash
find . -name "Scene-*-*.png" | sort
```

2. Group by scene number and count:
```bash
for scene in 1 2 3 4 5 6 7 8; do
  count=$(find . -name "Scene-${scene}-*.png" 2>/dev/null | wc -l | xargs)
  echo "Scene $scene: $count images"
done
```

3. Check image dimensions are 16:9 (flag any that aren't):
```bash
for f in Scene-1-*.png; do
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0 "$f" 2>/dev/null \
    | awk -F, '{ratio=$1/$2; if(ratio<1.7 || ratio>1.85) print FILENAME" NOT 16:9: "$1"x"$2}' \
    FILENAME="$f"
done
```

4. Cross-reference against script audit recommendations and flag gaps.

5. List untracked/new images that exist on disk but may not be committed:
```bash
git status --short | grep "Scene-"
```

---

### Mode 3 — Render Audit

**Trigger:** "analyze my render" / "check my video" / "how does this compare?"

**Steps:**

1. Locate the MP4. Look in `Renders/` subfolder or ask the user for the path.

2. Get technical specs:
```bash
ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate \
  -show_entries format=duration,bit_rate -of compact video.mp4
```

3. Measure audio loudness:
```bash
ffmpeg -i video.mp4 -filter_complex volumedetect -f null - 2>&1 \
  | grep -E "mean_volume|max_volume"
```

4. Sample image-diff to assess motion level:
```bash
python3 - <<'EOF'
import subprocess
video = "video.mp4"
result = subprocess.run(
    ["ffmpeg", "-i", video, "-vf", "fps=1,scale=160:90",
     "-f", "rawvideo", "-pix_fmt", "gray", "-"],
    capture_output=True, timeout=120
)
data = result.stdout
fs = 160 * 90
n = len(data) // fs
diffs = [sum(abs(int(c)-int(p)) for c,p in zip(data[i*fs:(i+1)*fs], data[(i-1)*fs:i*fs])) / fs
         for i in range(1, n)]
diffs.sort()
print(f"Frames: {n}, Median diff: {diffs[n//2]:.1f}, Near-static (<5): {sum(1 for d in diffs if d<5)/len(diffs)*100:.0f}%")
EOF
```

5. Compare against benchmarks and report.

**Competitor benchmarks for comparison:**

| Metric | Target (devotional) | Charava-Bhootni | Kumar-Chudail | Jinn-Masoom |
|---|---|---|---|---|
| Card hold (median) | 6–8s | 4.2s | 5–8s | 6.0s |
| Audio mean volume | -20 to -21 dB | — | -20.9 dB | — |
| Audio max volume | -4 to -6 dB | — | -4.8 dB | — |
| Near-static ratio | >60% | 74.6% | ~0.1%* | 27.1% |
| Format | 1920×1080 or 1280×720 | 640×360 | 638×360 | 640×360 |

*Kumar-Chudail's low near-static is explained by fade-to-black transitions inflating diff values.

**View velocity context (views/month at time of analysis, 2026-05):**
- Comic illustration, zero I2V: **263K/month** (Kumar-Aur-Chudail)
- Painterly folk illustration, 0–2 I2V: **157K/month** (Charava-Bhootni)
- Photoreal cinematic, selective I2V: **73K/month** (Jinn-Masoom)

---

### Mode 4 — Script Critique (Write / Update)

**Trigger:** "critique the script" / "critique scene N" / "update the critique" / "write the critique"

**Step 1 — Run terminal check:**
```bash
render-scene --critic
```

**Step 2 — Identify what needs work:**
- `NOT CRITIQUED` → write a new `### Critique` section
- `High` → read existing critique; check if issues are still present; update if needed
- Pacing `❌` or `⚠` → the critique must address the pacing problem and suggest a fix

**Step 3 — For each scene needing work:**
1. Re-read the scene's Hindi script text and its `#### Images` section
2. Map it to the 8-beat anubhav spine (numbered list below)
3. Identify issues: missing beats, weak narration, pacing problems, emotional gaps
4. Write or replace the `### Critique` block using the standard format

**Critique format** (write exactly this, under each `## Scene-N` block, before the `---` separator):

```markdown
### Critique

**Story Beat:** <beat name> (Beat N)
**Level:** High | Medium | Low

- **<Issue label>**: <what is wrong and why it matters for viewer retention>
- **Fix**: <concrete rewrite suggestion — give the actual Hindi line when possible>

#### English (Suggested)

<Rewritten English narration that resolves the critique issues. Write it as the final narration would sound — a scene-card by scene-card read, not a description of what to write. This is the Hindi adaptation reference.>
```

**Level guide:**
- **High** — a structural beat is missing or the scene will lose viewers
- **Medium** — the scene works but has a meaningful gap (stakes, emotion, timing)
- **Low** — technically correct; minor polish only

**8-beat anubhav spine:**
1. Hook — tease the outcome upfront
2. Devotee + crisis — who, what impossible situation
3. Guru / practice — what was prescribed and why
4. Ritual setup — physical preparation, rules, materials
5. Active sadhana — the nightly/daily practice in detail
6. The experience — vision, dream, sign, or inexplicable event
7. Resolution — how the crisis resolved through divine grace
8. Teaching close — what practice viewers can use, mantra named

**Step 4 — After writing all critiques, re-run:**
```bash
render-scene --critic
```
Confirm no scenes show `NOT CRITIQUED`. Any pacing `❌` must be addressed in the critique.

---

### Mode 5 — Production Status

**Trigger:** "production status" / "what's next" / "am I ready to render?"

**Steps:**

1. Run image audit (Mode 2) to get current image counts.
2. Run script audit (Mode 1) to get recommended counts.
3. Check for narration files:
```bash
find . -name "*.mp3" -o -name "*.wav" -o -name "*.m4a" | sort
```
4. Check for rendered outputs:
```bash
find . -path "*/Renders/*.mp4" | sort
```
5. Report status as a punch list:

```
## Production Status — [Video Name]

Images:
  Scene 1: 8/8 ✓
  Scene 2: 8/8 ✓
  Scene 3: 4/6 — MISSING 2 images
  Scene 4: 0/6 — NOT STARTED
  ...

Narration:
  scene-1-narration.mp3: EXISTS (42s)
  Remaining: NOT RECORDED

Renders:
  Scene-1-test-preview.mp4: EXISTS
  Full render: NOT STARTED

Next action: Generate 2 missing images for Scene 3, then script Scene 4.
```

---

## Production Knowledge Base

### I2V Budget Rules
- **0 I2V clips**: viable for pure narration-led episodes where narration carries all meaning
- **1–2 I2V clips**: use for the supernatural experience / divine vision / miracle moment only
- **Cost**: ~$0.90/5s clip via Seedance Replicate
- **Never**: use I2V for setup, ritual, or resolution scenes — still cards work fine there

### Visual Style — Devotional Anubhav
- Art style: **painterly Hindustani folk-story illustration** (not comic book, not photoreal)
- Palette: warm amber/golden for interior ritual scenes, cool night blue for outdoor/supernatural
- One dominant sacred focal point per card (deity portrait, yantra, diya flame, sadhak's hands)
- Motion: **Ken Burns slow push-in** (zoom 1.00→1.04) is the default for all still cards
- Transitions: hard cuts within a scene, **fade-to-black 1.2s** between scene groups

### Deity Reference Rule
One locked reference image per deity, used across ALL episodes and ALL scenes featuring that deity. This is the channel's visual identity anchor. Example: `Maa-Baglamukhi.png` is uploaded to every GPT-4o prompt that includes Maa.

### Audio Assembly Target
- Narration track: 0 dB (primary)
- Music bed: -18 to -20 dB relative to narration
- Resulting mix target: -20 to -21 dB mean, -4 to -6 dB max
- Format: AAC stereo 192 kbps, 44100 Hz

### render-scene CLI (symlinked to ~/bin — call from anywhere)
```bash
# Pacing + critique audit — no render, analysis only
render-scene --critic

# Preview render for a single scene (fast, 720p)
render-scene --scene 1 --preview

# Timed to narration (auto-calculates hold per image)
render-scene --scene 1 --narration scene-1-narration.mp3

# Full quality 1080p
render-scene --scene 1
```

**`render-scene --critic` outputs:**
1. Beat/level table — story beat per scene, critique level (High / Medium / Low / NOT CRITIQUED)
2. Pacing table — words, narration estimate, prompted images, generated images, planned hold, status vs. 6–8s target
3. Summary line — total words, total narration duration, total images

To write or update the `### Critique` sections in the script MD after running `--critic`, invoke Mode 4 of this skill.

### Scene Image Count Quick Reference
| Scene Type | Typical Word Count | At 85 WPM | Recommended Images |
|---|---|---|---|
| Hook / Intro | 60–80 | 42–56s | 6–8 |
| Guru instruction | 80–100 | 56–70s | 8–10 |
| Ritual setup | 80–100 | 56–70s | 8–10 |
| Active ritual | 60–80 | 42–56s | 6–8 |
| Experience / vision | 80–120 | 56–84s | 8–12 + 1–2 I2V |
| Resolution | 50–70 | 35–49s | 5–7 |
| Teaching close | 50–70 | 35–49s | 5–7 |

---

## Getting Started

**Step 1 — Register in your project:**
```bash
/Users/sunitjoshi/Developer/canon/skills.sh add devotional-producer /path/to/project
```

**Step 2 — Verify registration:**
```bash
/Users/sunitjoshi/Developer/canon/skills.sh status /path/to/project
```

**Step 3 — Use it (any agent):**
- Claude Code: "Audit scene 3" / "Production status" / "Check my script"
- Codex: Same — reads from AGENTS.md
- Pi: Same — reads from AGENTS.md via extension

No slash command needed. Describe what you want to check in natural language.
