# 1Shot

A Mac app for turning a one-take, talking-head recording into a YouTube-ready edit — and letting
Claude do the tedious parts with you, one step at a time.

You record yourself in one long take. 1Shot helps you:

- **Look and sound right** — white balance, LUTs, levels, stabilization; voice isolation, gate,
  compressor, de-esser, limiter, and a loudness meter aimed at YouTube's −14 LUFS.
- **Find the real take** — an on-device transcript of every word, with trim points.
- **Tighten it** — remove ums, long pauses, false starts and retakes.
- **Add pacing** — instant punch-in zooms on the lines that matter.
- **Illustrate it** — stock B-roll from Pixabay (video) and Unsplash (photos), kept in a shared
  B-roll Library every project can reuse.
- **Add motion graphics** — name plates, callouts, bullets and title cards.
- **Export** — a finished video, or a timeline for DaVinci Resolve.

## Editing with Claude

1Shot comes with a small helper that connects it to the [Claude desktop app](https://claude.ai/download)
over MCP. Claude can then open your project, read the transcript, propose cuts, zooms, B-roll and
graphics, and place them in the app — stopping for your approval after every step.

How Claude edits is written down in plain-language **style guides** (`StyleGuides/`), which you can
edit to match your own style. The guides that ship with the app use measurements from the author's
own videos as a worked example.

## Requirements

- An **Apple Silicon Mac running macOS 26** (Tahoe) or later. On-device transcripts use Apple's
  speech model, new in macOS 26.
- **Apple's command-line developer tools** (free) to build it: `xcode-select --install`
- Optional: the **Claude desktop app**, to edit with Claude.
- Optional: a free **[Pixabay API key](https://pixabay.com/api/docs/)** for stock B-roll
  (enter it in 1Shot › Settings…; it's stored in your Keychain).

## Build and run

```bash
git clone https://github.com/itsscottwilder/1Shot.git
cd 1Shot
./build.sh
```

This builds `1Shot.app` in the project folder and opens it in Finder. Drag it into Applications if
you like.

`build.sh` also installs the Claude helper in `~/Library/Application Support/1Shot` and **adds a
`1shot` entry to the Claude desktop app's settings** (it saves a backup of that file first). Quit
and reopen Claude to connect.

## Where your files go

| What | Where |
|---|---|
| Projects (by default), style guides, B-roll Library | `~/Movies/1Shot` |
| LUTs, the Claude helper | `~/Library/Application Support/1Shot` |
| Pixabay key | your Keychain |

Everything runs on your Mac. Transcription is on-device (macOS downloads Apple's speech model the
first time). The app itself only goes online for B-roll: Pixabay searches and thumbnails, and
downloading the clips and photos you place.

## License

[MIT](LICENSE) © 2026 Scott Wilder
