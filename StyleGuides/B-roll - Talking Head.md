---
type: broll-style-guide
name: B-roll - Talking Head
app: 1Shot
format_version: 1
guide_version: 8
applies_to: one-take talking-head videos for YouTube
learned_from: z0ZQMOC57g8, 1uZlLI7Iu-A, GmYFCXcf4lw, Um5KSLgUzlA (analyzed 2026-11-08)
input: edit transcript (.json) + the cut list and zoom list for the same clip
output: B-roll list (.json)
---

# Style guide: B-roll — Talking Head

## Purpose

Cut away from the talking head to **show what the speaker is saying** — the action or the object in the
sentence — for a few seconds, then come straight back to them. B-roll illustrates; it never decorates,
and their voice always keeps going underneath.

## Worked example: what the author's videos do (measured)

> These numbers come from the 1Shot author's own channel and are here as a worked example.
> To match your own style, measure a few of your videos the same way and update the Settings below.

| Video | B-roll shots | Length each | What's shown |
|---|---|---|---|
| If You Have a Job… | 6 | 8–10 s | hands typing on a laptop, setting up a softbox light, writing ideas on paper outdoors, holding a gray card, laptop research |
| How to Start & Grow… | 5 | 7–11 s | creator photo, gear setup, laptop, writing |
| YouTube Gurus LIE… | 0 | — | chapter-title cards instead |
| Give me 10 minutes… | 0 | — | shows things live on camera (location changes, mic tests) |

In those videos every shot was the author's own footage. It is always a hard cut in and a hard cut out, with no
sound effects, and the talking head always comes back at the normal frame.

**Learned from the author's own B-roll pass on a test project (2026-11-09):** they placed **6 stock shots
in about 3:15** of finished video, every one **5 s** long, about 20–30 s apart. They matched the **idea or
feeling** as often as the literal object (a frustrated woman at a laptop for "creative ruts", a man walking
and thinking for "ask yourself…"), used stock with people in it, and put B-roll **inside punched-in
stretches** once the punch-in had landed.

> **Current policy (2026-11-09): stock only.** Until the user says otherwise, do **not** use anything from their
> own drive or Movies folder — own footage needs its own color grade, which isn't practical yet. Use only
> Pixabay video and Unsplash photos, which are already finished color.

## Settings

```yaml
length_min: 4             # seconds on screen
length_target: 5
length_max: 8
spacing_min: 20           # seconds of talking head between B-roll shots
per_minute: 1.8           # about one shot every 30 s in a teaching video; 0 is fine for a reflective one
punch_settle: 2           # a shot inside a punched-in stretch starts at least this long after the punch-in
no_broll_first: 20        # seconds at the start that stay on the speaker's face (the hook)
transition: cut
sound_effect: none
```

## Picking the clip (2026-11-09; one spot at a time since 2026-11-10)

Pixabay's top result for a search is often wrong (Testing 11/9: "smartphone on tripod outdoors" came
back as hands texting indoors; "man walking thinking outdoors" as a shocked man in a studio). So:

1. Choose **all** the spots first and show them to the user as a list (time, words, length). They approve
   the spots on their own — they may drop, move or add spots.
2. Then go through the approved spots **one at a time, in order**. For the current spot only:
   1. Search Pixabay with `broll_candidates` (up to 40 results) and look at the sheet.
   2. Pick **your 10 favorites** that truly show the words, and show the user a sheet of just those,
      titled with the spot (time + words), with each clip's pixabay.com page link. Say which one you'd pick.
   3. **Stop and wait.** The user either picks the winner by number, or gives you a different phrase to search.
      For a new phrase, search it and show a new top-10 sheet for the **same** spot. Repeat until they pick.
   4. Place the winner with `apply_broll` using its `pixabayId`. `apply_broll` replaces the whole list,
      so send every clip picked so far, not just the new one. Then move on to the next spot.
3. **Never** search ahead for later spots, show more than one spot's sheet at a time, or pick a winner
   for the user. **Never place an unchecked top result.**

## The shared B-roll Library (2026-11-10)

Every clip the user approves is copied to **`~/Movies/1Shot/B-roll Library`**, so every project
can use it. The app does this by itself when an approved clip is placed: anything placed by `pixabayId`
or `url` (never an unchecked `search` result, never the user's own footage) goes into the library once, and
`library.json` there lists each clip with its credit, Pixabay page and the words it was first used for.
Placing a clip that's already in the library copies it from there instead of downloading it again.

- **MUST** treat every clip the user picks as approved for the library — that's automatic, nothing to do.
- **MUST** save any clip the user asks to keep (a runner-up, a "maybe") with `save_to_broll_library` —
  it goes into the library without being placed in the edit.
- **SHOULD** offer a clip from the library first when a new spot matches something the user already
  approved (same idea or object): show it beside your top 10 and say which project it came from.
  They still pick; a library clip is placed by its `pixabayId` like any other.

## Sources (stock only, in this order)

1. **Pixabay video** (free, the user's own key, searched by the app on their Mac). Give a short, literal `search`:
   the action and the object, e.g. `"hands typing laptop close up"`, `"writing notebook outdoors"`.
   **Search for the scene or the object, not a mood or an expression**: words like "bored", "shocked" or
   "thinking" bring back staged faces. People are fine (the author's videos use them) as long as they read as
   "someone like the viewer", never as a stand-in pretending to be the speaker.
2. **Unsplash photo** (free) for objects, places and screens when no video fits. Give the photo's
   download `url` and a `credit` ("Photo by NAME on Unsplash"). Photos get a gentle push automatically.
3. **Never** use `file` (the user's own footage) while the stock-only policy above is in effect.

## Rules

### Must

1. **MUST** tie every shot to words being spoken: an **action** ("writing down", "setting up", "typing"),
   a **thing** the speaker names ("tripod", "camera", "microphone"), a **place** ("the backyard", "your desk"),
   or the **feeling/idea** of the line ("creative ruts" → someone frustrated at a laptop; "ask yourself" →
   someone walking and thinking). If you can't point to the words, don't add a shot.
2. **MUST** start a shot at the **start of the phrase** that names it (or on a cut), and end it at the end
   of that sentence or on the next cut, within `length_min`–`length_max`.
3. **MUST** leave `spacing_min` of talking head between shots and keep to about `per_minute`.
4. **MUST** use stock only (Pixabay video first, Unsplash photos second) — see the policy above.
5. **MUST** pick clips **one spot at a time** with the user (see Picking the clip): your top 10 for one spot,
   then wait for their winner or a new search phrase before moving on.
6. **MUST** keep every approved clip in the shared B-roll Library (the app copies it there when it's placed;
   see The shared B-roll Library).

### Never

1. **NEVER** cover the hook (`no_broll_first`), the thesis/promise, the call to action, the subscribe
   ask or the sign-off. Those need the speaker's face.
2. **NEVER** cover the **first `punch_settle` seconds** of a punch-in — let the zoom land on the speaker's face first.
   After that, B-roll may cover part of a punched-in stretch when it illustrates something named there
   (the author did this for "get a tripod", "ask yourself" and "how you sound to your microphone").
3. **NEVER** cover a moment where the speaker demonstrates something on camera or reaches for a prop.
4. **NEVER** use stock with a recognizable face standing in for the speaker, logos/brands front and center, or
   anything that contradicts what the speaker says (a city skyline when they say "my backyard").
5. **NEVER** stack shots back to back. One shot, then back to them.
6. **NEVER** use a vertical (portrait) video — horizontal only, ever (2026-11-10). The app
   leaves vertical clips off candidate sheets and refuses to place one.

## Judgment

- **Teaching videos** (steps, how-tos) get B-roll on the actions in each step. **Reflective or personal
  videos** (like "YouTube Gurus LIE") can have none — don't force it.
- **Lists of objects** ("titles, thumbnails, scripts") — one shot for the list, not one per item.
- **Driving clips:** the car itself is the scene; only cut away for something he names that isn't in view.
- When unsure, leave it out and mention it in `review`.

## Output

Reply with one JSON object, nothing else:

```json
{
  "styleGuide": "B-roll - Talking Head",
  "clip": "IMG_0022.mov",
  "broll": [
    { "at": 124.60, "length": 5, "kind": "video", "search": "setting up tripod outdoors",
      "reason": "thing", "words": "get a tripod and try going to the backyard" },
    { "at": 165.40, "length": 8, "kind": "video", "search": "writing script notebook desk",
      "reason": "action", "words": "coming up with ideas, writing scripts" },
    { "at": 270.10, "length": 6, "kind": "photo", "url": "https://images.unsplash.com/…",
      "credit": "Photo by NAME on Unsplash", "reason": "thing", "words": "how you sound to your microphone" }
  ],
  "review": [],
  "summary": { "shots": 3, "secondsCovered": 22 }
}
```

- `at`: seconds on the **original clip** (same clock as cuts and zooms), when the shot starts.
- `length`: seconds the shot stays on screen in the finished video.
- `kind`: `video` or `photo`. Give exactly one of `pixabayId` (the clip the user picked; preferred),
  `search` (Pixabay's top match, unchecked) or `url` (Unsplash photo).
  (`file` and `sourceIn`, for his own footage, are not used while the stock-only policy is in effect.)
- `reason`: action, thing or place. `words`: the phrase it illustrates.
- Sorted by `at`, no overlaps.
