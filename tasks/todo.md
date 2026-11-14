# Performance pass (2026-11-14)

Plan: `~/.claude/plans/wiggly-crafting-swing.md`

## Playback (main thread)
- [x] TrimBar: playhead as overlay layers, not a full redraw
- [x] TrimBar: prefix sums + binary search in `shown` / `clipTime(shown:)`
- [x] MeterView / GainReductionMeter: redraw only on change, static labels
- [x] Chase seek for scrubbing and trim-handle drags (`seekExactly` left as is — see Review)

## Slider drags
- [x] `graphicsThumb` cache keyed by plate id (fixes `listThumbCache` leak)
- [x] AssetsPanel: skip group-list rebuild / reload when unchanged
- [x] Stabilizer `gaussian` with vDSP

## Render thread
- [x] BrollRenderer: cached duration, last-frame memo, LRU cap on generators
- [x] `arollGrade` allocation-free; static Rec. 709 color space

## Loading and I/O
- [x] `CubeLUT.cached(url:)`, remove `visualLUTCache`; faster parser if 65³ > 50 ms
- [x] `currentTranscript()` cache by url + modification date
- [x] `ProjectData: Equatable`, skip encode when unchanged

## Offline pipelines
- [x] `LUFSMeter.process` with local filter state
- [x] `autoreleasepool` per iteration in reader loops and export pumps

## Control server
- [x] Replies encoded/written off main; incremental newline scan (app + MCP helper)

## Lifetime and memory
- [x] Stop history + meter timers in `tearDown`; AudioRack observer removed in `deinit`
- [x] `zoomThumbs` eviction keeps the visible range

## Build
- [x] `-wmo` in build.sh

## Verification
- [x] Baseline + final compile to scratchpad, no new warnings
- [x] Differential tests: LUT, LUFS, TrimBar mapping, Gaussian
- [x] Before/after timings
- [x] `./build.sh` + smoke test

## Review

All items done except where noted. Nothing committed.

Measured (scratchpad harnesses, old code from `git show HEAD:`; app numbers on a synthetic 1080p30
clip with 100 cuts, two runs each):

| What | Before | After | Output |
|---|---|---|---|
| Playback CPU (whole app) | 125–130 % of a core | 49–65 % | playhead position confirmed by screenshot |
| Paused CPU | ~3 % | ~3 % | — |
| Timeline time mapping, one waveform draw, 500 clips | 2.60 ms | 0.27 ms | bit-identical (1.6 M checks) |
| LUT parse, 65-point | 333 ms | 51 ms (0.07 ms when cached) | byte-identical, 17 files |
| LUT parse, 33-point | 45 ms | 6.6 ms | byte-identical |
| Stabilizer smoothing, 216k frames, widest window | 276 ms per axis | 13.5 ms | max difference 2e-14 |
| Loudness meter, 10 min stereo | 766 ms | 123 ms | bit-identical readings |
| Full compile | 47 s | 33 s (with -wmo) | same 48 warnings |

Changed from the plan:
- `seekExactly` (arrow keys) was left alone: it works out its target from the player's current
  time, so holding back seeks there would change how key-repeat stepping behaves. The coalesced
  seek covers scrubbing and trim-handle drags.
- Added (found on the way): B-roll list thumbnails asked for one at a time per clip instead of a
  new image generator on every slider tick; photo thumbnails decoded small; the timeline's tile
  eviction also forgets the request, which fixes tiles staying blurry after the old 800-tile reset.

Not verified here (needs a person and real footage): scrubbing feel, the overview tick when
zoomed in, slider drags on the Graphics / B-roll tabs, LUT and group switching, stabilize sliders
in the app, and an export compared against one from the previous build.
