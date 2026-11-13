---
type: style-guide-index
app: 1Shot
format_version: 1
---

# 1Shot — Editing Style Guides

This folder holds editing style guides. Each guide tells an AI (Claude, ChatGPT, Gemini, or any other)
exactly how to turn a 1Shot **edit transcript** into a **cut list**.

## For the AI reading this

1. You will be given one style guide (a `.md` file from this folder) and one edit transcript
   (`<clip>.json` from a project's `Transcripts` folder; the matching `.txt` is a readable copy).
2. Follow the style guide's rules exactly. Rules marked **MUST** / **NEVER** are not optional.
   Rules marked **SHOULD** are strong defaults; break one only when the guide's own judgment rules say so,
   and say why in the cut's `note`.
3. Reply with the cut list in the format the guide's **Output** section defines — valid JSON, nothing
   before or after it — unless the person asks you to explain your choices.
4. All times are **seconds on the original clip** (not the trimmed timeline), exactly as in the transcript.

## The edit transcript (input)

| Field | Meaning |
|---|---|
| `clip` | Video file name |
| `duration`, `fps` | Clip length in seconds, frames per second |
| `trimStart`, `trimEnd` | The project's in/out points when the transcript was made. Nothing outside them is in the video. |
| `words[]` | Every word: `w` text, `s` start, `e` end (seconds). A word whose time is much longer than it takes to say usually has a pause inside it. |
| `segments[]` | Phrases/sentences: `s`, `e`, `text` |
| `silences[]` | Measured pauses (`s`, `e`), at least `minSilence` long, detected after voice isolation |
| `pauseSource`, `silenceThresholdDB` | How the pauses were measured |

## Making a new guide

Copy `Default - Talking Head.md`, rename it, and change the values and rules. Keep the same section
headings (`Purpose`, `Settings`, `Rules`, `Judgment`, `Output`) so every AI reads every guide the same way.
