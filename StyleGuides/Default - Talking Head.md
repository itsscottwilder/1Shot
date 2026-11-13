---
type: editing-style-guide
name: Default - Talking Head
app: 1Shot
format_version: 1
guide_version: 3
applies_to: one-take talking-head videos (car, desk, walk-and-talk) for YouTube
input: 1Shot edit transcript (.json)
output: cut list (.json)
---

# Style guide: Default — Talking Head

## Purpose

Make a single-take talking-head recording feel tight and confident without sounding chopped.
Remove dead air, false starts and abandoned takes. Keep the speaker's natural rhythm and any
pause that is doing a job (emphasis, a beat before a punchline, a rhetorical list).

## Settings

These numbers drive the rules below. Change them here, not in the rules.

```yaml
keep_pause: 0.35          # seconds of pause to leave where a pause is tightened
tighten_pauses_over: 0.6  # pauses longer than this get tightened down to keep_pause
dramatic_beat: 2.0        # seconds to keep for an intentional beat (see Judgment)
section_beat: 2.0         # seconds to keep where one section ends and the next begins
mid_sentence_over: 2.0    # a pause inside a sentence is only tightened if it is longer than this
word_padding: 0.05        # never cut closer than this to the edge of a kept word
min_cut: 1.0              # a cut must remove at least this much, unless it removes a clear mistake (Rule 8)
merge_gap: 0.25           # two cuts closer together than this become one cut
max_cuts_per_minute: 20   # if you exceed this, keep more pauses; the edit will feel choppy
max_blip: 1.0             # a non-speech sound shorter than this between two silences joins them into one pause
```

## Rules

### Must

1. **MUST** keep every cut inside `trimStart`–`trimEnd`.
2. **MUST** keep `word_padding` seconds of space on both sides of every kept word. Never cut through a word.
3. **MUST** remove false starts: when the speaker says the start of a phrase, stops, and says it again,
   cut from the end of the last good word before the false start to just before the restart.
   Keep the **later** attempt.
4. **MUST** remove abandoned takes: when the speaker says a sentence, pauses, and then says a reworded
   version of the same sentence, keep only the final version. Cut from the end of the last kept word
   before the first version to just before the final version starts.
5. **MUST** tighten every pause longer than `tighten_pauses_over` down to `keep_pause`, unless Judgment
   says it is an intentional beat. Cut from the middle of the pause so the remaining silence is split
   around the cut.
6. **MUST** use the measured `silences[]` for exact pause boundaries. When a word's timing is much longer
   than the word (for example a 3-second "to"), treat the overlapping silence as the pause.
7. **MUST** treat back-to-back silences as **one** pause when the sound between them is shorter than
   `max_blip` and no word **ends** inside it (it's a breath, click or background noise, not speech).
   Tighten the merged pause with a single cut — never leave slivers of silence between several cuts.
8. **MUST NOT** make any cut that removes less than `min_cut` seconds, **unless it removes a clear
   mistake** (a false start, a retake, a stumble or a misspoken word — reasons `false-start` or `retake`).
   Pauses and dead air that would come out shorter than `min_cut` are left alone. In practice a pause
   is only tightened when it is longer than `keep_pause + min_cut` (1.35 s with the defaults).
9. **MUST NOT** tighten a pause **inside a sentence** (the word before it doesn't end in `.` `?` or `!` —
   a trailing `...` counts as inside) unless it is longer than `mid_sentence_over`. Short mid-thought
   pauses are the speaker's delivery, not dead air.
10. **MUST NOT** tighten a pause right after a **short sentence** (5 words or fewer, e.g. "Now, I know.",
    "YouTube can be a tough slog.") unless it is longer than `mid_sentence_over`. A short line is a setup;
    the pause lets it land.

### Never

1. **NEVER** cut anything — words **or pauses** — inside the call to action, the subscribe request, or the
   sign-off ("thanks", "see you next time"). They stay exactly as recorded.
2. **NEVER** remove a whole sentence just because it seems unnecessary. Only remove repeats, false
   starts, abandoned takes and dead air. (Content cuts are the person's decision.)
3. **NEVER** change the order of anything.
4. **NEVER** leave two cuts closer together than `merge_gap` — merge them into one.

## Judgment

- **Intentional beats:** keep `dramatic_beat` (not `keep_pause`) for a pause that sets up a point —
  e.g. between items of a deliberate list ("the way you look. … The way you sound. … And the way you're
  surrounded?"), before a punchline, or after a question the speaker wants to land. Leave most of the
  beat **before** the cut (right after the line) and only a short breath (~0.3 s) after it.
- **Section changes:** where one idea finishes and a new one starts (often a new sentence starting with
  "So…", "Now…", "And the minute…"), keep `section_beat` — the viewer needs a moment to reset.
- **Retakes that restart with a stall:** if the kept version starts with a word followed by a long gap
  ("And … ask yourself"), cut through that gap too, so the kept take starts cleanly.
- **Tangents:** an aside about the recording itself (the camera, the phone mount, driving safety) may be
  something the person wants to drop. **Don't cut it** — list it in `review` with its start and end so
  they can decide. (Content cuts are the person's decision; see Never 2.)
- **Driving / walking clips:** long pauses while the speaker checks traffic are dead air — tighten them.
- **Trailing thoughts:** a phrase ending in "…" followed by the same words again is a false start (Rule 3).
- **Fillers** ("um", "uh"): the transcriber often omits them, so they may appear only as a short sound
  inside a pause. Don't try to cut fillers you can't see in `words[]`.
- When unsure whether something is a mistake, **keep it** and mention it in `review` (see Output).
  A short cut is only allowed for a *clear* mistake — if you're not sure, it isn't one.

## Output

Reply with one JSON object, nothing else:

```json
{
  "styleGuide": "Default - Talking Head",
  "clip": "IMG_0022.mov",
  "cuts": [
    { "start": 142.80, "end": 149.58, "reason": "false-start", "note": "first 'without…' then restart" },
    { "start": 178.90, "end": 184.40, "reason": "pause",       "note": "6.1 s → 0.35 s" }
  ],
  "review": [
    { "at": 220.80, "note": "Possible retake of 'And ask yourself…' — confirm which version to keep." }
  ],
  "summary": { "cutCount": 2, "secondsRemoved": 12.3, "newLength": 252.6 }
}
```

- `start` / `end`: seconds on the original clip, rounded to 2 decimals, `start < end`.
- `reason`: one of `pause`, `false-start`, `retake`, `dead-air`, `other`.
- `note`: a few words a person can scan.
- `review`: things you weren't sure enough to cut. Empty list if none.
- `summary.newLength`: `(trimEnd − trimStart) − secondsRemoved`.
- Cuts sorted by `start`, no overlaps.
