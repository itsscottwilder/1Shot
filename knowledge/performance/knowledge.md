# Performance — facts and observed patterns

Measured 2026-11-14 on a synthetic 1080p30 clip with 100 cuts unless stated.

- Playback CPU was dominated by redrawing the timeline strip, not by decoding or grading: 125–130 % of a core with the playhead drawn in `TrimBar.draw`, 49–65 % with it as a separate layer.
- `-O` alone does not optimize across files with `swiftc`; `-wmo` does, and it also made the full build faster (47 s → 33 s).
- Reaching into class-property arrays inside a per-sample loop is expensive: `LUFSMeter.process` got 6× faster by copying the four biquads into locals for the loop, with bit-identical results.
- The String-based .cube parser cost 333 ms for a 65-point LUT; parsing the bytes and handing each word to the same `Float` parser is 51 ms and byte-identical.
- `vDSP_convD` on the interior of the stabilizer's Gaussian is ~20× faster than the scalar loop (max difference 2e-14).
- Not worth touching (looked at, cost is small): the ~10 uncontended locks per frame in `ColorGrade`, per-frame `CIFilter(name:)` creation, compressor `log10f`/`powf`, the limiter's 73-sample scan, the undo poller, `GraphicsTuningStore`'s 0.5 s stat.
- The app's control socket (`~/Library/Application Support/1Shot/mcp.sock`, newline-delimited JSON) can drive a build end to end: `open_project {path}`, `seek {to, play}`, `apply_cuts`, `snapshot_frame`. Useful for smoke tests and CPU measurements without touching real projects.
- `./build.sh` quits a running 1Shot, reinstalls the MCP helper and reveals the app in Finder. For a compile check only, run its `swiftc` line with `-o` pointed elsewhere.
