# Performance — rules (apply by default)

- Anything that moves every video frame (playhead, meters) gets its own layer-backed view or redraws only when its value changed; it must not invalidate the timeline strip.
- A change to a hot numeric path ships with an old-vs-new differential test (old code from `git show HEAD:`), bit-identical where the arithmetic order is unchanged.
- Measure before rewriting: the LUT parser was only rewritten after timing showed 333 ms.
- Caches are bounded and keyed by what the content depends on (file path + modification date + size; plate id + plate value), never by a name alone.
