# Performance — hypotheses (need data)

- B-roll frames come from a synchronous `AVAssetImageGenerator.copyCGImage` per frame on the compositor thread (Broll.swift). Expected to be the main cause of dropped frames while B-roll is on screen and of slow exports with B-roll; real composition tracks through a custom compositor would decode sequentially. Not measured.
- Export decodes and grades frames that fall inside cuts and then discards them (Exporter.swift, video pump). Reading the edited composition instead should cut export time by about the fraction of the recording that is cut out. Not measured; needs an A/B of the output file.
- Attaching `AVPlayerItemVideoOutput` on every tab makes AVFoundation produce an extra BGRA frame per video frame even when the histogram is hidden. Not measured.
- The waveform pyramid holds ~65 MB per hour of audio as Float; Int16 would halve it with no visible change. Not measured.
- The reader loops had no autorelease pool; pools were added per iteration, but whether memory actually grew before was not measured.
