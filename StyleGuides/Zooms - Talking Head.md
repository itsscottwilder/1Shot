---
type: zoom-style-guide
name: Zooms - Talking Head
app: 1Shot
format_version: 1
guide_version: 2
applies_to: multi-take talking-head videos for YouTube
learned_from: z0ZQMOC57g8, 1uZlLI7Iu-A, GmYFCXcf4lw, Um5KSLgUzlA (analyzed 2026-11-08)
input: 1Shot edit transcript (.json) + the cut list for the same clip
output: zoom list (.json)
---

# Style guide: Zooms — Talking Head

## Purpose

Add punchy, deliberate pacing to a single-camera talking-head video: **instant punch-in zooms** that
land on the line that matters, and **instant resets** back to the base frame when a new point starts.
No moving zooms, no sound effects. The zoom is punctuation, not decoration.

## Worked example: what the author's videos do (measured)

> These numbers come from the 1Shot author's own channel and are here as a worked example.
> To match your own style, measure a few of your videos the same way and update the Settings below.

| Video | Length | Punch-ins | Base frame | Punch frame | Moving zooms / SFX |
|---|---|---|---|---|---|
| How to Start & Grow… (Nov 2026) | 8:03 | 9 | 100% | ~125% (CTA ~140%) | none |
| Give me 10 minutes… (Nov 2026) | 10:24 | 3 digital + "human zooms" (walking to/from camera) | 100% | ~133% | none |
| If You Have a Job… (Oct 2026) | 9:56 | 9 | 100% | ~130% | none |
| YouTube Gurus LIE… (Sep 2026) | 10:40 | 2 | 100% | ~130% | none |

Every zoom in all four videos is an **instant jump-cut zoom**. Zero slow pushes, pull-backs, snap/crash
zooms, eased keyframe zooms or dolly zooms. The newer videos punch in more often (about 1 per minute).

## Settings

```yaml
base_scale: 1.00          # the normal frame
punch_scale: 1.28         # the emphasis frame (measured 1.25–1.35)
cta_scale: 1.40           # the final subscribe/sign-off ask only
punch_hold_min: 6         # seconds a punch-in stays before resetting
punch_hold_target: 10
punch_hold_max: 15        # longer than this and it stops feeling like emphasis
base_hold_min: 15         # seconds at base before the next punch-in (outside the hook)
hook_seconds: 45          # the opening; zooms may alternate faster here
hook_hold: 8              # in the hook, switch about every 8 s (every 1–2 sentences)
punches_per_minute: 1.0   # target density after the hook
anchor: eyes              # zoom around the speaker's eyes so they stay in the same spot (Rule 8)
default_anchor: [0.50, 0.42]   # x, y as fractions of the frame from the top-left: the usual eye position
transition: cut           # instant; never animate the scale
sound_effect: none
```

## Rules

### Must

1. **MUST** make every zoom an instant scale change (`transition: cut`). Never animate it.
2. **MUST** place each zoom at a **sentence start** or exactly on a cut from the cut list — never in the
   middle of a word, and preferably on the first word of the line it emphasizes.
3. **MUST** only use three scales: `base_scale`, `punch_scale`, and (once) `cta_scale`.
4. **MUST** punch in for:
   - the **thesis / promise** of the video in the hook ("By the end of this video…", "I'm going to show you…")
   - a **one-word takeaway** or the name of a step/point when it's said ("Step one: *simplify*")
   - a **direct instruction or warning** to the viewer ("You do not need perfect videos…", "do not get bogged down…")
   - **personal proof or a confession** ("I have already made affiliate money…", "I'm 54 and broke")
   - a **turning point** in the argument ("But we don't do the thing that's hard…")
   - each item of the **closing recap** ("So become a master of simplification…")
5. **MUST** reset to `base_scale` when:
   - a **new point, step or section** starts ("Step two…", "Now the third one…", "So here's the play…")
   - the talk turns **tactical or conversational** (explaining, giving an example, an analogy)
   - the speaker **gestures widely or reaches for a prop** (they need the wide frame)
   - the punch-in has lasted `punch_hold_max`
6. **MUST** use `cta_scale` once: on the final subscribe / "if you're still here" ask, held to the end.
7. **MUST** hold a punch-in at least `punch_hold_min` and stay at base at least `base_hold_min`
   between punch-ins (the hook is the exception — see Judgment).
8. **MUST** make a best effort to keep the **eyes in the same place in the frame** when zooming in as
   they were when zoomed out. Scale around the eyes, not the center of the frame: the eyes don't move,
   the edges of the frame do. The app zooms around `default_anchor`; if the speaker sits off-center
   or higher/lower than usual, give `anchorX` / `anchorY` on the zoom (see Output) set to where the eyes
   are in the wide frame. Keep the same anchor for every punch-in in a clip unless the speaker moves.

### Never

1. **NEVER** zoom while B-roll, a full-screen graphic or a chapter card is covering the talking head.
   The return from B-roll is always to `base_scale`.
2. **NEVER** punch in twice in a row without a reset between (the only step-up allowed is punch → CTA).
3. **NEVER** use slow push-ins, pull-backs, snap/crash zooms, eased keyframe zooms, dolly zooms or whooshes.
   They aren't part of this channel's style. (A future guide may allow a slow push for a personal story.)
4. **NEVER** punch in on a demonstration where he moves toward or away from the camera himself
   ("human zoom") — the physical move already does the job.
5. **NEVER** let a punch-in move the eyes. (Zooming in around any point inside the frame never shows
   an edge of the picture, so there's never a reason to shift them.)

## Judgment

- **Hook (first `hook_seconds`):** alternate base ↔ punch about every `hook_hold` seconds, every 1–2
  sentences, to grab attention. After the hook, slow down to about `punches_per_minute`.
- **Pick the line, not the moment:** the punch-in goes on the line a viewer would quote or underline.
  If two candidate lines are close together, choose the stronger one and leave the other.
- **Quiet videos:** a reflective, serious video (like "YouTube Gurus LIE") can have very few punch-ins —
  save them for the vulnerable or turning-point lines. Don't force the density.
- **Cuts and zooms together:** when a cut from the cut list falls on or within 0.5 s before the line, put the
  zoom exactly on that cut — the jump in scale hides the jump cut.
- **Text on screen:** if a one-word text graphic is planned for a keyword, punch in on the same word.

## Output

Reply with one JSON object, nothing else:

```json
{
  "styleGuide": "Zooms - Talking Head",
  "clip": "IMG_0022.mov",
  "zooms": [
    { "at": 31.30, "scale": 1.28, "type": "punch-in", "reason": "thesis", "words": "I want you to think about…", "anchorX": 0.50, "anchorY": 0.40 },
    { "at": 41.80, "scale": 1.00, "type": "reset",    "reason": "new point", "words": "Every guru on YouTube…" },
    { "at": 282.70, "scale": 1.40, "type": "cta",     "reason": "subscribe ask", "words": "So do me a favor…" }
  ],
  "summary": { "punchIns": 1, "resets": 1, "cta": 1 }
}
```

- `at`: seconds on the **original clip** (same clock as cuts), 2 decimals; the new scale starts at this time.
- `scale`: one of `base_scale`, `punch_scale`, `cta_scale`.
- `type`: `punch-in`, `reset` or `cta`.
- `reason`: thesis, keyword, instruction, proof, turning-point, recap, new point, conversational, prop, max-hold, subscribe ask.
- `words`: the first few words spoken at that moment.
- `anchorX` / `anchorY` (optional, punch-ins and cta only): where the eyes are in the wide frame,
  0–1 from the top-left. Leave them out to use `default_anchor`.
- Sorted by `at`. The clip starts at `base_scale`; the first entry is normally a punch-in.
