// 1Shot — a quick YouTube prep utility for macOS: play, trim, color-correct,
// clean up the voice and export a YouTube-ready file, all in one window.

import Cocoa
import AVKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Big timecode overlay

final class TimecodeOverlay: NSView {
    var text = "00:00:00" { didSet { if text != oldValue { needsDisplay = true } } }

    // Let clicks fall through to the player controls underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Scale with the window: ~7% of width, capped by height (half the old size, 2.5.1).
        let size = max(12, min(bounds.width * 0.07, bounds.height * 0.175))
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0           // negative = fill + outline
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let s = str.size()
        // Centered horizontally, sitting near the bottom of the video area.
        let bottomMargin = bounds.height * 0.03
        str.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                             y: bottomMargin))
    }
}

// MARK: - Window content that accepts dropped files

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var showsHint = true { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard showsHint else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let str = NSAttributedString(string: "Drop a video or project here · New Project ⌘N · Open Video ⌘O", attributes: attrs)
        let s = str.size()
        str.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?.first
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}

// MARK: - Player window

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    fileprivate static var anyCreated = false
    private let container = DropView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
    let playerView = AVPlayerView()
    let overlay = TimecodeOverlay()
    var player: AVPlayer?
    private var timeObserver: Any?
    let rack = AudioRack()
    lazy var drawer = SoundDesignPanel(rack: rack)
    let trimBar = TrimBar()
    let exportDrawer = VisualDesignPanel()
    let assetsPanel = AssetsPanel()
    /// The DaVinci-style step tabs (3.0.0) and the permanent right-side panel they switch between.
    let tabBar = WorkspaceTabBar()
    /// Play/pause, frame steps, go to start/end and loop, above the step tabs (3.3.3).
    let transportBar = TransportBar()
    private var transportObservation: NSKeyValueObservation?
    let rightPanel = RightPanel()
    // 3.2: list panels for the Cuts, Zooms, B-roll and Graphics tabs (see TimelinePanels.swift).
    let cutsPanel = TimelineListPanel(title: "Cuts", subtitle: "Every piece cut out, in order. Type an In or Out time (MM:SS:FF) and press Return to move that edge to the frame.", thumbnails: false)
    let zoomsPanel = TimelineListPanel(title: "Zooms", subtitle: "Each punch-in, from where it starts (In) to the reset that ends it (Out).", thumbnails: false)
    let brollFraming = BrollFramingControls()
    lazy var brollPanel = TimelineListPanel(title: "B-roll", subtitle: "Shots on V2 in timeline order. Select one to zoom in and pan across it.", thumbnails: true, accessory: brollFraming)
    let plateControls = GraphicsPlacementControls()
    let plateHandles = PlateHandlesView()               // 3.2: move/resize plates on the video
    var plateBoxCache: [String: (base: CGRect, pivot: CGPoint)] = [:]
    var plateDrag: PlateDrag?
    let brollHandles = PlateHandlesView()               // 3.2: picture-in-picture B-roll on the video
    var brollDrag: BrollDrag?
    var selectingBrollRow = false      // updateBrollHandles is selecting a row (stops it looping)
    let exportPanel = ExportPanel()
    var scrubInProgress = false
    // Visual Design groups (3.2; see VisualGroupControl.swift)
    var visualGroups: [VisualGroup] = VisualGroup.defaults
    var activeVisualGroup = VisualGroup.arollID
    var selectedVisualClip: VisualClip?
    var resumeAfterScrub = false
    lazy var graphicsPanel = TimelineListPanel(title: "Graphics", subtitle: "Plates in timeline order. Drag a plate on the timeline to move it in time; select one to resize or move it on screen.", thumbnails: true, accessory: plateControls)
    var zoomRowMap: [(punch: Int, reset: Int?)] = []
    var listThumbCache: [String: NSImage] = [:]
    /// B-roll thumbnails being made now, so a refresh (every framing-slider tick) doesn't ask again.
    var brollThumbsLoading = Set<String>()
    /// Graphics list thumbnails, one per plate id: a slider drag replaces its entry instead of adding one.
    var plateThumbCache: [String: (plate: GraphicPlate, style: String, image: NSImage)] = [:]
    private(set) var currentTab: WorkspaceTab = .visualDesign
    /// Assets tab (3.1.0): the project's source clips for the assembled A-roll.
    var assets: [AssetEntry] = []
    private(set) var selectedAssetID: UUID?
    let grade = ColorGrade()
    let stabilizer = Stabilizer()
    /// Edit › Undo / Redo (see Undo.swift).
    let history = EditHistory()
    private var videoComposition: AVVideoComposition?
    private let eyedropperView = EyedropperView()
    private var refreshPending = false
    private var videoOutput: AVPlayerItemVideoOutput?
    private var histogramTimer: Timer?
    private var histogramBusy = false
    private let histogramQueue = DispatchQueue(label: "1Shot.histogram")
    private var thumbnailGenerator: AVAssetImageGenerator?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "1Shot"
        window.minSize = NSSize(width: 520, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        // Only the first project window remembers its place; later ones cascade from the front one.
        if !PlayerWindowController.anyCreated { window.setFrameAutosaveName("1ShotPipelineWindow") }
        PlayerWindowController.anyCreated = true
        super.init(window: window)
        window.delegate = self

        playerView.frame = container.bounds
        playerView.autoresizingMask = [.width, .height]
        // No hovering QuickTime controls (2026-11-11: never used). Space plays/pauses,
        // the timeline scrubs, and J/K/L-style keys work as before.
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.isHidden = true
        container.addSubview(playerView)

        // contentOverlayView sits above the video but below the playback controls.
        if let ov = playerView.contentOverlayView {
            overlay.frame = ov.bounds
            overlay.autoresizingMask = [.width, .height]
            ov.addSubview(overlay)
        }
        overlay.isHidden = !UserDefaults.standard.bool(forKey: "TimecodeVisible")
        // Black cover for the 2 s tail after a fade to black (the export adds that black; the preview shows it here).
        if let ov = playerView.contentOverlayView {
            tailCover.frame = ov.bounds
            tailCover.autoresizingMask = [.width, .height]
            tailCover.wantsLayer = true
            tailCover.layer?.backgroundColor = NSColor.black.cgColor
            tailCover.isHidden = true
            ov.addSubview(tailCover, positioned: .below, relativeTo: overlay)
        }

        // Always-open trim strip under the video.
        trimBar.autoresizingMask = [.width, .maxYMargin]
        trimBar.isHidden = true
        container.addSubview(trimBar)
        trimBar.onTrimChanged = { [weak self] start, end, movingStart, finished in
            self?.trimChanged(start: start, end: end, movingStart: movingStart, finished: finished)
        }
        trimBar.onVolumeChanged = { [weak self] map, finished in
            guard let self else { return }
            if finished { self.setVolume(map) } else { self.volume = map }   // sound follows on mouse-up
        }
        trimBar.onResizeSourceClip = { [weak self] index, left, delta in
            self?.resizeSourceClip(index: index, left: left, delta: delta)
        }
        trimBar.onRemoveCut = { [weak self] i in self?.removeCut(at: i) }
        trimBar.onPlayAcrossCut = { [weak self] i in self?.playAcrossCut(at: i) }
        trimBar.onResizeCut = { [weak self] i, c in self?.resizeCut(at: i, to: c) }
        trimBar.onNeedThumbnails = { [weak self] keys in self?.makeZoomThumbnails(keys: keys) }
        trimBar.clipView = UserDefaults.standard.object(forKey: "TimelineShowsClips") as? Bool ?? true
        trimBar.onMoveZoom = { [weak self] i, t in self?.moveZoom(at: i, to: t) }
        trimBar.onEditBroll = { [weak self] i, s, e, part in self?.editBroll(at: i, start: s, end: e, part: part) }
        trimBar.onRemoveBroll = { [weak self] i in self?.removeBroll(at: i) }
        trimBar.onDropBroll = { [weak self] urls, t in self?.addBrollFiles(urls, at: t) }
        trimBar.onChangeZoom = { [weak self] i, s in self?.changeZoom(at: i, scale: s) }
        trimBar.onAddZoom = { [weak self] t, s in self?.addZoom(at: t, scale: s) }
        trimBar.onScrub = { [weak self] time, finished in
            guard let self else { return }
            // Clicking the timeline while playing keeps playing from the new spot (2026-11-11);
            // while paused it just moves the playhead, as before.
            if !self.scrubInProgress {
                self.scrubInProgress = true
                self.resumeAfterScrub = (self.player?.rate ?? 0) > 0
            }
            self.player?.pause()
            let resume = finished && self.resumeAfterScrub
            if finished { self.scrubInProgress = false; self.resumeAfterScrub = false }
            self.chaseSeek(to: CMTime(seconds: self.toComp(time), preferredTimescale: 600),
                           then: resume ? { [weak self] in self?.player?.play() } : nil)
        }

        // Right panel (3.0.0): a permanent sidebar whose content follows the selected tab.
        rightPanel.autoresizingMask = [.height, .minXMargin]
        rightPanel.isHidden = true
        container.addSubview(rightPanel)
        rightPanel.setPage(exportDrawer, for: .visualDesign)
        rightPanel.setPage(drawer, for: .soundDesign)
        rightPanel.setPage(assetsPanel, for: .assets)
        setUpTimelinePanels()
        setUpPlateHandles()
        setUpBrollHandles()
        setUpVisualGroups()
        rightPanel.show(.visualDesign)

        // Step tabs, docked above the timeline.
        tabBar.autoresizingMask = [.width, .maxYMargin]
        tabBar.isHidden = true
        tabBar.onSelect = { [weak self] tab in self?.selectTab(tab) }
        container.addSubview(tabBar)
        transportBar.onGoToStart = { [weak self] in self?.goToStart() }
        transportBar.onStepBack = { [weak self] in self?.stepFrame(by: -1) }
        transportBar.onPlayPause = { [weak self] in self?.togglePlayPause() }
        transportBar.onStepForward = { [weak self] in self?.stepFrame(by: 1) }
        transportBar.onGoToEnd = { [weak self] in self?.goToEnd() }
        transportBar.onToggleLoop = { [weak self] in self?.toggleLoop() }
        transportBar.setLoop(loopPlayback)
        transportBar.setEnabled(false)
        container.addSubview(transportBar)

        // Assets tab (3.1.0): import/review/reject/trim source clips, then build the A-roll.
        assetsPanel.onImport = { [weak self] urls in self?.importAssets(urls) }
        assetsPanel.onSelect = { [weak self] id in self?.selectAsset(id) }
        assetsPanel.onToggleReject = { [weak self] id in self?.toggleAssetRejected(id) }
        assetsPanel.onRemove = { [weak self] id in self?.removeAsset(id) }
        assetsPanel.onReorder = { [weak self] order in self?.reorderAssets(order) }
        assetsPanel.onBuild = { [weak self] in self?.buildAroll() }
        assetsPanel.onMoveToNewGroup = { [weak self] ids in self?.moveAssetsToNewGroup(ids) }
        assetsPanel.onMoveToGroup = { [weak self] ids, group in self?.moveAssets(ids, toGroup: group) }
        assetsPanel.onRenameGroup = { [weak self] id, name in self?.renameGroup(id, to: name) }
        assetsPanel.onDeleteGroup = { [weak self] id in self?.confirmDeleteGroup(id) }
        assetsPanel.urlForAsset = { [weak self] entry in self?.project?.folder.appendingPathComponent(entry.path) }
        assetsPanel.trimPanel.onSetIn = { [weak self] seconds in self?.setTrimFromPanel(start: seconds, end: nil) }
        assetsPanel.trimPanel.onSetOut = { [weak self] seconds in self?.setTrimFromPanel(start: nil, end: seconds) }
        assetsPanel.trimPanel.onSetInAtPlayhead = { [weak self] in
            guard let self else { return }
            self.setTrimFromPanel(start: self.trimBar.playhead, end: nil)
        }
        assetsPanel.trimPanel.onSetOutAtPlayhead = { [weak self] in
            guard let self else { return }
            self.setTrimFromPanel(start: nil, end: self.trimBar.playhead)
        }

        trimBar.onNeedWaveform = { [weak self] generation in
            self?.rack.makeWaveform { [weak self] data in self?.trimBar.setWaveform(data, generation: generation) }
        }

        exportDrawer.onGradeChanged = { [weak self] settings in
            self?.gradeChangedInPanel(settings)      // goes to the Visual Design group being edited (3.2)
        }
        exportDrawer.onEyedropper = { [weak self] in self?.toggleEyedropper() }
        grade.stabilizer = stabilizer
        exportDrawer.onStabilizeAnalyze = { [weak self] in self?.analyzeStabilization() }
        exportDrawer.onStabilizeToggle = { [weak self] on in
            guard let self else { return }
            self.stabilizer.enabled = on
            self.updateStabilizeUI()
            self.refreshFrame()
        }
        exportDrawer.onStabilizeSettings = { [weak self] smoothness, crop in
            guard let self else { return }
            self.stabilizer.smoothness = smoothness
            self.stabilizer.maxCrop = crop
            self.stabilizer.rebuildPlan()
            self.updateStabilizeUI()
            self.refreshFrame()
        }
        exportDrawer.onFadeChanged = { [weak self] on in
            guard let self else { return }
            self.fadeEnabled = on
            self.updateFade()
        }
        exportDrawer.onBypassChanged = { [weak self] on in
            self?.grade.bypassed = on
            self?.refreshFrame()
        }
        exportDrawer.onLUTSelected = { [weak self] slot, url in self?.useLUT(at: url, slot: slot) }
        exportDrawer.onLoadLUT = { [weak self] slot in self?.loadLUT(for: slot) }

        eyedropperView.autoresizingMask = [.width, .height]
        eyedropperView.onPick = { [weak self] point in self?.pickWhite(at: point) }
        eyedropperView.onCancel = { [weak self] in self?.endEyedropper() }

        container.onDrop = { [weak self] url in self?.open(url) }
        window.contentView = container
        window.acceptsMouseMovedEvents = true
        layoutContent()

        // Remember the out-of-the-box settings, so New Project can start from them.
        defaultColor = exportDrawer.snapshot
        defaultAudio = drawer.snapshot

        // Projects save themselves: check for changes every second and a half.
        autosaveTimer = Timer.everyMode(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.saveProject()
        }
        history.attach(to: self)
    }

    /// Video fills the window above the step tabs and timeline; the right panel (whichever
    /// tab's page is showing) is permanently docked beside the video. Nothing slides (3.0.0).
    private func layoutContent(animated: Bool = false) {
        // The workspace chrome shows as soon as a project exists — an empty timeline, ready to be
        // populated, not just once a clip is loaded. Only the DropView hint (behind the hidden
        // playerView) needs an actual clip.
        let open = project != nil
        let barHeight = open ? TrimBar.height + WorkspaceTabBar.height + TransportBar.height : 0
        let b = container.bounds
        let pw = RightPanel.width

        func place(_ view: NSView, _ frame: NSRect) {
            if animated { view.animator().frame = frame } else { view.frame = frame }
        }
        trimBar.isHidden = !open
        tabBar.isHidden = !open
        transportBar.isHidden = !open
        rightPanel.isHidden = !open
        let videoWidth = b.width - pw
        place(trimBar, NSRect(x: 0, y: 0, width: videoWidth, height: TrimBar.height))
        place(tabBar, NSRect(x: 0, y: TrimBar.height, width: videoWidth, height: WorkspaceTabBar.height))
        place(transportBar, NSRect(x: 0, y: TrimBar.height + WorkspaceTabBar.height,
                                   width: videoWidth, height: TransportBar.height))
        place(playerView, NSRect(x: 0, y: barHeight, width: videoWidth, height: b.height - barHeight))
        eyedropperView.frame = playerView.frame
        place(rightPanel, NSRect(x: videoWidth, y: 0, width: pw, height: b.height))
        placeStepTip()
        if open { DispatchQueue.main.async { [weak self] in self?.showStepTipIfNeeded() } }
        DispatchQueue.main.async { [weak self] in self?.updatePlateHandles(); self?.updateBrollHandles() }   // the video moved
    }

    /// Switches the DaVinci-style step tab: swaps the right panel's page. The timeline (V2, V1
    /// filmstrip and A1 waveform) never hides or changes.
    func selectTab(_ tab: WorkspaceTab) {
        guard currentTab != tab else { return }
        playbackPauseGeneration += 1
        hideTail()
        player?.pause()
        currentTab = tab
        trimBar.showFullAsset = (tab == .assets && selectedAssetID != nil)
        tabBar.select(tab)
        rightPanel.show(tab)
        if tab == .export { refreshExportPanel() }
        if tab == .visualDesign { pickClipAtPlayhead() } else { trimBar.clipHighlight = nil }
        if tab == .visualDesign { refreshFrame() }   // fresh frame for the histogram when paused
        updatePlateHandles()
        updateBrollHandles()
        showStepTipIfNeeded()
    }

    // MARK: Step tips (3.4.0)

    private var stepTipCard: StepTipCard?
    private var seenStepTips = Set<WorkspaceTab>()
    private var stepTipObserver: NSObjectProtocol?

    /// The first time each step is opened in this window, an explainer card pops up over the video.
    func showStepTipIfNeeded() {
        guard project != nil, !StepTipCard.turnedOff, !seenStepTips.contains(currentTab) else { return }
        seenStepTips.insert(currentTab)
        closeStepTip()
        if stepTipObserver == nil {
            stepTipObserver = NotificationCenter.default.addObserver(forName: StepTipCard.turnedOffNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
                self?.closeStepTip()
            }
        }
        let card = StepTipCard(tab: currentTab)
        card.onClose = { [weak self] in self?.closeStepTip() }
        // In the player's overlay layer: views merely stacked over AVPlayerView draw but never get clicks.
        guard let host = playerView.contentOverlayView else { return }
        host.addSubview(card, positioned: .above, relativeTo: nil)
        stepTipCard = card
        placeStepTip()
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; card.animator().alphaValue = 1 }
    }

    /// Help › Show Step Tips Again: forget what's been seen and show this step's card now.
    func resetStepTips() {
        seenStepTips = []
        showStepTipIfNeeded()
    }

    func closeStepTip() {
        stepTipCard?.removeFromSuperview()
        stepTipCard = nil
    }

    /// Centred over the video, never taller than it.
    private func placeStepTip() {
        guard let card = stepTipCard else { return }
        guard let area = card.superview?.bounds else { return }
        let size = card.frame.size
        card.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                    y: max(area.minY + 8, (area.midY - size.height / 2).rounded())))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var loadID = 0

    /// `assetID` is set when this load is the Assets tab reviewing one source clip (so its own
    /// saved in/out seeds the trim, and dragging the handles saves back to it) — nil otherwise.
    func load(_ url: URL, assetID: UUID? = nil) {
        trimBar.sourceClipBoundaries = []
        trimBar.sourceClipCount = 0
        arollPieces = []
        if project?.contains(url) != true { RecentFiles.add(url) }   // a project is listed by its project file instead
        if url.standardizedFileURL != currentVideo?.standardizedFileURL { setCuts([]) }   // cuts belong to a clip
        currentVideo = url
        arollRecipe = nil
        selectedAssetID = assetID
        trimBar.showFullAsset = (currentTab == .assets && assetID != nil)
        // Reviewing one source clip: the A-roll's volume sections don't apply to it (3.7.0).
        trimBar.volume = assetID == nil ? volume : VolumeMap()
        rack.setVolume(assetID == nil ? volume : VolumeMap(), cuts: [])
        releasePlayer()
        preparePlayer(AVURLAsset(url: url))
    }

    /// Loads an assembled multi-clip A-roll (Assets tab Build) in place of a single file.
    func loadComposition(_ composition: AVMutableComposition) {
        setCuts([])
        currentVideo = nil
        selectedAssetID = nil
        trimBar.showFullAsset = false
        trimBar.volume = volume
        rack.setVolume(volume, cuts: [])
        releasePlayer()
        preparePlayer(composition)
    }

    /// Lets go of the current player completely before another clip loads (3.3.3). A paused
    /// AVPlayer still holds its item, its 4K HEVC decoder and the view's display layer; handing the
    /// view a new player while the old one held all that could leave the viewer black (timecode
    /// only, and no sound, since the effects rack follows the player) for the new clip.
    private func releasePlayer() {
        viewerWatchdog?.cancel(); viewerWatchdog = nil
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        transportObservation = nil
        transportBar.setPlaying(false)
        transportBar.setEnabled(false)
        grade.isPlaying = false
        guard let old = player else { return }
        old.pause()
        rack.detach()
        playerView.player = nil
        old.replaceCurrentItem(with: nil)
        videoOutput = nil
        player = nil
    }

    private var viewerWatchdog: Task<Void, Never>?

    /// Makes sure the viewer actually shows a frame once the item can play (3.3.3). Now and then
    /// (large 4K HEVC clips, right after switching clips) the item is ready and the color stage
    /// renders frames, yet AVPlayerView never becomes ready for display and stays black. When that
    /// happens, hand the view its player again and re-seek exactly to force a fresh frame.
    func ensureViewerShowsFrame(_ p: AVPlayer) {
        viewerWatchdog?.cancel()
        viewerWatchdog = Task { @MainActor [weak self] in
            var attempts = 0
            var waited = 0.0
            while !Task.isCancelled, waited < 20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
                guard let self, self.player === p, let item = p.currentItem else { return }
                if item.status == .failed {
                    NSLog("1Shot: viewer: the clip failed to load: \(item.error?.localizedDescription ?? "unknown error"); log: \(item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? [])")
                    return
                }
                guard item.status == .readyToPlay else { continue }
                if self.playerView.isReadyForDisplay {
                    if waited > 0.5 { NSLog("1Shot: viewer: first frame on screen after \(waited) s") }
                    return
                }
                // Give a heavy clip a moment to show its first frame before stepping in.
                guard waited >= Double(attempts + 1) * 1.0 else { continue }
                attempts += 1
                NSLog("1Shot: viewer: ready to play but nothing on screen after \(waited) s; re-attaching (try \(attempts))")
                self.playerView.player = nil
                self.playerView.player = p
                let t = p.currentTime()
                await p.seek(to: t.isNumeric ? t : .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if attempts >= 3 {
                    NSLog("1Shot: viewer: still not showing a frame after \(attempts) tries")
                    return
                }
            }
        }
    }

    /// Find the audio track first so the effects hookup is in place BEFORE the player starts —
    /// AVPlayer can ignore a tap added mid-playback. Shared by load(_:) and loadComposition(_:).
    private func preparePlayer(_ asset: AVAsset) {
        loadID += 1
        let myID = loadID
        Task { @MainActor in
            let track = try? await asset.loadTracks(withMediaType: .audio).first
            var sampleRate = 48000.0
            if let track,
               let descs = try? await track.load(.formatDescriptions),
               let first = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee,
               asbd.mSampleRate > 0 {
                sampleRate = asbd.mSampleRate
            }
            var fps = 30.0
            if let video = try? await asset.loadTracks(withMediaType: .video).first,
               let rate = try? await video.load(.nominalFrameRate), rate > 0 {
                fps = Double(rate)
            }
            guard myID == self.loadID else { return }   // a newer file was opened meanwhile
            TrimBar.frameRate = fps
            self.start(asset: asset, audioTrack: track, sampleRate: sampleRate)
        }
    }

    private func start(asset: AVAsset, audioTrack: AVAssetTrack?, sampleRate: Double) {
        sourceAsset = asset
        sourceAudioTrack = audioTrack
        sourceSampleRate = sampleRate
        playbackCuts = []
        let item = AVPlayerItem(asset: asset)
        endEyedropper()
        stabilizer.reset()                    // shake analysis belongs to the previous clip
        exportDrawer.setStabilizeProgress(nil)
        updateStabilizeUI()
        // Every frame goes through the color grade (live preview = export).
        let composition = grade.makeVideoComposition(for: asset, forDisplay: true)
        item.videoComposition = composition
        videoComposition = composition
        NSLog("1Shot: color stage attached (render size \(composition.renderSize))")
        // Taps the finished (color-graded) frames for the Levels histogram. AVFoundation converts
        // and copies a buffer for this tap on every displayed frame, whether or not updateHistogram()
        // is actually consuming it that moment — a histogram only needs the rough spread of values,
        // so a small, fixed size keeps that continuous cost off the full 4K+ frame.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 480,
            kCVPixelBufferHeightKey as String: 270
        ])
        item.add(output)
        videoOutput = output
        if histogramTimer == nil {
            histogramTimer = Timer.everyMode(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updateHistogram()
            }
        }
        let p = AVPlayer(playerItem: item)
        // Sound is played through the effects rack, which silences AVPlayer's own audio.
        rack.attach(to: p, item: item, asset: asset, track: audioTrack, sampleRate: sampleRate)

        player = p
        playerView.player = p
        ensureViewerShowsFrame(p)
        transportBar.setEnabled(true)
        transportObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let on = p.timeControlStatus != .paused
            DispatchQueue.main.async { self?.transportBar.setPlaying(on) }
        }
        watchPlaybackEnds(of: p, item: item)
        playerView.isHidden = false
        container.showsHint = false
        overlay.text = "00:00:00"

        // Fires 60 times a second during playback (so no frame is skipped) and whenever you scrub/seek.
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60),
                                                 queue: .main) { [weak self] t in
            guard let self else { return }
            guard t.isValid, t.isNumeric else { return }
            let source = self.toSource(t.seconds)      // player time → original-clip time
            self.overlay.text = TrimBar.format(source)
            self.trimBar.isPlaying = (self.player?.rate ?? 0) != 0
            // Dragging the playhead: a scrub seek that lands after the mouse moved on mustn't pull
            // the line back. (A trim-handle drag still moves it with the frame, as before.)
            if !(self.trimBar.isScrubbing && self.chaseTarget != nil) { self.trimBar.playhead = source }
            if self.currentTab == .graphics { self.updatePlateHandles() }
            if self.currentTab == .broll { self.updateBrollHandles() }
        }

        // Set up the trim strip once the length is known.
        trimBar.duration = 0
        trimBar.resetThumbnails(count: 0)
        layoutContent()
        Task { @MainActor in
            guard let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0,
                  self.player === p else { return }
            self.trimBar.duration = d
            // Reviewing one asset in the Assets tab: seed from its own saved in/out, if any.
            if self.currentTab == .assets, let id = self.selectedAssetID,
               let a = self.assets.first(where: { $0.id == id }), a.outPoint > a.inPoint {
                self.trimBar.start = a.inPoint
                self.trimBar.end = a.outPoint
                self.assetsPanel.trimPanel.update(start: a.inPoint, end: a.outPoint)
            } else {
                self.trimBar.start = 0
                self.trimBar.end = d
            }
            self.updateFade()
            self.makeThumbnails(asset: asset, duration: d)
            self.finishRestore()
        }

        updateWindowTitle()
        window?.makeFirstResponder(playerView)   // space bar = play/pause
        showWindow(nil)
        // Leave newly loaded videos paused until the user chooses to play them.
    }

    static func format(_ t: CMTime) -> String {
        guard t.isValid, t.isNumeric else { return "00:00:00" }
        return TrimBar.format(CMTimeGetSeconds(t))
    }

    // MARK: Export

    // MARK: End of video / loop

    private(set) var loopPlayback = UserDefaults.standard.object(forKey: "LoopPlayback") as? Bool ?? true
    private var playbackPauseGeneration = 0
    private var endObserver: NSObjectProtocol?
    private let tailCover = NSView()
    private var tailToken = 0

    /// Seconds of black after the end when fade to black is on (matches the export).
    static let fadeTailSeconds = 2.0

    private func hideTail() {
        tailToken += 1
        tailCover.isHidden = true
    }
    private var rateObservation: NSKeyValueObservation?

    func toggleLoop() {
        loopPlayback.toggle()
        UserDefaults.standard.set(loopPlayback, forKey: "LoopPlayback")
        transportBar.setLoop(loopPlayback)
    }

    /// What the viewer is doing, for `status` (MCP) — so a black viewer can be diagnosed without eyes on it.
    func viewerDiagnostics() -> [String: Any] {
        var d: [String: Any] = [:]
        let item = player?.currentItem
        d["itemStatus"] = ["unknown", "readyToPlay", "failed"][item?.status.rawValue ?? 0]
        d["itemError"] = MCP.orNull(item?.error?.localizedDescription)
        d["errorLog"] = item?.errorLog()?.events.suffix(3).map { "\($0.errorDomain) \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? []
        d["timeControl"] = ["paused", "waiting", "playing"][player?.timeControlStatus.rawValue ?? 0]
        d["waitingReason"] = MCP.orNull(player?.reasonForWaitingToPlay?.rawValue)
        d["playerTime"] = MCP.r(player?.currentTime().seconds ?? -1)
        d["readyForDisplay"] = playerView.isReadyForDisplay
        d["viewHidden"] = playerView.isHidden
        d["viewHasPlayer"] = playerView.player === player && player != nil
        d["viewFrame"] = "\(Int(playerView.frame.width))x\(Int(playerView.frame.height))"
        let stats = grade.frameStats
        d["framesGraded"] = stats.graded
        d["emptySourceFrames"] = stats.emptySource
        d["lastSourceExtent"] = "\(stats.lastExtent)"
        if let out = videoOutput, let item {
            let t = out.itemTime(forHostTime: CACurrentMediaTime())
            d["outputHasFrame"] = out.hasNewPixelBuffer(forItemTime: t)
            d["outputAttached"] = item.outputs.contains { $0 === out }
        }
        return d
    }

    private func watchPlaybackEnds(of p: AVPlayer, item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.reachedEnd()
            }
        // Pressing play (any way: space, the player's button, menu) while parked at the end
        // or outside the trimmed part starts again from the beginning.
        rateObservation = p.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                if let self, player === self.player {
                    self.trimBar.isPlaying = player.rate != 0
                    self.grade.isPlaying = player.rate != 0
                }
                if let self, player === self.player, player.rate != 0 { self.hideTail() }
                guard let self, player === self.player, player.rate > 0, let range = self.trimRange else { return }
                let now = self.toSource(player.currentTime().seconds)
                if now >= range.end - 0.05 || now < range.start - 0.01 {
                    player.seek(to: CMTime(seconds: self.toComp(range.start), preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    private func reachedEnd() {
        // Fade to black on: hold 2 s of black like the export does, then loop (if looping).
        if fadeEnabled, !isExporting, trimRange != nil {
            tailToken += 1
            let token = tailToken
            tailCover.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeTailSeconds) { [weak self] in
                guard let self, token == self.tailToken else { return }
                self.tailCover.isHidden = true
                self.loopFromStart()
            }
            return
        }
        loopFromStart()
    }

    private func loopFromStart() {
        guard loopPlayback, !isExporting, let p = player, let range = trimRange else { return }
        let generation = playbackPauseGeneration
        p.seek(to: CMTime(seconds: toComp(range.start), preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            if finished { DispatchQueue.main.async { [weak self] in
                guard let self, self.player === p, self.playbackPauseGeneration == generation, self.loopPlayback else { return }
                p.play()
            } }
        }
    }

    private var exporter: VideoExporter?
    private var progressSheet: ExportProgressSheet?

    func exportVideo() {
        guard !isExporting, let window, player?.currentItem != nil,
              let asset = sourceAsset else { NSSound.beep(); return }
        player?.pause()
        let trim = trimRange

        // A composition (built from the Assets tab) has no single file of its own.
        let fileAsset = asset as? AVURLAsset

        let recipe = ExportRecipe.current          // chosen in the Export tab (3.2)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [recipe.isProRes ? .quickTimeMovie : .mpeg4Movie]
        // Next free name: "Clip (YouTube).mp4", then "Clip (YouTube) 2.mp4", "… 3.mp4"…
        // so an earlier export is never replaced and macOS never has to ask.
        let folder = project?.exportsFolder ?? fileAsset?.url.deletingLastPathComponent() ?? Project.defaultLocation
        panel.directoryURL = folder
        let baseName = fileAsset?.url.deletingPathExtension().lastPathComponent ?? project?.name ?? "A-roll"
        panel.nameFieldStringValue = Self.freeExportName(base: baseName + " (\(recipe.fileSuffix))", ext: recipe.fileExtension, in: folder)
        panel.title = "Export: \(recipe.name)"
        panel.prompt = "Export"
        let info = Self.exportInfoView(recipe: recipe, length: trim.map {
            $0.end - $0.start - CutList.totalLength(CutList.normalized(cuts, trim: $0)) + (fadeEnabled ? 2 : 0)
        })
        panel.accessoryView = info.view
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if let fileURL = fileAsset?.url, url.standardizedFileURL == fileURL.standardizedFileURL {
                self.showAlert("Choose a different name",
                               "Exporting can't replace the video that's currently open.")
                return
            }
            let normalize = info.normalize.state == .on
            UserDefaults.standard.set(normalize, forKey: "NormalizeLoudness")
            Task { @MainActor in await self.runExport(asset: asset, to: url, trim: trim, normalize: normalize, recipe: recipe) }
        }
    }

    /// "<base>.mp4" if that's free in `folder`, otherwise "<base> 2.mp4", "<base> 3.mp4"…
    private static func freeExportName(base: String, ext: String = "mp4", in folder: URL) -> String {
        let fm = FileManager.default
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base) \(n).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
            n += 1
        }
    }

    /// The export details shown at the bottom of the save sheet.
    private static func exportInfoView(recipe: ExportRecipe, length: Double?) -> (view: NSView, normalize: NSButton) {
        let title = NSTextField(labelWithString: recipe.name)
        title.font = .boldSystemFont(ofSize: 13)
        let specs = NSTextField(wrappingLabelWithString:
            recipe.specs + "\nIncludes your trim, cuts, zooms, B-roll, graphics, color and all audio processing")
        specs.font = .systemFont(ofSize: 11)
        specs.textColor = .secondaryLabelColor
        specs.preferredMaxLayoutWidth = 380
        let lengthLabel = NSTextField(labelWithString: length.map { "Length: \(TrimBar.format($0))" } ?? "")
        lengthLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let normalize = NSButton(checkboxWithTitle: "Normalize loudness to −14 LUFS (YouTube's level)", target: nil, action: nil)
        normalize.state = UserDefaults.standard.bool(forKey: "NormalizeLoudness") ? .on : .off
        normalize.toolTip = "Measures the finished audio and turns it up or down so it lands on −14 LUFS. Turning up goes through the limiter, so peaks still never pass −0.1 dB."

        let stack = NSStackView(views: [title, specs, lengthLabel, normalize])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: lengthLabel)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.setFrameSize(stack.fittingSize)
        return (stack, normalize)
    }

    @MainActor
    private func runExport(asset: AVAsset, to url: URL, trim: (start: Double, end: Double)?, normalize: Bool,
                           recipe: ExportRecipe = .current) async {
        // A clip with no sound still exports (3.5.2): picture plus a silent track, no normalizing.
        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first
        let normalize = normalize && audioTrack != nil
        let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        var transform = CGAffineTransform.identity
        var size = CGSize(width: 1920, height: 1080)
        var fps: Double = 30
        if let videoTrack, let loaded = try? await videoTrack.load(.preferredTransform, .naturalSize, .nominalFrameRate) {
            transform = loaded.0
            size = loaded.1
            fps = Double(loaded.2)
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0 else { showAlert("Export failed", "Couldn't read the video's length."); return }
        let start = max(0, trim?.start ?? 0)
        let end = min(duration, trim?.end ?? duration)
        guard end - start > 0.05 else { showAlert("Export failed", "The trimmed section is empty."); return }
        guard !isExporting else { NSSound.beep(); return }

        let cutList = CutList.normalized(cuts, trim: (start, end))
        let fadeEnd: Double? = fadeEnabled ? end : nil
        var source = VideoExporter.Source(asset: asset, audioTrack: audioTrack, videoTrack: videoTrack,
                                          videoTransform: transform, videoSize: size, frameRate: fps,
                                          videoComposition: grade.makeVideoComposition(for: asset, honorsBypass: false),
                                          start: start, end: end,
                                          tailBlack: fadeEnabled ? Self.fadeTailSeconds : 0,
                                          cuts: cutList,
                                          fadeEnd: fadeEnd)
        source.recipe = recipe
        let sheet = ExportProgressSheet(fileName: url.lastPathComponent)
        progressSheet = sheet
        window?.beginSheet(sheet.window, completionHandler: nil)

        // Normalize to −14 LUFS: measure the finished audio first, then export with the gain that lands it there.
        let drive = rack.limiterInputGain          // The user's limiter setting, put back after the export
        var plan: NormalizePlan?
        if normalize {
            let flag = CancelFlag()
            sheet.onCancel = { flag.set() }
            loudnessScanRunning = true
            do {
                plan = try await normalizationPlan(asset: asset, track: audioTrack!, start: start, end: end,
                                                   cuts: cutList, fadeEnd: fadeEnd, drive: drive, flag: flag, sheet: sheet)
                loudnessScanRunning = false
            } catch {
                loudnessScanRunning = false
                rack.setLimiter(inputGain: drive)
                window?.endSheet(sheet.window)
                progressSheet = nil
                if flag.isSet { return }
                showAlert("Couldn't measure the loudness", error.localizedDescription)
                return
            }
        }
        if let plan {
            if plan.viaLimiter { rack.setLimiter(inputGain: drive + plan.gainDB) }
            else { source.outputGain = Float(pow(10, plan.gainDB / 20)) }
        }

        sheet.setMessage("Exporting “\(url.lastPathComponent)”…")
        sheet.setProgress(0)
        let exp = VideoExporter(rack: rack, source: source, outputURL: url)
        sheet.onCancel = { [weak exp] in exp?.cancel() }
        exp.onProgress = { [weak sheet] p in sheet?.setProgress(p) }
        exporter = exp

        exp.start { [weak self] error in
            guard let self else { return }
            self.rack.setLimiter(inputGain: drive)     // the drawer's setting again (normalizing only changed the export)
            if let w = self.progressSheet?.window { self.window?.endSheet(w) }
            self.progressSheet = nil
            self.exporter = nil
            if let error {
                if let e = error as? VideoExporter.ExportError, case .cancelled = e { return }
                self.showAlert("Export failed", error.localizedDescription)
                return
            }
            guard let window = self.window else { return }
            var loudness = ""
            if let measured = exp.finalLoudness?.integrated {
                loudness = String(format: "Loudness: %.1f LUFS", measured)
                if let plan, let before = plan.before {
                    loudness += String(format: " (normalized from %.1f)", before)
                } else if !normalize {
                    let off = measured - LUFSMeter.target
                    loudness += abs(off) < 0.5 ? " (on YouTube's −14)"
                        : " (YouTube's level is −14; " + String(format: "%.1f", abs(off)) + (off < 0 ? " quieter)" : " louder)")
                }
                loudness += "\n"
            }
            if let note = plan?.note { loudness += note + "\n" }
            let alert = NSAlert()
            alert.messageText = "Ready for YouTube"
            alert.informativeText = "\(url.lastPathComponent)\n\n" + (loudness.isEmpty ? "" : loudness + "\n") +
                "Upload to YouTube opens YouTube's upload page and shows the file in Finder — drag it in and choose Unlisted."
            alert.addButton(withTitle: "Upload to YouTube")
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Done")
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn:
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    if let upload = URL(string: "https://www.youtube.com/upload") {
                        NSWorkspace.shared.open(upload)
                    }
                case .alertSecondButtonReturn:
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                default:
                    break
                }
            }
        }
    }

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    var isExporting: Bool { exporter != nil || loudnessScanRunning }

    // MARK: Loudness (Sound Design › Measure Edit, and Export's normalize to −14 LUFS)

    /// True while the edit is being rendered offline to measure it (playback and editing wait).
    private(set) var loudnessScanRunning = false

    /// Renders the whole trimmed, cut edit through Sound Design (like the export) and measures its
    /// LUFS. Used by the export's normalize-to−14-LUFS option and the MCP get_settings(measure:
    /// true) tool. Completion on the main thread.
    func scanEditLoudness(completion: ((Result<LUFSMeter.Reading, Error>) -> Void)? = nil) {
        guard !isExporting, let asset = sourceAsset, let track = sourceAudioTrack, let trim = trimRange else {
            completion?(.failure(LoudnessScan.ScanError.message(isExporting ? "Wait for the export to finish." : "No video with sound is open.")))
            return
        }
        player?.pause()
        loudnessScanRunning = true
        LoudnessScan.run(rack: rack, asset: asset, audioTrack: track, start: trim.start, end: trim.end,
                         cuts: cuts, fadeEnd: fadeEnabled ? trim.end : nil) { [weak self] result in
            guard let self else { return }
            self.loudnessScanRunning = false
            completion?(result)
        }
    }

    struct NormalizePlan {
        let before: Double?      // the edit's loudness as it is
        let gainDB: Double       // how much it's raised (+) or lowered (−)
        let viaLimiter: Bool     // true: by driving the limiter (peaks stay under −0.1 dB); false: plain gain
        let note: String?
    }

    final class CancelFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Measures the edit and works out the gain that lands it on −14 LUFS. With the limiter on, the
    /// gain goes into the limiter's drive (so peaks can't pass its −0.1 dB ceiling); a big boost is
    /// measured a second time, because more limiting makes it come out a little quieter than planned.
    /// Without the limiter it's plain gain, kept small enough that peaks stay under −1 dB.
    @MainActor
    private func normalizationPlan(asset: AVAsset, track: AVAssetTrack, start: Double, end: Double,
                                   cuts: [Cut], fadeEnd: Double?, drive: Double,
                                   flag: CancelFlag, sheet: ExportProgressSheet) async throws -> NormalizePlan {
        let target = LUFSMeter.target
        func scan(_ message: String) async throws -> LUFSMeter.Reading {
            sheet.setMessage(message)
            sheet.setProgress(0)
            return try await LoudnessScan.measureEdit(rack: rack, asset: asset, audioTrack: track, start: start, end: end,
                                                      cuts: cuts, fadeEnd: fadeEnd, isCancelled: { flag.isSet },
                                                      progress: { [weak sheet] f in sheet?.setProgress(f) })
        }
        let first = try await scan("Measuring loudness (target −14 LUFS)…")
        guard let before = first.integrated else {
            return NormalizePlan(before: nil, gainDB: 0, viaLimiter: false, note: "It was too quiet to measure, so it was left as it is.")
        }
        var gain = target - before
        if rack.limiterActive {
            if gain > 0.5 {
                rack.setLimiter(inputGain: drive + gain)
                let check = try await scan("Checking the new level…")
                rack.setLimiter(inputGain: drive)
                if let after = check.integrated { gain += target - after }
            }
            return NormalizePlan(before: before, gainDB: min(30, max(-30, gain)), viaLimiter: true, note: nil)
        }
        let room = -1 - first.peakDB
        let used = min(gain, room)
        let note: String? = used < gain - 0.05
            ? String(format: "The limiter is off, so it was only raised %.1f dB to keep peaks under −1 dB.", used) : nil
        return NormalizePlan(before: before, gainDB: used, viaLimiter: false, note: note)
    }

    func togglePlayPause() {
        guard !isExporting, let p = player else { return }
        if p.timeControlStatus == .paused {
            // At the end (or outside the trimmed part)? Start over from the trim start, like QuickTime.
            if let range = trimRange {
                let now = toSource(p.currentTime().seconds)
                if now >= range.end - 0.05 || now < range.start - 0.01 {
                    p.seek(to: CMTime(seconds: toComp(range.start), preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            p.play()
        } else {
            playbackPauseGeneration += 1
            hideTail()
            p.pause()
        }
    }

    // MARK: Frame stepping

    /// One exact frame back or forward (pauses first). Uses the real frames in the file,
    /// so it stays exact even on iPhone footage with a variable frame rate.
    func stepFrame(by count: Int) {
        guard !isExporting, let p = player, let item = p.currentItem else { return }
        p.pause()
        if (count > 0 && item.canStepForward) || (count < 0 && item.canStepBackward) {
            item.step(byCount: count)
        } else {
            let now = p.currentTime().seconds
            seekExactly(p, to: now + Double(count) / max(1, TrimBar.frameRate))
        }
    }

    /// Transport › Go to start: the trim start (the clip's start when untrimmed). Keeps playing if it was.
    func goToStart() {
        guard !isExporting, let p = player else { return }
        hideTail()
        let start = trimRange?.start ?? 0
        p.seek(to: CMTime(seconds: toComp(start), preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        trimBar.playhead = start
        trimBar.revealPlayhead()
    }

    /// Transport › Go to end: the last frame before the trim end (pauses first).
    func goToEnd() {
        guard !isExporting, let p = player else { return }
        playbackPauseGeneration += 1
        p.pause()
        let end = trimRange?.end ?? trimBar.duration
        seekExactly(p, to: toComp(end) - 1 / max(1, TrimBar.frameRate))
        trimBar.playhead = max(0, end - 1 / max(1, TrimBar.frameRate))
        trimBar.revealPlayhead()
    }

    /// Jump one second back or forward (pauses first).
    func stepSecond(by direction: Int) {
        guard !isExporting, let p = player else { return }
        p.pause()
        seekExactly(p, to: p.currentTime().seconds + Double(direction))
    }

    private func seekExactly(_ p: AVPlayer, to seconds: Double) {
        hideTail()
        var t = max(0, seconds)
        if let d = p.currentItem?.duration.seconds, d.isFinite { t = min(t, d) }
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Color

    /// Show a change right away while paused (re-renders the current frame).
    ///
    /// 3.5: one refresh at a time, and the latest one always lands. The old version handed
    /// AVFoundation a new composition and hoped; on slower Macs (MacBook Air) a re-render could
    /// be skipped while another was drawing, leaving a moved graphic in its old place. Now each
    /// refresh waits until the compositor really starts a new frame, retries if it doesn't (and
    /// finally re-seeks to the same time, which always draws), and runs once more if anything
    /// changed in the meantime. Problems are logged as "1Shot: refresh: …".
    func refreshFrame() {
        guard let p = player else { return }
        // Playing frames draw themselves. (Was `timeControlStatus == .paused`, which also skipped
        // refreshes while the player was "waiting" — paused, but buffering — so nothing redrew.)
        guard p.rate == 0 else { return }
        refreshStats.requests += 1
        refreshWanted = true
        guard !refreshPending else { return }      // the one in flight runs again when it's done
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.runRefresh(attempt: 1) }
    }

    /// Counts for the "1Shot: refresh:" log line written after each graphic or B-roll drag.
    struct RefreshStats { var requests = 0, renders = 0, retries = 0, reseeks = 0, failures = 0 }
    var refreshStats = RefreshStats()
    private var refreshWanted = false

    /// Logs once the last refresh of a drag has had time to land (or fail).
    func logRefreshStatsSoon(_ what: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.logRefreshStats(what) }
    }

    func logRefreshStats(_ what: String) {
        let s = refreshStats
        NSLog("1Shot: refresh: \(what): \(s.requests) requests, \(s.renders) frames drawn, \(s.retries) retries, \(s.reseeks) re-seeks, \(s.failures) never drew"
              + (player.map { ", player \($0.timeControlStatus.rawValue) rate \($0.rate)" } ?? ""))
        refreshStats = RefreshStats()
    }

    private func runRefresh(attempt: Int) {
        guard let p = player, let item = p.currentItem else { refreshPending = false; return }
        refreshWanted = false
        let before = grade.frameStats.graded
        if attempt <= 2 {
            // Handing the item a fresh copy of the composition makes AVFoundation re-render the paused frame.
            if let copy = videoComposition?.mutableCopy() as? AVVideoComposition { item.videoComposition = copy }
        } else {
            refreshStats.reseeks += 1
            p.seek(to: p.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let started = CACurrentMediaTime()
        func check() {
            guard let p = self.player, p.currentItem === item else { self.refreshPending = false; return }
            if self.grade.frameStats.graded != before {               // a new frame is being drawn
                self.refreshStats.renders += 1
                if self.refreshWanted, p.rate == 0 { self.runRefresh(attempt: 1) } else { self.refreshPending = false }
                return
            }
            if CACurrentMediaTime() - started < 0.25 {                 // give it up to a quarter second
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { check() }
                return
            }
            guard p.rate == 0 else { self.refreshPending = false; return }   // started playing: frames draw anyway
            if attempt < 3 {
                self.refreshStats.retries += 1
                NSLog("1Shot: refresh: no new frame after 0.25 s (try \(attempt)); \(attempt == 1 ? "trying again" : "re-seeking")")
                self.runRefresh(attempt: attempt + 1)
            } else {
                self.refreshStats.failures += 1
                NSLog("1Shot: refresh: gave up, the frame never redrew (player \(p.timeControlStatus.rawValue), item \(item.status.rawValue))")
                self.refreshPending = false
                if self.refreshWanted { self.refreshFrame() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { check() }
    }

    private func updateHistogram() {
        guard currentTab == .visualDesign, !histogramBusy, let output = videoOutput else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        histogramBusy = true
        histogramQueue.async { [weak self] in
            let bins = Self.histogram(of: buffer)
            DispatchQueue.main.async {
                guard let self else { return }
                self.histogramBusy = false
                self.exportDrawer.setHistogram(bins)
            }
        }
    }

    /// Red, green and blue histograms (256 bins each) from a sample of the frame's pixels.
    private static func histogram(of buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, min(width, height) / 270)
        // 768 bins: red 0–255, green 256–511, blue 512–767.
        var bins = [Float](repeating: 0, count: 768)
        var y = 0
        while y < height {
            let row = pixels + y * rowBytes
            var x = 0
            while x < width {
                let px = row + x * 4                       // BGRA
                bins[Int(px[2])] += 1                      // red
                bins[256 + Int(px[1])] += 1                // green
                bins[512 + Int(px[0])] += 1                // blue
                x += step
            }
            y += step
        }
        return bins
    }

    // MARK: Stabilization

    func analyzeStabilization() {
        guard let p = player, let asset = sourceAsset, !isExporting else { NSSound.beep(); return }
        p.pause()
        exportDrawer.setStabilizeProgress(0)
        stabilizer.analyze(asset: asset, progress: { [weak self] fraction in
            self?.exportDrawer.setStabilizeProgress(fraction)
        }, completion: { [weak self] error in
            guard let self else { return }
            self.exportDrawer.setStabilizeProgress(nil)
            self.updateStabilizeUI()
            if let error {
                if let e = error as? Stabilizer.StabilizeError, case .cancelled = e { return }
                self.showAlert("Couldn't analyze the clip", error.localizedDescription)
                return
            }
            NSLog("1Shot: stabilization ready, zoom \(self.stabilizer.zoomPercent ?? 0)%")
            self.refreshFrame()
        })
    }

    // MARK: Fade to black

    var fadeEnabled = false

    /// Keeps the fade lined up with the current end of the video (the trim end).
    func updateFade() {
        let end = fadeEnabled ? trimRange?.end : nil
        if !fadeEnabled { hideTail() }
        grade.fadeOutEnd = end                       // the grade maps player time back to clip time itself
        rack.setFadeOut(end: end.map { toComp($0) })  // sound fades with the picture (the rack plays the edited timeline)
        refreshFrame()
    }

    func updateStabilizeUI() {
        exportDrawer.setStabilizeState(analyzed: stabilizer.isAnalyzed, enabled: stabilizer.enabled,
                                       zoomPercent: stabilizer.zoomPercent)
    }

    // MARK: Projects

    var project: Project? {
        // The project picker shows only while no project is open (3.3.3).
        didSet { DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.updateProjectPicker() } }
    }
    private(set) var currentVideo: URL?
    var pendingRestore: ProjectData?     // settings waiting for the clip to finish loading
    /// The timeline's zoom and scroll to put back after a clip-edge rebuild (3.6.2).
    var pendingTimelineView: (length: Double, start: Double)?
    private var autosaveTimer: Timer?
    private var defaultColor: VisualDesignPanel.Snapshot?
    private var defaultAudio: SoundDesignPanel.Snapshot?

    /// Every color, LUT, stabilize, fade, bypass and audio setting back to how the app starts;
    /// cuts and trim cleared.
    func resetAllSettings() {
        if let defaultColor { exportDrawer.restore(defaultColor) { _ in nil } }
        if let defaultAudio { drawer.restore(defaultAudio) }
        setCuts([])
        setZooms([])
        setBroll([])
        setGraphics([])
        resetTrim()
        stabilizer.reset()
        updateStabilizeUI()
    }

    /// One entry point for anything opened: a project (.1shot file or project folder) or a video.
    func open(_ url: URL) {
        showWindow(nil)          // bring the window back if it was closed
        if url.pathExtension.lowercased() == Project.fileExtension || Self.isProjectFolder(url) {
            openProject(url)
            return
        }
        guard let project, let window, !project.contains(url) else {
            if project == nil || project?.contains(url) == true { load(url) }
            return
        }
        // A video opened while a project is open: add it to the project, or leave the project.
        let alert = NSAlert()
        alert.messageText = "Add “\(url.lastPathComponent)” to “\(project.name)”?"
        alert.informativeText = "It's copied into the project's Media folder and replaces the project's current video. Your color and audio settings stay as they are."
        alert.addButton(withTitle: "Add to Project")
        alert.addButton(withTitle: "Open Without Project")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.addVideoToProject(url)
            case .alertSecondButtonReturn: self.closeProject(); self.load(url)
            default: break
            }
        }
    }

    private static func isProjectFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension.lowercased() == Project.fileExtension }
    }

    /// File › New Project…: name it, make the folder, bring in the open video (if any) or ask for one.
    func newProject(parent: NSWindow? = nil, completion: ((Bool) -> Void)? = nil) {
        if parent == nil { showWindow(nil) }
        guard let window = parent ?? self.window, !isExporting else { NSSound.beep(); completion?(false); return }
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "Name your project. A folder with this name holds the video, LUTs, settings and exports."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "Untitled Project"
        panel.directoryURL = Project.defaultLocation
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion?(false); return }
            guard response == .OK, var folder = panel.url else { completion?(false); return }
            if folder.pathExtension.lowercased() == Project.fileExtension { folder.deletePathExtension() }
            self.saveProject()
            let created: Project
            do { created = try Project.create(at: folder) } catch {
                self.showAlert("Couldn't create the project", error.localizedDescription)
                completion?(false)
                return
            }
            self.project = created
            self.pendingRestore = nil
            RecentFiles.add(created.fileURL)
            NSLog("1Shot: new project at \(created.folder.path)")
            self.updateWindowTitle()
            // A new project starts clean: default settings, land on Assets (empty, ready for
            // drag-and-drop), then offer to pick its first clip(s).
            self.resetAllSettings()
            self.loadVisualGroups(from: created)
            self.assets = []
            self.assetsPanel.setAssets([], selectedID: nil)
            self.selectTab(.assets)
            self.layoutContent()
            completion?(true)
            self.showWindow(nil)
            self.chooseClipsForProject()
        }
    }

    /// File › Open Project…
    func openProjectPanel() {
        showWindow(nil)          // bring the window back if it was closed
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project folder or its .1shot file."
        if let type = UTType(filenameExtension: Project.fileExtension) {
            panel.allowedContentTypes = [type, .folder]
        }
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Project.defaultLocation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func openProject(_ url: URL) {
        guard !isExporting else { NSSound.beep(); return }
        saveProject()
        let opened: Project
        do { opened = try Project.open(url) } catch {
            showAlert("Couldn't open the project", error.localizedDescription)
            return
        }
        project = opened
        RecentFiles.add(opened.fileURL)
        NSLog("1Shot: opened project \(opened.name)")
        // Color and audio settings go back right away; trim and stabilization once the clip has loaded.
        restoreDrawers(from: opened)
        assets = opened.data.assets ?? []
        loadVisualGroups(from: opened)
        assetsPanel.setAssets(assets, selectedID: nil)
        if !assets.isEmpty {
            // Rebuilds the same recipe that was last saved — deterministic, so cuts/zooms/broll/
            // graphics (restored below via pendingRestore) still line up with it.
            pendingRestore = opened.data
            buildAroll(restoring: true)
        } else if let video = opened.videoURL, FileManager.default.fileExists(atPath: video.path) {
            pendingRestore = opened.data
            load(video)
        } else {
            pendingRestore = nil
            updateWindowTitle()
            selectTab(.assets)
            layoutContent()
            chooseClipsForProject()
        }
    }

    /// File › Save (⌘S): saves right away. With no project yet, makes one (like New Project).
    func saveCommand() {
        guard project != nil else { newProject(); return }
        saveProject()
    }

    /// File › Save As… (⇧⌘S): copies the whole project folder under a new name and switches to it.
    /// (The video copy is instant and takes no extra space on the same APFS drive.)
    func saveAsCommand() {
        guard let current = project else { newProject(); return }
        guard let window, !isExporting, pendingRestore == nil else { NSSound.beep(); return }
        saveProject()
        let panel = NSSavePanel()
        panel.title = "Save Project As"
        panel.message = "Saves a copy of the whole project folder under a new name, then switches to the copy."
        panel.prompt = "Save"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = current.name + " copy"
        panel.directoryURL = current.folder.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, var destination = panel.url else { return }
            if destination.pathExtension.lowercased() == Project.fileExtension { destination.deletePathExtension() }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                self.showAlert("Couldn't save the project",
                               "A folder named “\(destination.lastPathComponent)” already exists there. Choose another name.")
                return
            }
            let sheet = BusySheet.make(message: "Saving “\(destination.lastPathComponent)”…")
            window.beginSheet(sheet, completionHandler: nil)
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: Error?
                do {
                    try fm.copyItem(at: current.folder, to: destination)
                    // Rename the settings file to match the new project name.
                    let oldFile = destination.appendingPathComponent(current.fileURL.lastPathComponent)
                    let newFile = destination.appendingPathComponent(destination.lastPathComponent)
                        .appendingPathExtension(Project.fileExtension)
                    if oldFile.standardizedFileURL != newFile.standardizedFileURL {
                        try fm.moveItem(at: oldFile, to: newFile)
                    }
                } catch {
                    failure = error
                    try? fm.removeItem(at: destination)
                }
                DispatchQueue.main.async {
                    window.endSheet(sheet)
                    if let failure {
                        self.showAlert("Couldn't save the project", failure.localizedDescription)
                    } else {
                        NSLog("1Shot: saved project as \(destination.path)")
                        self.openProject(destination)
                    }
                }
            }
        }
    }

    /// File › Create Edit Transcript: every word with its timing, plus the pauses, saved in Transcripts/.
    func createEditTranscript() {
        guard let window, !isExporting else { NSSound.beep(); return }
        guard let project else {
            let alert = NSAlert()
            alert.messageText = "Edit transcripts are saved in a project"
            alert.informativeText = "Create a project for this video first; the transcript goes in its Transcripts folder."
            alert.addButton(withTitle: "New Project…")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.newProject() }
            }
            return
        }
        guard let target = transcriptSource else {
            showAlert("No video in this project yet",
                      "Add a video to the project first (File › Open Video…), or build the A-roll in the Assets tab.")
            return
        }
        guard TranscriptMaker.isAvailable else {
            showAlert("Can't transcribe on this Mac", TranscriptMaker.TranscriptError.needsMacOS26.localizedDescription)
            return
        }
        player?.pause()
        let trim = isTrimmed ? trimRange : nil
        let fps = TrimBar.frameRate
        let sheet = TaskProgressSheet(title: "Creating edit transcript for “\(target.name)”")
        window.beginSheet(sheet.window, completionHandler: nil)
        let started = Date()
        Task { @MainActor in
            do {
                // Pauses are measured after Apple's voice isolator at 100% (road noise removed),
                // whatever the Audio drawer is set to.
                sheet.update("Listening for pauses (voice isolation at 100%)…", 0)
                let isolated = try await TranscriptMaker.isolatedLevels(asset: target.asset) { fraction in
                    DispatchQueue.main.async { sheet.update("Listening for pauses (voice isolation at 100%)…", fraction) }
                }
                let transcript = try await TranscriptMaker.make(asset: target.asset, name: target.name,
                                                                source: target.source, fps: fps, trim: trim,
                                                                isolatedLevels: isolated) { message, fraction in
                    sheet.update(message, fraction)
                }
                let json = try TranscriptMaker.write(transcript, to: project.transcriptsFolder)
                window.endSheet(sheet.window)
                project.data.transcript = project.relativePath(of: json)
                self.saveProject()
                NSLog("1Shot: transcript done in %.0f s — %d words, %d pauses",
                      Date().timeIntervalSince(started), transcript.words.count, transcript.silences.count)
                let alert = NSAlert()
                alert.messageText = "Edit transcript saved"
                alert.informativeText = "\(transcript.words.count) words and \(transcript.silences.count) pauses, in the project's Transcripts folder (.json for Claude, .txt to read)."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                alert.beginSheetModal(for: window) { response in
                    if response == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([json])
                    }
                }
            } catch {
                window.endSheet(sheet.window)
                self.showAlert("Couldn't create the transcript", error.localizedDescription)
            }
        }
    }

    func closeProject() {
        saveProject()
        project = nil
        pendingRestore = nil
        updateWindowTitle()
    }

    /// Offered right after New Project. Cancelling it leaves you on the (already-showing) empty
    /// Assets tab, ready for drag-and-drop or Import… — this is just a shortcut past that.
    private func chooseClipsForProject() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose clip(s) for this project. They're copied into the project's Media folder."
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            self.importAssets(panel.urls)
        }
    }

    /// Copies the clip into Media/ (with a wait sheet for big files) and opens the copy.
    private func addVideoToProject(_ url: URL, keepTrim: Bool = false) {
        guard let project, let window else { return }
        let sheet = BusySheet.make(message: "Copying “\(url.lastPathComponent)” into the project…")
        window.beginSheet(sheet, completionHandler: nil)
        let trim = keepTrim && isTrimmed ? trimRange : nil
        project.importVideo(url) { [weak self] result in
            window.endSheet(sheet)
            guard let self, self.project === project else { return }
            switch result {
            case .failure(let error):
                self.showAlert("Couldn't copy the video into the project", error.localizedDescription)
            case .success(let copy):
                project.data.video = project.relativePath(of: copy)
                project.data.trimStart = trim?.start
                project.data.trimEnd = trim?.end
                if keepTrim { project.data.color = self.exportDrawer.snapshot }   // so stabilization is re-run
                if keepTrim && copy.standardizedFileURL == self.currentVideo?.standardizedFileURL {
                    self.updateWindowTitle()
                } else {
                    // Open the project's own copy, then put the trim back (if we kept one).
                    self.pendingRestore = keepTrim ? project.data : nil
                    self.load(copy)
                }
                self.saveProject()
            }
        }
    }

    /// Writes the project file if anything changed (called every 1.5 s, and on quit).
    func saveProject() {
        guard let project, pendingRestore == nil else { return }
        let color = colorSnapshotForSaving()
        project.data.color = color
        project.data.visualGroups = visualGroups
        project.data.audio = drawer.snapshot
        project.data.cuts = cuts.isEmpty ? nil : cuts
        project.data.suggestedCuts = suggestedCuts.isEmpty ? nil : suggestedCuts
        project.data.suggestedFrom = suggestedFrom
        project.data.suggestedStyleGuide = suggestedStyleGuide
        project.data.zooms = zooms.isEmpty ? nil : zooms
        project.data.broll = broll.isEmpty ? nil : broll
        project.data.graphics = graphics.isEmpty ? nil : graphics
        project.data.volume = volume.isFlat ? nil : volume
        project.data.assets = assets.isEmpty ? nil : assets
        if selectedAssetID == nil, let video = currentVideo, project.contains(video) {
            project.data.video = project.relativePath(of: video)
            if isTrimmed, let range = trimRange {
                project.data.trimStart = range.start
                project.data.trimEnd = range.end
            } else {
                project.data.trimStart = nil
                project.data.trimEnd = nil
            }
        } else if selectedAssetID == nil, sourceAsset is AVMutableComposition {
            project.data.video = nil
            project.data.trimStart = isTrimmed ? trimRange?.start : nil
            project.data.trimEnd = isTrimmed ? trimRange?.end : nil
        }
        for lut in exportDrawer.selectedLUTFiles { project.keepCopy(ofLUT: lut) }
        do { try project.save() } catch {
            NSLog("1Shot: couldn't save project: \(error.localizedDescription)")
        }
    }

    func restoreDrawers(from project: Project) {
        activeVisualGroup = VisualGroup.arollID   // the saved look is the A-roll group's (3.2)
        if let color = project.data.color {
            exportDrawer.restore(color) { name in
                // Prefer the LUT library copy (so the menu shows it); bring the project's copy in if it's missing.
                if let inLibrary = CubeLUT.libraryFiles().first(where: { $0.lastPathComponent == name }) { return inLibrary }
                guard let kept = project.lutCopy(named: name) else { return nil }
                return try? CubeLUT.importToLibrary(kept)
            }
        }
        if let audio = project.data.audio { drawer.restore(audio) }
    }

    /// Runs once the clip's length is known: trim, then re-analyze stabilization if it was on.
    private func finishRestore() {
        guard let data = pendingRestore else { return }
        pendingRestore = nil
        if let start = data.trimStart, let end = data.trimEnd, end - start > 0.05 {
            trimBar.start = start
            trimBar.end = min(end, trimBar.duration)
            trimChanged(start: trimBar.start, end: trimBar.end, movingStart: false, finished: true)
        }
        setCuts(data.cuts ?? [])
        suggestedCuts = data.suggestedCuts ?? []
        suggestedFrom = data.suggestedFrom
        suggestedStyleGuide = data.suggestedStyleGuide
        setZooms(data.zooms ?? [])
        setBroll(data.broll ?? [])
        addApprovedBrollToLibrary()
        setGraphics(data.graphics ?? [])
        setVolume(data.volume ?? VolumeMap())
        if data.color?.stabilize == true { analyzeStabilization() }
        updateWindowTitle()
        if let v = pendingTimelineView {
            pendingTimelineView = nil
            trimBar.restoreView(length: v.length, start: v.start)
        }
    }

    func updateWindowTitle() {
        let clip = currentVideo?.lastPathComponent
        switch (project, clip) {
        case let (p?, c?): window?.title = "\(p.name) — \(c)"
        case let (p?, nil): window?.title = p.name
        case let (nil, c?): window?.title = c
        default: window?.title = "1Shot"
        }
        window?.representedURL = project?.folder ?? currentVideo
    }

    // MARK: Cuts (multi-cut editing)

    private(set) var cuts: [Cut] = []
    /// The cut list as it was suggested (before manual changes), kept for Export Finalized Cut List.
    var suggestedCuts: [Cut] = []
    var suggestedFrom: String?
    var suggestedStyleGuide: String?

    /// Replaces the cut list (normalized to the trim) and shows it on the trim strip.
    func setCuts(_ list: [Cut]) {
        cuts = CutList.normalized(list, trim: trimRange)
        trimBar.cuts = cuts
        trimBar.selectedCut = nil
        trimBar.pendingCutStart = nil
        updateFade()
        rebuildPlaybackForCuts()
        syncBroll()      // B-roll keeps its on-screen length across the new cuts
        syncGraphics()   // so do the motion graphics
        refreshCutsPanel()
    }

    // Playback of the edited timeline: the player plays a composition of the kept pieces, so the
    // preview runs smoothly through every cut. Everything else in the app (trim strip, timecode,
    // transcript, cut lists, export) stays in original-clip time; these convert between the two.

    /// The clip currently loaded — a plain file, or (after Build, in the Assets tab) an
    /// assembled `AVMutableComposition` with no single file of its own.
    var sourceAsset: AVAsset?
    /// The build recipe of the open A-roll (see arollRecipe(_:)); nil when a single file is open.
    var arollRecipe: String?
    var sourceAudioTrack: AVAssetTrack?
    private var sourceSampleRate: Double = 48_000
    private var playbackCuts: [Cut] = [] {   // the cuts the current player item was built with
        didSet { rack.setVolume(volume, cuts: playbackCuts) }   // the sound's clock skips them
    }

    /// A1 split points and section levels (3.7.0), in original-clip seconds.
    private(set) var volume = VolumeMap()

    func setVolume(_ map: VolumeMap) {
        volume = map.normalized
        trimBar.volume = volume
        rack.setVolume(volume, cuts: playbackCuts)
    }
    private var playbackBuild = 0

    /// Original-clip time → player time (a time inside a cut lands where the cut closes).
    func toComp(_ source: Double) -> Double {
        source - CutList.removed(before: source, cuts: playbackCuts)
    }

    /// Player time → original-clip time.
    func toSource(_ comp: Double) -> Double {
        CutList.sourceTime(comp, cuts: playbackCuts)
    }

    /// Like toSource, but a time exactly at a cut maps to where the cut starts (for out points).
    private func toSourceEnd(_ comp: Double) -> Double {
        var t = comp
        for c in playbackCuts {
            if t > c.start + 0.000_5 { t += c.length } else { break }
        }
        return t
    }

    /// Rebuilds what the player plays after the cuts change, keeping the playhead, trim, grade and audio.
    private func rebuildPlaybackForCuts() {
        guard let source = sourceAsset, let p = player else { return }
        let wanted = cuts
        guard wanted != playbackCuts else { return }
        playbackBuild += 1
        let build = playbackBuild
        let here = trimBar.playhead
        let trim = trimRange
        let wasPlaying = p.timeControlStatus == .playing
        let pauseGeneration = playbackPauseGeneration
        Task { @MainActor in
            let duration = (try? await source.load(.duration).seconds) ?? 0
            guard duration > 0, build == self.playbackBuild, self.sourceAsset === source else { return }
            let playAsset: AVAsset
            let audioTrack: AVAssetTrack?
            if wanted.isEmpty {
                playAsset = source
                audioTrack = self.sourceAudioTrack
            } else {
                guard let built = await Self.makeEditedComposition(of: source, cuts: wanted, duration: duration) else { return }
                playAsset = built.asset
                audioTrack = built.audioTrack
            }
            guard build == self.playbackBuild, self.player === p else { return }

            self.playbackCuts = wanted
            let item = AVPlayerItem(asset: playAsset)
            let map: ((Double) -> Double)? = wanted.isEmpty ? nil : { t in CutList.sourceTime(t, cuts: wanted) }
            let composition = self.grade.makeVideoComposition(for: playAsset, mapTime: map, forDisplay: true)
            item.videoComposition = composition
            self.videoComposition = composition
            // Small and fixed, not full frame size — see the comment where this is first set up.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 480,
                kCVPixelBufferHeightKey as String: 270
            ])
            item.add(output)
            self.videoOutput = output
            p.pause()
            p.replaceCurrentItem(with: item)
            self.ensureViewerShowsFrame(p)
            self.rack.attach(to: p, item: item, asset: playAsset, track: audioTrack, sampleRate: self.sourceSampleRate)
            self.watchPlaybackEnds(of: p, item: item)
            if let trim { self.applyTrim(start: trim.start, end: trim.end, to: item, duration: duration) }
            self.updateFade()
            p.seek(to: CMTime(seconds: self.toComp(here), preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                if wasPlaying { DispatchQueue.main.async { [weak self] in
                    guard let self, self.player === p, self.playbackPauseGeneration == pauseGeneration else { return }
                    p.play()
                } }
            }
        }
    }

    /// The clip with the cut pieces taken out (video + audio, rotation kept).
    private static func makeEditedComposition(of source: AVAsset, cuts: [Cut], duration: Double) async
        -> (asset: AVAsset, audioTrack: AVAssetTrack?)? {
        guard let video = try? await source.loadTracks(withMediaType: .video).first else { return nil }
        let audio = try? await source.loadTracks(withMediaType: .audio).first
        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        v.preferredTransform = (try? await video.load(.preferredTransform)) ?? .identity
        let a = audio == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for (s, e) in CutList.keptSegments(start: 0, end: duration, cuts: cuts) {
            let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 60_000),
                                    end: CMTime(seconds: e, preferredTimescale: 60_000))
            do {
                try v.insertTimeRange(range, of: video, at: cursor)
                if let a, let audio { try a.insertTimeRange(range, of: audio, at: cursor) }
            } catch {
                NSLog("1Shot: couldn't build the edited preview: \(error)")
                return nil
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return (comp, a)
    }

    /// X: first press marks where a cut starts (at the playhead), second press makes the cut.
    func markCut() {
        guard player != nil, !isExporting else { NSSound.beep(); return }
        let now = trimBar.playhead
        if let first = trimBar.pendingCutStart {
            trimBar.pendingCutStart = nil
            guard abs(now - first) >= CutList.minimumLength else { NSSound.beep(); return }
            setCuts(cuts + [Cut(start: min(first, now), end: max(first, now), reason: "manual", note: nil)])
        } else {
            trimBar.pendingCutStart = now
        }
    }

    /// Esc while marking a cut.
    func cancelMarkCut() -> Bool {
        guard trimBar.pendingCutStart != nil else { return false }
        trimBar.pendingCutStart = nil
        return true
    }

    /// Delete key (or Edit › Remove Selected Cut): remove the cut you clicked on the trim strip.
    @discardableResult
    func deleteSelectedCut() -> Bool {
        guard let i = trimBar.selectedCut, cuts.indices.contains(i) else { return false }
        removeCut(at: i)
        return true
    }

    var hasSelectedCut: Bool { trimBar.selectedCut.map { cuts.indices.contains($0) } ?? false }

    /// Puts a cut piece back into the video.
    func removeCut(at i: Int) {
        guard cuts.indices.contains(i) else { return }
        var list = cuts
        list.remove(at: i)
        setCuts(list)
    }

    /// A cut's edge was dragged on the trim strip. Keeps the cut selected; the playhead and the
    /// zoomed view stay where they are.
    func resizeCut(at i: Int, to c: Cut) {
        guard cuts.indices.contains(i) else { return }
        guard cuts[i] != c else { trimBar.cuts = cuts; return }   // clicked an edge without moving it
        var list = cuts
        list[i] = c
        setCuts(list)
        if let j = cuts.firstIndex(where: { abs($0.start - c.start) < 0.001 }) { trimBar.selectedCut = j }
    }

    // Timeline zoom (View menu, ⇧Z). The timeline is always visible now (3.0.0).
    func zoomTimeline(_ how: Int) {
        switch how {
        case 1: trimBar.zoomIn()
        case -1: trimBar.zoomOut()
        default: trimBar.zoomToFit()
        }
    }

    /// Plays from 2 seconds before a cut so you can hear how the join sounds.
    func playAcrossCut(at i: Int) {
        guard cuts.indices.contains(i), let p = player else { return }
        let from = max(trimRange?.start ?? 0, cuts[i].start - 2)
        p.seek(to: CMTime(seconds: toComp(from), preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async { p.play() }
        }
    }

    func clearCuts() { setCuts([]) }

    // MARK: Zooms (punch-ins from a zoom list; see the Zooms style guide)

    private(set) var zooms: [ZoomEvent] = []

    func setZooms(_ list: [ZoomEvent]) {
        zooms = ZoomList.normalized(list)
        trimBar.zoomMarks = zooms
        grade.zooms = zooms
        refreshFrame()
        refreshZoomsPanel()
    }

    func moveZoom(at i: Int, to t: Double) {
        guard zooms.indices.contains(i) else { return }
        var list = zooms
        list[i].at = t
        setZooms(list)
    }

    /// nil scale = remove the zoom.
    func changeZoom(at i: Int, scale: Double?) {
        guard zooms.indices.contains(i) else { return }
        var list = zooms
        if let scale {
            list[i].scale = scale
            list[i].type = ZoomList.type(for: scale)
        } else {
            list.remove(at: i)
        }
        setZooms(list)
    }

    /// A zoom added by hand on the timeline. A punch-in gets its own reset 15 s later (see
    /// insertPunchIn); a scale of 1 is just a reset.
    func addZoom(at t: Double, scale: Double) {
        if scale > 1.001 { insertPunchIn(at: t, scale: scale); return }
        setZooms(zooms + [ZoomEvent(at: t, scale: scale, type: ZoomList.type(for: scale), reason: "manual", words: nil)])
    }

    func clearZooms() { setZooms([]) }

    // MARK: Motion graphics (V3)

    private(set) var graphics: [GraphicPlate] = []

    func setGraphics(_ list: [GraphicPlate]) {
        // No face boxes any more (3.2): drop ones saved by older versions so nothing shrinks plates.
        graphics = list.filter { $0.length > 0.1 }.sorted { $0.at < $1.at }.map { p in var p = p; p.avoid = nil; return p }
        syncGraphics()
    }

    func syncGraphics() {
        trimBar.graphicsBlocks = graphics.map { p in
            let end = clipTimeFor(edited: edited(p.at) + p.length)
            let words = [p.title, p.kicker, p.items?.first].compactMap { $0 }.first ?? p.template
            let label = words.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "\\n", with: " ")
            return TrimBar.GraphicsBlock(start: p.at, end: end, label: label, fullScreen: p.isFullScreen)
        }
        grade.graphics.update(plates: graphics, cuts: cuts, red: GraphicsStyle.red)
        refreshFrame()
        refreshGraphicsPanel()
        invalidatePlateBoxes()
    }

    // MARK: B-roll (V2)

    private(set) var broll: [BrollClip] = []

    func edited(_ t: Double) -> Double { t - CutList.removed(before: t, cuts: cuts) }
    func clipTimeFor(edited e: Double) -> Double { CutList.sourceTime(e, cuts: cuts) }

    func brollURL(_ c: BrollClip) -> URL? {
        guard let f = c.file else { return nil }
        if f.hasPrefix("/") { return URL(fileURLWithPath: f) }
        return project?.folder.appendingPathComponent(f)
    }

    func setBroll(_ list: [BrollClip]) {
        broll = list.filter { $0.length > 0.1 }.sorted { $0.at < $1.at }
        syncBroll()
    }

    func syncBroll() {
        trimBar.brollBlocks = broll.map { c in
            let end = clipTimeFor(edited: edited(c.at) + c.length)
            let name = c.file.map { ($0 as NSString).lastPathComponent } ?? c.search ?? c.credit ?? "B-roll"
            return TrimBar.BrollBlock(start: c.at, end: end, label: name, photo: c.isPhoto, pending: c.file == nil)
        }
        let shots: [BrollRenderer.Shot] = broll.compactMap { (c: BrollClip) -> BrollRenderer.Shot? in
            guard let url = brollURL(c) else { return nil }
            var pip: BrollRenderer.PiP? = nil
            if c.showsWhole {
                if c.pipScale != nil || c.pipX != nil || c.pipY != nil || c.rotation != nil {
                    pip = BrollRenderer.PiP(scale: c.pipScale ?? 1, x: c.pipX ?? 960, y: c.pipY ?? 540, rotation: c.rotation ?? 0)
                }
            } else if c.isPiP { pip = BrollRenderer.PiP(scale: c.pipScale ?? 1, x: c.pipX ?? 960, y: c.pipY ?? 540) }
            var shot = BrollRenderer.Shot(url: url, at: c.at, length: c.length, sourceIn: c.sourceIn ?? 0, photo: c.isPhoto)
            shot.zoom = c.zoom ?? 1; shot.panX = c.panX ?? 0; shot.panY = c.panY ?? 0
            shot.push = c.isPhoto && c.push == true
            shot.fit = c.showsWhole
            shot.group = c.visualGroup ?? VisualGroup.brollID
            shot.id = c.id
            shot.pip = pip
            return shot
        }
        grade.broll.update(shots: shots, cuts: cuts)
        updateBrollHandles()
        syncVisualGroups()       // also refreshes the frame
        refreshBrollPanel()
        highlightSelectedClip()
    }

    func editBroll(at i: Int, start s: Double, end e: Double, part: Int) {
        guard broll.indices.contains(i) else { return }
        var c = broll[i]
        switch part {
        case 1:
            let delta = edited(s) - edited(c.at)
            c.at = s
            c.length = max(0.5, c.length - delta)
            if !c.isPhoto { c.sourceIn = max(0, (c.sourceIn ?? 0) + delta) }
        case 2:
            c.length = max(0.5, edited(e) - edited(c.at))
        default:
            c.at = max(0, s)
        }
        var list = broll
        list[i] = c
        setBroll(list)
    }

    func removeBroll(at i: Int) {
        guard broll.indices.contains(i) else { return }
        var list = broll
        list.remove(at: i)
        setBroll(list)
    }

    func clearBroll() { setBroll([]) }

    /// Your own photos/clips: copied into the project's Media/B-roll folder, placed one after another.
    func addBrollFiles(_ urls: [URL], at t: Double) {
        guard player != nil else { NSSound.beep(); return }
        Task { @MainActor in
            var place = self.edited(t)
            var list = self.broll
            for url in urls {
                let photo = BrollList.isPhotoFile(url)
                var length = photo ? BrollList.defaultPhotoLength : BrollList.defaultVideoLength
                if !photo, let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0.3 {
                    length = min(d, BrollList.defaultVideoLength)
                }
                var stored = url.path
                if let project = self.project {
                    let folder = project.mediaFolder.appendingPathComponent("B-roll", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(url.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try? FileManager.default.copyItem(at: url, to: target)
                    }
                    if FileManager.default.fileExists(atPath: target.path) { stored = project.relativePath(of: target) }
                }
                list.append(BrollClip(at: self.clipTimeFor(edited: place), length: length,
                                      kind: photo ? "photo" : "video", file: stored, reason: "manual"))
                place += length
            }
            self.setBroll(list)
        }
    }

    /// B key / Automation › Add B-roll at Playhead…
    func addBrollAtPlayhead() {
        guard let window, player != nil else { NSSound.beep(); return }
        let t = trimBar.playhead
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image]
        panel.message = "Choose photos or video clips to put on V2 at \(TrimBar.format(t))."
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK { self?.addBrollFiles(panel.urls, at: t) }
        }
    }

    /// Automation › Export B-roll Library List…: every video in your Movies folder, for the AI to choose from.
    func exportBrollLibrary() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "B-roll library.json"
        panel.directoryURL = project?.transcriptsFolder
        panel.message = "Lists every video in your Movies folder (name, folder, length, date) so the AI can pick your own B-roll."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let entries = await BrollLibrary.scan()
                struct Out: Encodable { let kind = "1shot-broll-library"; let videos: [BrollLibrary.Entry] }
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                do {
                    try enc.encode(Out(videos: entries)).write(to: url, options: .atomic)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self?.showAlert("Couldn't save the library list", error.localizedDescription)
                }
            }
        }
    }

    func importBrollList() {
        guard let window, player != nil else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.directoryURL = project?.transcriptsFolder
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            self?.applyBrollList(text)
        }
    }

    func pasteBrollList() {
        selectTab(.broll)   // follow along to this step's tab (3.2)
        guard player != nil, let text = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        applyBrollList(text)
    }

    /// Puts the list on V2 (shown faded until downloaded), then downloads every shot into the project.
    private func applyBrollList(_ text: String) {
        do {
            let incoming = try BrollList.parse(text)
            setBroll(broll.filter { $0.reason == "manual" } + incoming)   // keeps your own clips
            fetchPendingBroll()
        } catch {
            showAlert("Couldn't read that B-roll list", error.localizedDescription)
        }
    }

    /// Automation › Download Missing B-roll: retry shots that haven't downloaded yet (e.g. after adding the key).
    func downloadMissingBroll() {
        guard broll.contains(where: { $0.file == nil }) else {
            showAlert("Nothing to download", "Every B-roll shot is already in the project.")
            return
        }
        fetchPendingBroll()
    }

    private func fetchPendingBroll() {
        guard project != nil else {
            showAlert("Open a project first", "Downloaded B-roll is saved in the project's Media/B-roll folder.")
            return
        }
        Task { @MainActor in
            let (got, problems) = await self.downloadPendingBroll()
            var msg = "\(got) shot\(got == 1 ? "" : "s") downloaded to Media/B-roll."
            if !problems.isEmpty { msg += "\n\nNot downloaded:\n" + problems.prefix(6).joined(separator: "\n") }
            self.showAlert("B-roll ready", msg)
        }
    }

    /// Downloads (or copies) every B-roll shot that isn't in the project yet. Used by the menu
    /// commands above and by Claude (MCP), which reports the result instead of showing an alert.
    @MainActor
    /// Back-fill: this project's approved stock B-roll that's already downloaded goes into the shared
    /// B-roll Library too (each clip once). Runs when a project opens and when B-roll is applied.
    func addApprovedBrollToLibrary() {
        guard let project else { return }
        for c in broll where c.pixabayId != nil || c.url != nil || c.isGenerated {
            guard let file = c.file else { continue }
            SharedBrollLibrary.add(project.folder.appendingPathComponent(file), clip: c, project: project.name)
        }
    }

    func downloadPendingBroll() async -> (got: Int, problems: [String]) {
        guard let project else { return (0, ["No project is open."]) }
        let folder = project.mediaFolder.appendingPathComponent("B-roll", isDirectory: true)
        var problems: [String] = []
        var got = 0
        for c in broll where c.file == nil {
            do {
                let saved: URL
                var credit = c.credit
                if let lib = c.libraryFile {
                    // Your own clip: copy it into the project.
                    let src = URL(fileURLWithPath: lib)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(src.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: src, to: target)
                    }
                    saved = target
                } else if let shared = SharedBrollLibrary.item(for: c) {
                    // Already in the shared B-roll Library (approved in some project): clone it, no download.
                    saved = try SharedBrollLibrary.copy(shared.file, into: folder)
                    credit = credit ?? shared.item.credit
                } else if let s = c.url, let u = URL(string: s) {
                    let known = BrollList.isPhotoFile(u) || BrollList.isVideoFile(u)
                    let ext = known ? u.pathExtension.lowercased() : (c.isPhoto ? "jpg" : "mp4")
                    saved = try await BrollFetch.download(u, into: folder,
                                                          base: c.isGenerated ? "Generated \(Int(c.at))" : "Unsplash \(Int(c.at))", ext: ext)
                } else if let pid = c.pixabayId {
                    let (u, line) = try await BrollFetch.pixabayVideo(id: pid)
                    saved = try await BrollFetch.download(u, into: folder, base: "Pixabay \(pid)", ext: "mp4")
                    credit = credit ?? line
                } else if let q = c.search {
                    let (u, line) = try await BrollFetch.pixabayVideo(q)
                    saved = try await BrollFetch.download(u, into: folder, base: "Pixabay \(q)", ext: "mp4")
                    credit = credit ?? line
                } else { continue }
                if let i = broll.firstIndex(where: { $0.id == c.id }) {
                    var list = broll
                    list[i].file = project.relativePath(of: saved)
                    list[i].credit = credit
                    setBroll(list)
                    got += 1
                    // Approved stock goes into the shared B-roll Library for every project (3.1.1).
                    SharedBrollLibrary.add(saved, clip: list[i], project: project.name)
                }
            } catch {
                var label = "shot at " + TrimBar.format(c.at)
                if let pid = c.pixabayId { label = "Pixabay \(pid)" }
                if let u = c.url { label = u }
                if let q = c.search { label = q }
                problems.append(label + ": " + error.localizedDescription)
            }
        }
        saveProject()
        return (got, problems)
    }

    /// Z key: a punch-in at the playhead.
    func insertZoomAtPlayhead() {
        guard player != nil, trimBar.duration > 0 else { NSSound.beep(); return }
        insertPunchIn(at: trimBar.playhead, scale: ZoomList.punchScale)
    }

    /// A punch-in added by hand that goes back to normal 5 s later (ZoomList.defaultHold), or just
    /// before the next zoom or the trim end, whichever comes first. Drag either marker (or edit In/Out
    /// in the Zooms tab) to adjust it.
    func insertPunchIn(at time: Double, scale: Double) {
        guard trimBar.duration > 0 else { NSSound.beep(); return }
        let fps = max(1, TrimBar.frameRate)
        let t = (time * fps).rounded() / fps
        let limit = trimRange?.end ?? trimBar.duration
        var out = min(t + ZoomList.defaultHold, limit)
        if let next = zooms.first(where: { $0.at > t + 0.05 }) { out = min(out, next.at - 0.1) }
        var list = zooms.filter { abs($0.at - t) > 0.05 }
        list.append(ZoomEvent(at: t, scale: scale, type: ZoomList.type(for: scale), reason: "manual", words: nil))
        if out > t + 0.5 {
            list.append(ZoomEvent(at: (out * fps).rounded() / fps, scale: 1, type: "reset", reason: "manual", words: nil))
        }
        setZooms(list)
    }

    /// View › Show Cuts as Clips: DaVinci-style timeline (kept parts end to end) or the whole recording.
    var timelineShowsClips: Bool { trimBar.clipView }
    func toggleTimelineClips() {
        trimBar.clipView.toggle()
        UserDefaults.standard.set(trimBar.clipView, forKey: "TimelineShowsClips")
    }

    /// Automation › Import Zoom List…: a zoom list from Claude or another AI (Zooms style guide format).
    func importZoomList() {
        guard let window, player != nil else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.directoryURL = project?.transcriptsFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            self.applyZoomList(text)
        }
    }

    /// Automation › Paste Zoom List: the same, from the clipboard.
    func pasteZoomList() {
        selectTab(.zooms)   // follow along to this step's tab (3.2)
        guard player != nil, let text = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        applyZoomList(text)
    }

    private func applyZoomList(_ text: String) {
        do {
            let list = try ZoomList.parse(text)
            setZooms(list)
            let punches = zooms.filter { $0.scale > 1.001 }.count
            showAlert("Zoom list applied",
                      "\(punches) zoom\(punches == 1 ? "" : "s") in. This replaced any zooms you had. " +
                      "Drag a marker above the timeline to move it; right-click it to change or remove it.")
        } catch {
            showAlert("Couldn't read that zoom list", error.localizedDescription)
        }
    }

    /// Edit › Cut Pauses from Transcript: shortens every pause over 0.6 s to 0.35 s
    /// (the Default style guide), keeping any other cuts you already have.
    func cutPausesFromTranscript() {
        selectTab(.cuts)   // follow along to this step's tab (3.2)
        guard let transcript = currentTranscript()?.transcript else {
            if transcriptIsOutOfDate {
                showAlert("The edit transcript is out of date",
                          "It was made before the A-roll was rebuilt (or for another clip), so its times no longer " +
                          "line up. Choose Automation › Create Edit Transcript again.")
            } else {
                showAlert("No edit transcript yet", "Choose Automation › Create Edit Transcript first; pauses come from it.")
            }
            return
        }
        let pauses = CutList.pauseCuts(from: transcript, trim: trimRange)
        let others = cuts.filter { $0.reason != "pause" }
        setCuts(others + pauses)
        suggestedCuts = cuts
        suggestedFrom = "Automation › Cut Pauses from Transcript"
        suggestedStyleGuide = "app pause rule (keep 0.35 s, cuts of 1 s or more)"
        showAlert("Pauses tightened",
                  "\(pauses.count) pauses shortened to 0.35 s, removing \(TrimBar.format(CutList.totalLength(pauses))). " +
                  "Play it back to check; click a red cut and press Delete to keep that pause.")
    }

    /// Edit › Paste Cut List: a cut list from Claude or another AI (style-guide format), from the clipboard.
    func pasteCutList() {
        selectTab(.cuts)   // follow along to this step's tab (3.2)
        guard player != nil else { NSSound.beep(); return }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            showAlert("Nothing to paste", "Copy the AI's cut list (the JSON) first.")
            return
        }
        applyCutList(text, from: "Pasted from the clipboard")
    }

    /// Edit › Import Cut List…: the same, from a .json or .txt file.
    func importCutList() {
        guard let window, player != nil else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.directoryURL = project?.transcriptsFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            self.applyCutList(text, from: "Imported \(url.lastPathComponent)")
        }
    }

    private func applyCutList(_ text: String, from source: String) {
        do {
            let (list, reviewCount) = try CutList.parse(text)
            setCuts(list)
            suggestedCuts = cuts
            suggestedFrom = source
            suggestedStyleGuide = Self.styleGuideName(in: text)
            var message = "\(cuts.count) cuts, removing \(TrimBar.format(CutList.totalLength(cuts))). This replaced any cuts you had."
            if reviewCount > 0 { message += " The AI also flagged \(reviewCount) spot\(reviewCount == 1 ? "" : "s") to review — see its notes." }
            showAlert("Cut list applied", message)
        } catch {
            showAlert("Couldn't read that cut list", error.localizedDescription)
        }
    }

    /// The "styleGuide" named in a cut list, if it has one.
    private static func styleGuideName(in text: String) -> String? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let data = String(text[a...b]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["styleGuide"] as? String
    }

    /// Automation › Export Finalized Cut List…: your cuts as they are now, next to the suggested list and
    /// what you changed, so an AI can compare and tune the style guide.
    func exportCutList() {
        guard let window, player != nil, trimBar.duration > 0 else { NSSound.beep(); return }
        let clip = (sourceAsset as? AVURLAsset)?.url.lastPathComponent ?? currentVideo?.lastPathComponent
            ?? project?.name ?? "Clip"
        let base = (clip as NSString).deletingPathExtension + " cut list (edited)"
        let fm = FileManager.default
        let folder = project?.transcriptsFolder
            ?? fm.urls(for: .moviesDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = base + ".json"
        var n = 2
        while fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).json"
            n += 1
        }
        let report = EditedCutList(clip: clip, fps: TrimBar.frameRate,
                                   trim: trimRange ?? (start: 0, end: trimBar.duration),
                                   styleGuide: suggestedStyleGuide, suggestedFrom: suggestedFrom,
                                   suggested: suggestedCuts, edited: cuts)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        panel.message = suggestedCuts.isEmpty
            ? "No suggested cut list to compare with — this saves your cuts only."
            : "Saves your cuts, the suggested cuts, and what you changed (\(report.summary.resized) resized, " +
              "\(report.summary.removed) removed, \(report.summary.added) added)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            do {
                try encoder.encode(report).write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self?.showAlert("Couldn't save the cut list", error.localizedDescription)
            }
        }
    }

    /// File › Export Timeline for DaVinci…: the trimmed, cut edit as an FCPXML timeline that points at
    /// the original video. Import it in DaVinci Resolve with File › Import › Timeline.
    func exportDavinciTimeline() {
        guard let window, player != nil, trimBar.duration > 0 else { NSSound.beep(); return }
        guard let video = (sourceAsset as? AVURLAsset)?.url else {
            showAlert("Can't export for DaVinci yet",
                      "This video was built from multiple clips in the Assets tab. FCPXML export for a " +
                      "multi-clip A-roll isn't supported yet — only for a single opened video.")
            return
        }
        let base = video.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let folder = project?.exportsFolder ?? video.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = "\(base) (DaVinci).fcpxml"
        var n = 2
        while fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) (DaVinci) \(n).fcpxml"
            n += 1
        }
        let trim = trimRange ?? (start: 0, end: trimBar.duration)
        let cutList = cuts
        let fps = TrimBar.frameRate
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        panel.message = "A timeline for DaVinci Resolve with your trim and \(cutList.count) cut\(cutList.count == 1 ? "" : "s"). " +
            "It points at the original video, so keep the video where it is."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let xml = try await DavinciExport.fcpxml(video: video, fps: fps, trim: trim, cuts: cutList,
                                                             timelineName: "\(base) (1Shot cut)")
                    try xml.write(to: url, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self?.showAlert("Couldn't export the timeline", error.localizedDescription)
                }
            }
        }
    }

    // MARK: LUTs

    private func useLUT(at url: URL?, slot: VisualDesignPanel.LUTSlot) {
        let set: (CubeLUT?) -> Void = { [weak self] lut in
            self?.lutChangedInPanel(lut, slot: slot)   // the group being edited (3.2)
        }
        guard let url else {
            set(nil)
            refreshFrame()
            return
        }
        do {
            set(try CubeLUT.cached(url: url))
            NSLog("1Shot: \(slot == .camera ? "camera" : "creative") LUT \(url.lastPathComponent) applied")
        } catch {
            set(nil)
            exportDrawer.clearLUTSelection(slot)
            showAlert("Couldn't use that LUT", error.localizedDescription)
        }
        refreshFrame()
    }

    private func loadLUT(for slot: VisualDesignPanel.LUTSlot) {
        guard let window else { return }
        let panel = NSOpenPanel()
        if let cube = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cube] }
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more .cube LUT files"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            var lastImported: URL?
            var problems: [String] = []
            for url in panel.urls {
                do { lastImported = try CubeLUT.importToLibrary(url) }
                catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            self.exportDrawer.rebuildLUTMenu(select: lastImported, slot: slot)
            if let lastImported { self.useLUT(at: lastImported, slot: slot) }
            if !problems.isEmpty {
                self.showAlert("Some LUTs couldn't be loaded", problems.joined(separator: "\n"))
            }
        }
    }

    func toggleEyedropper() {
        if eyedropperView.superview != nil { endEyedropper(); return }
        guard player != nil else { exportDrawer.setEyedropperActive(false); NSSound.beep(); return }
        player?.pause()
        eyedropperView.frame = playerView.frame
        container.addSubview(eyedropperView, positioned: .above, relativeTo: playerView)
        window?.makeFirstResponder(eyedropperView)
        window?.invalidateCursorRects(for: eyedropperView)
        exportDrawer.setEyedropperActive(true)
    }

    private func endEyedropper() {
        eyedropperView.removeFromSuperview()
        exportDrawer.setEyedropperActive(false)
        window?.makeFirstResponder(playerView)
    }

    /// Sample the ORIGINAL frame (before any color changes) where you clicked,
    /// then set Color + Tint so that spot becomes neutral.
    private func pickWhite(at point: NSPoint) {
        endEyedropper()
        guard let p = player, let asset = sourceAsset else { return }
        let videoRect = playerView.videoBounds
        guard videoRect.width > 0, videoRect.contains(point) else { NSSound.beep(); return }
        let nx = (point.x - videoRect.minX) / videoRect.width
        let nyFromTop = playerView.isFlipped ? (point.y - videoRect.minY) / videoRect.height
                                             : (videoRect.maxY - point.y) / videoRect.height

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Measure the player's own frame (stabilized, before white balance and LUT), not a separate raw decode.
        generator.videoComposition = grade.makeEyedropperComposition(for: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: toSource(p.currentTime().seconds), preferredTimescale: 60_000)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, image, _, result, _ in
            guard result == .succeeded, let image,
                  let rgb = Self.averageColor(of: image, atX: nx, yFromTop: nyFromTop) else { return }
            let solved = ColorGrade.solveWhiteBalance(red: rgb.r, green: rgb.g, blue: rgb.b, lut: self?.grade.lut)
            NSLog("1Shot: eyedropper picked r=%.3f g=%.3f b=%.3f → Color %.0f, Tint %.0f",
                  rgb.r, rgb.g, rgb.b, solved.temperature, solved.tint)
            DispatchQueue.main.async {
                guard let self else { return }
                _ = generator   // keep the generator alive until it's done
                // Sets Color + Tint (and un-bypasses them); other controls keep their state.
                self.exportDrawer.applyWhiteBalance(temperature: solved.temperature, tint: solved.tint)
            }
        }
    }

    /// Average of a small patch around a point (Rec. 709 video values, 0…1).
    private static func averageColor(of image: CGImage, atX nx: CGFloat, yFromTop ny: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        // About 1% of the frame width (at least 9 px), so a printed line or noise barely moves the average.
        let patch = max(9, image.width / 100)
        let cx = Int(nx * CGFloat(image.width)), cy = Int(ny * CGFloat(image.height))
        let rect = CGRect(x: max(0, min(image.width - patch, cx - patch / 2)),
                          y: max(0, min(image.height - patch, cy - patch / 2)),
                          width: patch, height: patch)
        guard let crop = image.cropping(to: rect),
              let space = CGColorSpace(name: CGColorSpace.itur_709),
              let ctx = CGContext(data: nil, width: patch, height: patch, bitsPerComponent: 8, bytesPerRow: patch * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: patch, height: patch))
        let px = data.bindMemory(to: UInt8.self, capacity: patch * patch * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(patch * patch) {
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2])
        }
        let n = Double(patch * patch) * 255
        return (CGFloat(r / n), CGFloat(g / n), CGFloat(b / n))
    }

    // MARK: Trim

    /// The part of the video that plays and exports (whole video if untrimmed).
    var trimRange: (start: Double, end: Double)? {
        // The player's in/out points are on the edited timeline; report them as original-clip times.
        guard let item = player?.currentItem else { return nil }
        let duration = trimBar.duration > 0 ? trimBar.duration : item.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let rev = item.reversePlaybackEndTime
        let fwd = item.forwardPlaybackEndTime
        let start = (rev.isValid && rev.isNumeric) ? toSource(rev.seconds) : 0
        let end = (fwd.isValid && fwd.isNumeric) ? toSourceEnd(fwd.seconds) : duration
        return (max(0, start), min(duration, end))
    }

    var isTrimmed: Bool {
        guard let item = player?.currentItem else { return false }
        return item.reversePlaybackEndTime.isValid || item.forwardPlaybackEndTime.isValid
    }

    /// FCPXML export needs one literal source file; a composition built from several Assets-tab
    /// clips doesn't have one.
    var canExportDavinciTimeline: Bool { sourceAsset is AVURLAsset }

    /// A handle on the trim strip moved: apply it and show that frame. In the Assets tab, while
    /// reviewing one source clip, this is that clip's own in/out (saved to its AssetEntry) rather
    /// than the whole project's trim.
    func trimChanged(start: Double, end: Double, movingStart: Bool, finished: Bool) {
        guard !isExporting, let p = player, let item = p.currentItem else { return }
        p.pause()
        let duration = trimBar.duration
        applyTrim(start: start, end: end, to: item, duration: duration)
        if currentTab == .assets, let id = selectedAssetID, let idx = assets.firstIndex(where: { $0.id == id }) {
            assets[idx].inPoint = start
            assets[idx].outPoint = end
            assetsPanel.trimPanel.update(start: start, end: end)
            assetsPanel.setAssets(assets, selectedID: selectedAssetID)
        }
        // Preview the frame under the handle; when you let go of the end handle, park at the start.
        if finished { updateFade() }
        let target = (movingStart || finished) ? start : end
        // Plain seek, as in 3.8.4: one-seek-at-a-time (chaseSeek) is used for scrubbing only for now.
        p.seek(to: CMTime(seconds: toComp(target), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Scrubbing (one seek at a time) — from PR #1

    private var chaseTarget: CMTime?
    private var chaseThen: (() -> Void)?
    private weak var chasePlayer: AVPlayer?      // the player with a scrub seek in flight (nil = none)

    /// Seeks exactly to `time` for a playhead scrub. Only one seek runs at a time:
    /// while it does, the newest place asked for is remembered and sought as soon as it lands.
    /// A new exact seek on every mouse event instead cancels the one before it, so on heavy
    /// footage the picture doesn't update until the mouse stops.
    /// `then` runs after the seek to `time` finishes, unless a newer request replaced it.
    func chaseSeek(to time: CMTime, then: (() -> Void)? = nil) {
        chaseTarget = time
        chaseThen = then
        if let busy = chasePlayer, busy === player { return }
        runChaseSeek()
    }

    private func runChaseSeek() {
        guard let p = player, let target = chaseTarget else {
            chasePlayer = nil; chaseTarget = nil; chaseThen = nil      // nothing to seek: don't leave a target waiting
            return
        }
        let then = chaseThen
        chaseTarget = nil
        chaseThen = nil
        chasePlayer = p
        p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak p] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.chasePlayer === p { self.chasePlayer = nil }
                if self.chaseTarget != nil { self.runChaseSeek() }      // the mouse moved on meanwhile
                else if finished { then?() }
            }
        }
    }

    /// Sets the player's in/out points (original-clip times → edited timeline).
    private func applyTrim(start: Double, end: Double, to item: AVPlayerItem, duration: Double) {
        item.reversePlaybackEndTime = start > 0.001 ? CMTime(seconds: toComp(start), preferredTimescale: 600) : .invalid
        item.forwardPlaybackEndTime = end < duration - 0.001 ? CMTime(seconds: toComp(end), preferredTimescale: 600) : .invalid
    }

    func resetTrim() {
        guard !isExporting, player?.currentItem != nil else { return }
        trimBar.start = 0
        trimBar.end = trimBar.duration
        trimChanged(start: 0, end: trimBar.duration, movingStart: false, finished: true)
    }

    /// From a trim panel's edited field or "At Playhead" button (the project trim, or in the
    /// Assets tab the selected clip's in/out — trimChanged saves to whichever is active).
    func setTrimFromPanel(start: Double?, end: Double?) {
        guard trimBar.duration > 0 else { return }
        let s = max(0, min(start ?? trimBar.start, trimBar.duration))
        let e = max(s + 0.05, min(end ?? trimBar.end, trimBar.duration))
        trimBar.start = s
        trimBar.end = e
        trimChanged(start: s, end: e, movingStart: false, finished: true)
    }

    // MARK: Assets tab (3.1.0)

    /// A row was clicked: load that one source clip into the viewer for review/trim, exactly
    /// like File > Open Video… — just remembering which asset it is so dragging the trim
    /// handles saves back to it instead of (or on top of) the project's own trim.
    func selectAsset(_ id: UUID) {
        guard let asset = assets.first(where: { $0.id == id }), let project else { return }
        load(project.folder.appendingPathComponent(asset.path), assetID: id)
    }

    /// Import button or a drag-and-drop onto the Assets panel: copy each file into the project
    /// (reusing the same Media/ import used for the classic single-clip flow), then probe it.
    func importAssets(_ urls: [URL]) {
        guard let project else {
            showAlert("Create a project first", "Assets need a project to import clips into — use File > New Project… first.")
            return
        }
        for url in urls {
            project.importVideo(url) { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    if case .success(let destination) = result {
                        let entry = await AssetEntry.make(path: project.relativePath(of: destination), url: destination)
                        self.assets.append(entry)
                        self.assets.sort { $0.sortDate < $1.sortDate }
                        self.assetsPanel.setAssets(self.assets, selectedID: self.selectedAssetID)
                    }
                }
            }
        }
    }

    func toggleAssetRejected(_ id: UUID) {
        guard let idx = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[idx].rejected.toggle()
        assetsPanel.setAssets(assets, selectedID: selectedAssetID)
    }

    /// Drag-to-reorder or Move Up/Down in the Assets list (3.6.1). The list order is the A-roll
    /// order: every sort in the app is by sortDate, so this hands the clips' existing dates back
    /// out in the new order (nudged apart if two were equal). Nothing is rebuilt until Build A-roll.
    func reorderAssets(_ order: [UUID]) {
        var byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var updated: [AssetEntry] = order.compactMap { byID.removeValue(forKey: $0) }
        updated += assets.filter { byID[$0.id] != nil }   // anything the caller left out stays at the end
        guard updated.map(\.id) != assets.map(\.id) else { return }
        var dates = assets.map(\.sortDate).sorted()
        for i in dates.indices.dropFirst() where dates[i] <= dates[i - 1] {
            dates[i] = dates[i - 1].addingTimeInterval(0.001)
        }
        for i in updated.indices { updated[i].sortDate = dates[i] }
        assets = updated
        assetsPanel.setAssets(assets, selectedID: selectedAssetID)
        saveProject()
    }

    func removeAsset(_ id: UUID) {
        assets.removeAll { $0.id == id }
        if selectedAssetID == id {
            selectedAssetID = nil
            trimBar.showFullAsset = false
        }
        assetsPanel.setAssets(assets, selectedID: selectedAssetID)
    }

    /// Assembles every non-rejected asset (in Assets-list order, each trimmed to its own in/out) into
    /// one AVMutableComposition and loads it as the working clip. Rebuildable: calling this again
    /// regenerates the composition from the current recipe. If that changes the total length,
    /// Cuts/Zooms/B-roll/Graphics are measured against the *old* timeline and no longer line up,
    /// so this asks before clearing them (Visual Design/Sound Design settings aren't position-
    /// dependent and are kept either way).
    func buildAroll(restoring: Bool = false) {
        guard let project else { NSSound.beep(); return }
        let included = assets.filter { !$0.rejected }.sorted { $0.sortDate < $1.sortDate }
        guard !included.isEmpty else {
            showAlert("Nothing to build", "Import at least one clip, and make sure it isn't rejected.")
            return
        }
        let hadPreviousBuild = !restoring && selectedAssetID == nil && sourceAsset is AVMutableComposition
        let previousDuration = trimBar.duration
        Task { @MainActor in
            guard let comp = await Self.assembleComposition(assets: included, in: project) else {
                self.showAlert("Couldn't build the A-roll", "One of the clips couldn't be read.")
                return
            }
            let recipeChanged = self.arollRecipe != nil && self.arollRecipe != Self.arollRecipe(included)
            let hasEdits = !self.cuts.isEmpty || !self.zooms.isEmpty || !self.broll.isEmpty || !self.graphics.isEmpty
            if hadPreviousBuild, abs(comp.duration.seconds - previousDuration) > 0.05 || (recipeChanged && hasEdits) {
                let alert = NSAlert()
                alert.messageText = "Rebuild the A-roll?"
                alert.informativeText = "The clips or their order changed, so Cuts, Zooms, B-roll and Graphics " +
                    "will be cleared — they were positioned against the old timeline. Visual Design and " +
                    "Sound Design settings are kept."
                alert.addButton(withTitle: "Rebuild")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.clearCuts()
                self.clearZooms()
                self.clearBroll()
                self.setGraphics([])
                self.setVolume(VolumeMap())
            }
            guard self.project === project else { return }
            if !restoring {
                self.saveProject()
                project.data.trimStart = nil
                project.data.trimEnd = nil
                project.data.video = nil
            }
            var cursor = 0.0
            self.trimBar.sourceClipBoundaries = included.dropLast().map { entry in
                cursor += entry.outPoint - entry.inPoint
                return cursor
            }
            self.trimBar.sourceClipCount = included.count
            self.arollPieces = self.makeArollPieces(included, in: project)
            self.loadComposition(comp)
            self.arollRecipe = Self.arollRecipe(included)
            if !restoring { self.selectTab(.visualDesign) }
        }
    }

    /// Ripple-trim a source clip and rebuild V1; in/out remain bounded by the original media.
    private func resizeSourceClip(index: Int, left: Bool, delta: Double) {
        guard !isExporting, let project, selectedAssetID == nil, sourceAsset is AVMutableComposition else { return }
        let included = assets.filter { !$0.rejected }.sorted { $0.sortDate < $1.sortDate }
        guard included.indices.contains(index), let assetIndex = assets.firstIndex(where: { $0.id == included[index].id }) else { return }
        var updated = assets
        var entry = updated[assetIndex]
        if left { entry.inPoint = min(entry.outPoint - 0.05, max(0, entry.inPoint + delta)) }
        else { entry.outPoint = max(entry.inPoint + 0.05, min(entry.duration, entry.outPoint + delta)) }
        guard abs(entry.inPoint - updated[assetIndex].inPoint) > 0.001 ||
              abs(entry.outPoint - updated[assetIndex].outPoint) > 0.001 else { return }
        // Ripple (3.6.2): everything after the edge slides with it, so cuts, zooms, B-roll, graphics
        // and the timeline trim stay on the same words. Only what falls in a removed stretch moves
        // to the edit point (a cut there shrinks or goes).
        var clipStart = 0.0
        for e in included.prefix(index) { clipStart += e.outPoint - e.inPoint }
        let clipEnd = clipStart + (included[index].outPoint - included[index].inPoint)
        let applied = left ? entry.inPoint - included[index].inPoint : entry.outPoint - included[index].outPoint
        let pivot: Double, removed: Double, shift: Double
        if left {
            pivot = clipStart; removed = max(0, applied); shift = -applied
        } else {
            pivot = clipEnd + min(0, applied); removed = max(0, -applied); shift = applied
        }
        let ripple: (Double) -> Double = { t in
            t < pivot ? t : (t >= pivot + removed ? t + shift : pivot)
        }
        updated[assetIndex] = entry
        applyAssetTrims(updated, ripple: ripple) { [weak self] ok in
            if !ok { self?.showAlert("Couldn't resize the clip", "The source clips couldn't be assembled. No changes were made.") }
        }
    }

    /// Saves new in/out points for the source clips and rebuilds V1 from them (3.4.0). The timeline
    /// trim, cuts, zooms, B-roll and graphics are cleared: they were placed against the old timeline.
    /// `done(false)` = the clips couldn't be assembled and nothing changed.
    func applyAssetTrims(_ updated: [AssetEntry], ripple: ((Double) -> Double)? = nil, done: @escaping (Bool) -> Void) {
        guard let project else { done(false); return }
        // With a ripple, the current edits are carried over onto the new timeline instead of cleared.
        var kept: (cuts: [Cut], zooms: [ZoomEvent], broll: [BrollClip], graphics: [GraphicPlate],
                   trim: (Double, Double)?)? = nil
        var volumeKept = VolumeMap()
        if let f = ripple {
            let cutsNow = cuts.map { Cut(start: f($0.start), end: f($0.end), reason: $0.reason, note: $0.note) }
                .filter { $0.length >= CutList.minimumLength }
            let zoomsNow = zooms.map { z -> ZoomEvent in var z = z; z.at = f(z.at); return z }
            let brollNow = broll.map { b -> BrollClip in var b = b; b.at = f(b.at); return b }
            let graphicsNow = graphics.map { g -> GraphicPlate in
                var g = g; g.at = f(g.at); g.builds = g.builds?.map(f); return g
            }
            let trimNow = isTrimmed ? trimRange.map { (f($0.start), f($0.end)) } : nil
            volumeKept = volume.rippled(f)
            kept = (cutsNow, zoomsNow, brollNow, graphicsNow, trimNow)
        }
        let newIncluded = updated.filter { !$0.rejected }.sorted { $0.sortDate < $1.sortDate }
        Task { @MainActor in
            guard let comp = await Self.assembleComposition(assets: newIncluded, in: project) else {
                done(false)
                return
            }
            guard self.project === project else { done(false); return }
            self.clearCuts()
            self.clearZooms()
            self.clearBroll()
            self.setGraphics([])
            self.setVolume(VolumeMap())
            self.assets = updated
            self.assetsPanel.setAssets(updated, selectedID: nil)
            project.data.video = nil
            project.data.trimStart = nil
            project.data.trimEnd = nil
            project.data.cuts = nil
            project.data.zooms = nil
            project.data.broll = nil
            project.data.graphics = nil
            project.data.volume = nil
            if let kept {
                project.data.volume = volumeKept.isFlat ? nil : volumeKept
                project.data.cuts = kept.cuts.isEmpty ? nil : kept.cuts
                project.data.zooms = kept.zooms.isEmpty ? nil : kept.zooms
                project.data.broll = kept.broll.isEmpty ? nil : kept.broll
                project.data.graphics = kept.graphics.isEmpty ? nil : kept.graphics
                project.data.trimStart = kept.trim?.0
                project.data.trimEnd = kept.trim?.1
                project.data.suggestedCuts = nil   // made from the transcript, which no longer lines up
                self.suggestedCuts = []
                // Put them back once the rebuilt A-roll has loaded (same path as opening a project),
                // with the timeline zoomed and scrolled as it was.
                self.pendingRestore = project.data
                self.pendingTimelineView = self.trimBar.viewState
            }
            var cursor = 0.0
            self.trimBar.sourceClipBoundaries = newIncluded.dropLast().map { item in
                cursor += item.outPoint - item.inPoint
                return cursor
            }
            self.trimBar.sourceClipCount = newIncluded.count
            self.arollPieces = self.makeArollPieces(newIncluded, in: project)
            self.loadComposition(comp)
            self.arollRecipe = Self.arollRecipe(newIncluded)
            // Persist the asset trims immediately; the player is loaded asynchronously.
            project.data.assets = updated
            do { try project.save() } catch { self.showAlert("Couldn't save the project", error.localizedDescription) }
            done(true)
        }
    }

    /// Identifies one build of the A-roll: which clips, in order, each with its in/out. An edit
    /// transcript made from a build stores this, so a rebuild that changes it marks the transcript
    /// out of date (its times would no longer line up). 3.1.1.
    static func arollRecipe(_ included: [AssetEntry]) -> String {
        included.map { "\($0.id.uuidString)@\(String(format: "%.4f", $0.inPoint))-\(String(format: "%.4f", $0.outPoint))" }
            .joined(separator: ",")
    }

    /// What an edit transcript listens to right now: the open project clip, or the assembled
    /// A-roll (3.1.1). nil when neither is open.
    var transcriptSource: (asset: AVAsset, name: String, source: String?)? {
        guard let project else { return nil }
        if let video = currentVideo {
            guard project.contains(video) else { return nil }
            return (asset: AVURLAsset(url: video), name: video.lastPathComponent, source: nil)
        }
        guard let comp = sourceAsset as? AVComposition, let recipe = arollRecipe,
              let frozen = comp.copy() as? AVComposition else { return nil }   // an unchanging copy for the background readers
        return (asset: frozen, name: "\(project.name) (A-roll)", source: recipe)
    }

    /// The project's edit transcript, but only if it belongs to what's open now — the same clip,
    /// or the same build of the A-roll. Anything else would put cuts in the wrong places.
    func currentTranscript() -> (transcript: EditTranscript, url: URL)? {
        guard let project, let rel = project.data.transcript else { return nil }
        let url = project.folder.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url),
              let t = try? JSONDecoder().decode(EditTranscript.self, from: data) else { return nil }
        if currentVideo == nil {
            guard sourceAsset != nil, let recipe = arollRecipe, t.source == recipe else { return nil }
        } else if t.source != nil {
            return nil      // an A-roll transcript, but a single clip is open
        }
        return (transcript: t, url: url)
    }

    /// True when the project has a transcript file, but it was made for something else
    /// (an earlier A-roll build, or a different clip).
    var transcriptIsOutOfDate: Bool { project?.data.transcript != nil && currentTranscript() == nil }

    /// Mirrors makeEditedComposition's segment-insert loop, but across N different source
    /// files (each trimmed to its own in/out) instead of N kept segments of one file.
    private static func assembleComposition(assets: [AssetEntry], in project: Project) async -> AVMutableComposition? {
        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for entry in assets {
            let url = project.folder.appendingPathComponent(entry.path)
            let asset = AVURLAsset(url: url)
            guard let video = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
            if cursor == .zero {
                v.preferredTransform = (try? await video.load(.preferredTransform)) ?? .identity
            }
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            let range = CMTimeRange(start: CMTime(seconds: entry.inPoint, preferredTimescale: 60_000),
                                    end: CMTime(seconds: max(entry.inPoint, entry.outPoint), preferredTimescale: 60_000))
            guard range.duration.seconds > 0.01 else { return nil }
            do {
                try v.insertTimeRange(range, of: video, at: cursor)
                if let a, let audio { try a.insertTimeRange(range, of: audio, at: cursor) }
            } catch {
                NSLog("1Shot: couldn't insert \(entry.path) into the A-roll: \(error)")
                return nil
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return cursor.seconds > 0.01 ? comp : nil
    }

    /// Frames for the zoomed filmstrip, fetched as the strip asks for them.
    ///
    /// One generator per clip, reused for every request (3.1.1). Each new AVAssetImageGenerator opens
    /// its own hardware decoders (one set per source file of an assembled A-roll), and cancelled ones
    /// don't hand them back right away — making a fresh one on every redraw while the timeline was
    /// being resized ran the system's video decoder service up to ~10 GB and froze the Mac.
    /// Requests are also gathered for a moment, so a resize drag asks once when it pauses, not every frame.
    private var zoomThumbGenerator: AVAssetImageGenerator?
    private var zoomThumbTask: Task<Void, Never>?
    private var filmstripTask: Task<Void, Never>?

    /// One clip of an assembled A-roll: where it sits on the timeline and where that part
    /// comes from in its own file. Timeline thumbnails are taken from the file itself (3.3.1):
    /// AVAssetImageGenerator can't decode across the joins of an A-roll made of HEVC clips
    /// ("Cannot Decode" for everything after the first clip), though playback is fine.
    struct ArollPiece {
        let start: Double          // on the A-roll
        let end: Double
        let inPoint: Double        // in the clip file
        let asset: AVURLAsset
    }
    var arollPieces: [ArollPiece] = []

    func makeArollPieces(_ included: [AssetEntry], in project: Project) -> [ArollPiece] {
        var cursor = 0.0
        return included.map { entry in
            let length = max(0, entry.outPoint - entry.inPoint)
            defer { cursor += length }
            return ArollPiece(start: cursor, end: cursor + length, inPoint: entry.inPoint,
                              asset: AVURLAsset(url: project.folder.appendingPathComponent(entry.path)))
        }
    }

    /// A small frame (up to 400 px) of the A-roll at `t`, read from the clip file it comes from.
    static func pieceImage(_ pieces: [ArollPiece], at t: Double, tolerance: Double) async -> CGImage? {
        guard let piece = pieces.last(where: { t >= $0.start }) ?? pieces.first else { return nil }
        let local = piece.inPoint + min(max(0, t - piece.start), max(0, piece.end - piece.start - 0.01))
        let generator = AVAssetImageGenerator(asset: piece.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        return try? await generator.image(at: CMTime(seconds: local, preferredTimescale: 600)).image
    }
    private var zoomThumbPending: [Int] = []
    private var zoomThumbWanted = Set<Int>()
    private var zoomThumbWork: DispatchWorkItem?

    private func makeZoomThumbnails(keys: [Int]) {
        guard sourceAsset != nil, !keys.isEmpty else { return }
        zoomThumbWanted.formUnion(keys)
        zoomThumbWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startZoomThumbnails() }
        zoomThumbWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func startZoomThumbnails() {
        zoomThumbWork = nil
        let keys = Array(zoomThumbWanted)
        zoomThumbWanted.removeAll()
        guard let asset = sourceAsset, !keys.isEmpty else {
            trimBar.forgetThumbnailRequests(keys)
            return
        }
        if !arollPieces.isEmpty {
            // An assembled A-roll: each frame comes from its own clip file (see ArollPiece).
            let newKeys = Set(keys)
            trimBar.forgetThumbnailRequests(zoomThumbPending.filter { !newKeys.contains($0) })
            zoomThumbTask?.cancel()
            zoomThumbPending = keys
            let pieces = arollPieces
            zoomThumbTask = Task { [weak self] in
                for key in keys.sorted() {
                    if Task.isCancelled { return }
                    let image = await Self.pieceImage(pieces, at: Double(key) / 100, tolerance: 0.1)
                    await MainActor.run {
                        guard let self, !Task.isCancelled else { return }
                        self.zoomThumbPending.removeAll { $0 == key }
                        if let image { self.trimBar.setThumbnail(image, forKey: key) }
                    }
                }
            }
            return
        }
        let generator: AVAssetImageGenerator
        if let current = zoomThumbGenerator, current.asset === asset {
            generator = current
        } else {
            zoomThumbGenerator?.cancelAllCGImageGeneration()
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            zoomThumbGenerator = generator
        }
        // Only the newest request matters: drop the unfinished older ones (the strip asks again
        // for any it still shows).
        let newKeys = Set(keys)
        let dropped = zoomThumbPending.filter { !newKeys.contains($0) }
        if !zoomThumbPending.isEmpty { generator.cancelAllCGImageGeneration() }
        trimBar.forgetThumbnailRequests(dropped)
        zoomThumbPending = keys
        let times = keys.sorted().map { NSValue(time: CMTime(value: CMTimeValue($0 * 6), timescale: 600)) }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, result, _ in
            let key = Int((requested.seconds * 100).rounded())
            DispatchQueue.main.async {
                guard let self, self.zoomThumbGenerator === generator else { return }
                if result == .succeeded, let image {
                    self.zoomThumbPending.removeAll { $0 == key }
                    self.trimBar.setThumbnail(image, forKey: key)
                } else if result == .failed {
                    self.zoomThumbPending.removeAll { $0 == key }
                }
            }
        }
    }

    /// Filmstrip thumbnails for the trim strip (made in the background).
    private func makeThumbnails(asset: AVAsset, duration: Double) {
        let count = 20
        trimBar.resetThumbnails(count: count)
        if !arollPieces.isEmpty {
            // An assembled A-roll: each frame comes from its own clip file (see ArollPiece).
            let pieces = arollPieces
            thumbnailGenerator = nil
            filmstripTask?.cancel()
            filmstripTask = Task { [weak self] in
                for i in 0..<count {
                    if Task.isCancelled { return }
                    let t = duration * (Double(i) + 0.5) / Double(count)
                    guard let image = await Self.pieceImage(pieces, at: t, tolerance: max(0.5, duration / Double(count) / 2)) else { continue }
                    await MainActor.run {
                        guard let self, !Task.isCancelled else { return }
                        self.trimBar.setThumbnail(image, at: i)
                    }
                }
            }
            return
        }
        filmstripTask?.cancel()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let tolerance = CMTime(seconds: max(0.5, duration / Double(count) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        thumbnailGenerator = generator
        let times = (0..<count).map {
            NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600))
        }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, result, _ in
            guard result == .succeeded, let image else { return }
            let index = min(count - 1, max(0, Int(requested.seconds / duration * Double(count))))
            DispatchQueue.main.async {
                guard let self, self.thumbnailGenerator === generator else { return }
                self.trimBar.setThumbnail(image, at: index)
            }
        }
    }

    /// Edit › Undo and Redo in this window use the edit history.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history.undoManager }

    func windowWillClose(_ notification: Notification) {
        player?.pause()
        saveProject()     // closing the window keeps the app running (like other Mac apps)
        (NSApp.delegate as? AppDelegate)?.projectWindowClosed(self)
    }

    /// True when nothing is open in this window yet (no project, no clip): a new project can use it.
    var isEmpty: Bool { project == nil && player == nil && !isExporting }

    /// True when this window has the project at `url` (its .1shot file or its folder) open.
    func isShowing(_ url: URL) -> Bool {
        guard let project else { return false }
        let u = url.standardizedFileURL
        return project.fileURL.standardizedFileURL == u || project.folder.standardizedFileURL == u
    }

    /// Several projects (3.2): a closed project window that isn't the last one is let go for good.
    /// Stops playback, audio and timers so nothing keeps running for a window that's gone.
    func tearDown() {
        saveProject()
        autosaveTimer?.invalidate(); autosaveTimer = nil
        histogramTimer?.invalidate(); histogramTimer = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        viewerWatchdog?.cancel(); viewerWatchdog = nil
        history.detach()
        drawer.stopMeters()
        player?.pause()
        rack.detach()
        playerView.player = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

// MARK: - Project selector

final class ProjectSelector: NSWindowController {
    var onCreate: ((NSWindow) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onBrowse: (() -> Void)?
    /// True when this project is the one open in the main window (it can't be deleted then).
    var isOpen: ((URL) -> Bool)?
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No projects yet. Create one to get started.")
    private var projectURLs: [URL] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "1Shot"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.085, alpha: 1).cgColor
        window.contentView = root

        let eyebrow = NSTextField(labelWithString: "1SHOT")
        eyebrow.font = .boldSystemFont(ofSize: 11)
        eyebrow.textColor = NSColor(calibratedRed: 0.67, green: 0.75, blue: 0.48, alpha: 1)
        let title = NSTextField(labelWithString: "Your projects")
        title.font = .boldSystemFont(ofSize: 30)
        let subtitle = NSTextField(labelWithString: "Pick up where you left off, or start something new.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let create = NSButton(title: "+  New Project", target: self, action: #selector(createClicked))
        create.bezelStyle = .rounded
        create.controlSize = .large
        create.keyEquivalent = "n"
        create.keyEquivalentModifierMask = [.command]
        let browse = NSButton(title: "Open Other…", target: self, action: #selector(browseClicked))
        browse.bezelStyle = .rounded
        browse.controlSize = .large
        let buttons = NSStackView(views: [create, browse])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let heading = NSTextField(labelWithString: "AVAILABLE PROJECTS")
        heading.font = .boldSystemFont(ofSize: 10)
        heading.textColor = .secondaryLabelColor
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 18
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // A flipped document view keeps the cards packed at the top-left, however few are left
        // (an unflipped one lets them sink to the bottom after a delete).
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [eyebrow, title, subtitle, heading, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(18, after: scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -42),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Project.defaultLocation, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
        let local = folders.compactMap { folder -> URL? in
            let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return files?.first { $0.pathExtension.lowercased() == Project.fileExtension }
        }
        let recent = RecentFiles.list().filter { $0.pathExtension.lowercased() == Project.fileExtension }
        var seen = Set<String>()
        let projects = (recent + local.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            .filter { fm.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
        projectURLs = projects
        if projects.isEmpty { list.addArrangedSubview(empty); return }
        for rowStart in stride(from: 0, to: projects.count, by: 3) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 16
            row.setHuggingPriority(.required, for: .horizontal)   // cards start at the left edge
            for index in rowStart..<min(rowStart + 3, projects.count) {
                let url = projects[index]
                let image = NSImageView()
                image.imageScaling = .scaleProportionallyUpOrDown
                image.wantsLayer = true
                image.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
                image.layer?.cornerRadius = 6
                image.layer?.masksToBounds = true
                image.image = NSImage(systemSymbolName: "film", accessibilityDescription: "No video preview")
                image.contentTintColor = .secondaryLabelColor
                image.translatesAutoresizingMaskIntoConstraints = false
                let button = NSButton(title: "", target: self, action: #selector(projectClicked(_:)))
                button.isBordered = false
                button.tag = index
                button.toolTip = url.deletingLastPathComponent().path
                button.translatesAutoresizingMaskIntoConstraints = false
                let preview = NSView()
                preview.translatesAutoresizingMaskIntoConstraints = false
                preview.addSubview(image)
                preview.addSubview(button)
                NSLayoutConstraint.activate([
                    preview.widthAnchor.constraint(equalToConstant: 198),
                    preview.heightAnchor.constraint(equalToConstant: 111),
                    image.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
                    image.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
                    image.topAnchor.constraint(equalTo: preview.topAnchor),
                    image.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
                    button.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
                    button.topAnchor.constraint(equalTo: preview.topAnchor),
                    button.bottomAnchor.constraint(equalTo: preview.bottomAnchor)
                ])
                let name = NSButton(title: url.deletingPathExtension().lastPathComponent, target: self, action: #selector(projectClicked(_:)))
                name.tag = index
                name.isBordered = false
                name.alignment = .left
                name.font = .systemFont(ofSize: 13, weight: .medium)
                name.lineBreakMode = .byTruncatingMiddle
                let card = NSStackView(views: [preview])
                card.orientation = .vertical
                card.alignment = .leading
                card.spacing = 6
                name.widthAnchor.constraint(equalToConstant: 172).isActive = true
                // Delete (3.2): moves the whole project folder to the Trash, after asking.
                let trash = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete project")!,
                                     target: self, action: #selector(deleteClicked(_:)))
                trash.isBordered = false
                trash.tag = index
                trash.contentTintColor = .secondaryLabelColor
                trash.toolTip = "Move this project to the Trash"
                trash.widthAnchor.constraint(equalToConstant: 20).isActive = true
                let nameRow = NSStackView(views: [name, trash])
                nameRow.orientation = .horizontal
                nameRow.spacing = 6
                card.addArrangedSubview(nameRow)
                row.addArrangedSubview(card)
                loadPreview(for: url, into: image)
            }
            list.addArrangedSubview(row)
        }
    }

    private func loadPreview(for projectURL: URL, into imageView: NSImageView) {
        DispatchQueue.global(qos: .userInitiated).async { [weak imageView] in
            guard let data = try? Data(contentsOf: projectURL),
                  let project = try? JSONDecoder().decode(ProjectData.self, from: data) else { return }
            let first = project.assets?.filter { !$0.rejected }.sorted { $0.sortDate < $1.sortDate }.first
            guard let path = first?.path ?? project.video else { return }
            let video = projectURL.deletingLastPathComponent().appendingPathComponent(path)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 396, height: 222)
            let start = first?.inPoint ?? project.trimStart ?? 0
            let length = first.map { max(0, $0.outPoint - $0.inPoint) } ?? 2
            let time = max(0, start + min(1, length / 2))
            guard let frame = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { return }
            DispatchQueue.main.async { [weak imageView] in
                imageView?.image = NSImage(cgImage: frame, size: .zero)
                imageView?.contentTintColor = nil
            }
        }
    }

    @objc private func createClicked() { if let window { onCreate?(window) } }
    @objc private func browseClicked() { onBrowse?() }
    @objc private func projectClicked(_ sender: NSButton) {
        if projectURLs.indices.contains(sender.tag) { onOpen?(projectURLs[sender.tag]) }
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard projectURLs.indices.contains(sender.tag), let window else { return }
        let file = projectURLs[sender.tag]
        let folder = file.deletingLastPathComponent()
        let name = file.deletingPathExtension().lastPathComponent
        if isOpen?(file) == true {
            let alert = NSAlert()
            alert.messageText = "“\(name)” is open"
            alert.informativeText = "Close it (open or create another project) before deleting it."
            alert.beginSheetModal(for: window)
            return
        }
        // Only a folder that is this project's own (its .1shot file inside, named like the folder or
        // the only project file there) is trashed; otherwise just the project file goes.
        let fm = FileManager.default
        let siblings = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let ownFolder = siblings.filter { $0.pathExtension.lowercased() == Project.fileExtension }.count == 1
            && folder.standardizedFileURL.path != Project.defaultLocation.standardizedFileURL.path
            && folder.path != NSHomeDirectory()
        let target = ownFolder ? folder : file
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = ownFolder
            ? "The whole project folder goes to the Trash: its media copies, transcript, B-roll, LUT copies and exports.\n\n\(folder.path)\n\nYou can get it back from the Trash until you empty it. Your original video files elsewhere aren't touched, and B-roll in the shared library stays."
            : "The project file goes to the Trash (the folder holds other things, so it stays):\n\n\(file.path)"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try fm.trashItem(at: target, resultingItemURL: nil)
                RecentFiles.remove(file)
                self.refresh()
            } catch {
                let fail = NSAlert()
                fail.messageText = "Couldn't move “\(name)” to the Trash"
                fail.informativeText = error.localizedDescription
                fail.beginSheetModal(for: window)
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let recentMenu = NSMenu(title: "Open Recent")
    private var projectSelector: ProjectSelector?

    /// The project picker shows only while no project is open (3.3.3): any project window on
    /// screen (or in the Dock) hides it; closing the last one brings it back.
    func updateProjectPicker() {
        guard runningCopy == nil else { return }
        let anyOpen = controllers.contains { c in
            guard c.project != nil, let w = c.window else { return false }
            return w.isVisible || w.isMiniaturized
        }
        if anyOpen {
            projectSelector?.window?.orderOut(nil)
        } else if projectSelector?.window?.isVisible != true {
            showProjectSelector()
        }
    }

    private func showProjectSelector() {
        let selector = projectSelector ?? ProjectSelector()
        projectSelector = selector
        selector.onCreate = { [weak self] parent in
            guard let self else { return }
            let target = self.controllerForProject(nil)
            target.newProject(parent: parent) { [weak self] created in
                if created { self?.projectSelector?.window?.orderOut(nil) }
                else { self?.discardIfUnused(target) }
            }
        }
        selector.onOpen = { [weak self] url in self?.openFromSelector(url) }
        selector.isOpen = { [weak self] url in self?.controller(showing: url) != nil }
        selector.onBrowse = { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Open Project"
            panel.message = "Choose a project folder or its .1shot file."
            if let type = UTType(filenameExtension: Project.fileExtension) { panel.allowedContentTypes = [type, .folder] }
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = Project.defaultLocation
            if panel.runModal() == .OK, let url = panel.url { self?.openFromSelector(url) }
        }
        selector.refresh()
        selector.showWindow(nil)
        selector.window?.makeKeyAndOrderFront(nil)
    }

    private func openFromSelector(_ url: URL) {
        if let existing = controller(showing: url) {
            projectSelector?.window?.orderOut(nil)
            bringToFront(existing)
            return
        }
        let target = controllerForProject(url)
        target.showWindow(nil)
        target.openProject(url)
        if target.isShowing(url) {
            projectSelector?.window?.orderOut(nil)
            bringToFront(target)
        } else {
            discardIfUnused(target)     // it didn't open (an alert said why)
        }
    }

    /// A window made for a project that then wasn't created or opened: close it again,
    /// unless it's the only one.
    private func discardIfUnused(_ c: PlayerWindowController) {
        guard c.isEmpty, controllers.count > 1 else { return }
        c.close()                       // windowWillClose → projectWindowClosed lets it go
    }

    // File › Open Recent: rebuilt each time it's opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let files = RecentFiles.list()
        if files.isEmpty {
            let none = NSMenuItem(title: "No Recent Projects or Videos", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for url in files {
            let isProject = url.pathExtension.lowercased() == Project.fileExtension
            let title = isProject ? "\(url.deletingPathExtension().lastPathComponent) (project)" : url.lastPathComponent
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.isEnabled = FileManager.default.fileExists(atPath: url.path)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !files.isEmpty
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openRouted(url)
    }

    /// File › New Project…: in the front window if it's empty, otherwise in a new window.
    @objc func newProject(_ sender: Any?) {
        let target = controllerForProject(nil)
        target.newProject { [weak self] created in
            if !created { self?.discardIfUnused(target) }
        }
    }
    @objc func saveProject(_ sender: Any?) { controller?.saveCommand() }
    @objc func saveProjectAs(_ sender: Any?) { controller?.saveAsCommand() }
    @objc func createEditTranscript(_ sender: Any?) { controller?.createEditTranscript() }
    @objc func cutPauses(_ sender: Any?) { controller?.cutPausesFromTranscript() }
    @objc func pasteCutList(_ sender: Any?) { controller?.pasteCutList() }
    @objc func importCutList(_ sender: Any?) { controller?.importCutList() }
    @objc func exportCutList(_ sender: Any?) { controller?.exportCutList() }
    @objc func exportDavinciTimeline(_ sender: Any?) { controller?.exportDavinciTimeline() }
    @objc func clearCuts(_ sender: Any?) { controller?.clearCuts() }
    @objc func importZoomList(_ sender: Any?) { controller?.importZoomList() }
    @objc func addBrollAtPlayhead(_ sender: Any?) { controller?.addBrollAtPlayhead() }
    @objc func importBrollList(_ sender: Any?) { controller?.importBrollList() }
    @objc func pasteBrollList(_ sender: Any?) { controller?.pasteBrollList() }
    @objc func downloadMissingBroll(_ sender: Any?) { controller?.downloadMissingBroll() }
    @objc func clearBroll(_ sender: Any?) { controller?.clearBroll() }
    @objc func exportBrollLibrary(_ sender: Any?) { controller?.exportBrollLibrary() }
    @objc func showSettings(_ sender: Any?) { SettingsWindow.shared.show() }
    @objc func pasteZoomList(_ sender: Any?) { controller?.pasteZoomList() }
    @objc func clearZooms(_ sender: Any?) { controller?.clearZooms() }
    @objc func removeSelectedCut(_ sender: Any?) { controller?.deleteSelectedCut() }
    @objc func zoomTimelineIn(_ sender: Any?) { controller?.zoomTimeline(1) }
    @objc func zoomTimelineOut(_ sender: Any?) { controller?.zoomTimeline(-1) }
    @objc func zoomTimelineFit(_ sender: Any?) { controller?.zoomTimeline(0) }
    @objc func toggleTimelineClips(_ sender: Any?) { controller?.toggleTimelineClips() }
    @objc func showStyleGuides(_ sender: Any?) {
        Project.installStyleGuides()
        GraphicsTuningStore.ensureFile()
        NSWorkspace.shared.open(Project.styleGuidesFolder)
    }
    /// File › Open Project…: opens in its own window (or brings it forward if it's already open).
    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project folder or its .1shot file."
        if let type = UTType(filenameExtension: Project.fileExtension) {
            panel.allowedContentTypes = [type, .folder]
        }
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Project.defaultLocation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openRouted(url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if runningCopy != nil { return }   // a copy that handed off owns nothing: leave the socket alone
        for c in controllers { c.saveProject() }
        ControlServer.shared.stop()
    }

    @objc func clearRecent(_ sender: Any?) {
        RecentFiles.clear()
    }

    // MARK: Project windows (3.2)
    // Each open project gets its own window. Menu commands and shortcuts go to the window in front.

    private(set) var controllers: [PlayerWindowController] = []
    private weak var lastActive: PlayerWindowController?

    /// The project window in front (or the one most recently in front, while e.g. Settings is key).
    var controller: PlayerWindowController? {
        if let c = NSApp.keyWindow?.windowController as? PlayerWindowController { return c }
        if let c = NSApp.mainWindow?.windowController as? PlayerWindowController { return c }
        return lastActive ?? controllers.last
    }

    /// A new, empty project window, placed a step down and right from the one in front.
    @discardableResult
    func makeController() -> PlayerWindowController {
        let c = PlayerWindowController()
        c.window?.isReleasedWhenClosed = false
        if let front = controller?.window, let window = c.window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        } else if let window = c.window, let screen = window.screen ?? NSScreen.main {
            // Fill the screen as a normal window (menu bar and Dock stay visible) — not Full Screen mode.
            window.setFrame(screen.visibleFrame, display: false)
        }
        controllers.append(c)
        return c
    }

    /// The window that already has this project open, if any.
    func controller(showing url: URL) -> PlayerWindowController? {
        controllers.first { $0.isShowing(url) }
    }

    /// Where a project should open: the window that already has it, the front window if it's
    /// still empty, otherwise a new window.
    func controllerForProject(_ url: URL?) -> PlayerWindowController {
        if let url, let existing = controller(showing: url) { return existing }
        if let front = controller, front.isEmpty { return front }
        // The last window, closed (hidden) with its project saved: reuse it rather than keep it around.
        if let closed = controllers.first(where: {
            guard let w = $0.window else { return false }
            return !w.isVisible && !w.isMiniaturized && !$0.isExporting
        }) { return closed }
        return makeController()
    }

    /// Opens a project (or a video) the way File › Open does.
    func openRouted(_ url: URL) {
        let isProject = url.pathExtension.lowercased() == Project.fileExtension || Self.isProjectFolder(url)
        if isProject, let existing = controller(showing: url) {
            bringToFront(existing)
            return
        }
        // A plain video goes to the front window (which offers to add it to its project).
        let target = isProject ? controllerForProject(url) : (controller ?? makeController())
        projectSelector?.window?.orderOut(nil)
        target.open(url)
        bringToFront(target)
    }

    private static func isProjectFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension.lowercased() == Project.fileExtension }
    }

    func bringToFront(_ c: PlayerWindowController) {
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A project window was closed. The last one stays around hidden (the Dock icon brings it
    /// back, as before); any other is let go, so its project stops using memory and audio.
    func projectWindowClosed(_ c: PlayerWindowController) {
        DispatchQueue.main.async { [weak self] in self?.updateProjectPicker() }   // once it's off screen
        guard controllers.count > 1 else { return }
        controllers.removeAll { $0 === c }
        c.tearDown()
        if lastActive === c { lastActive = nil }
    }

    /// Only the window in front plays: bringing one forward pauses the others.
    @objc private func windowBecameMain(_ note: Notification) {
        guard let c = (note.object as? NSWindow)?.windowController as? PlayerWindowController else { return }
        lastActive = c
        for other in controllers where other !== c { other.player?.pause() }
        if c.project != nil { projectSelector?.window?.orderOut(nil) }
    }

    private var pendingURL: URL?
    private var spaceMonitor: Any?

    /// Space bar = play/pause from any of this app's windows (player, plugin editors…),
    /// except while you're typing into a text field.
    /// Left/right arrow = step one frame back/forward (Shift = one second). Hold to keep stepping.
    /// Home / End (fn ← / fn →) = go to the start / end of the trim.
    /// A / S / V = switch to the Assets, Sound Design and Visual Design tabs. E = Export for YouTube.
    /// X = mark a cut (press at the start, then at the end) · Delete = remove the selected cut · Esc = cancel marking.
    private func installSpaceBarMonitor() {
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])
            switch event.keyCode {
            case 49:   // space
                guard mods.isEmpty, self.spaceShouldControlPlayback(event) else { return event }
                if !event.isARepeat { self.controller?.togglePlayPause() }
                return nil   // swallow it so nothing else also reacts
            case 51, 117:    // delete, forward delete: remove the selected cut
                guard mods.isEmpty, self.spaceShouldControlPlayback(event),
                      self.controller?.deleteSelectedCut() == true else { return event }
                return nil
            case 53:         // esc: stop marking a cut
                return self.controller?.cancelMarkCut() == true ? nil : event
            case 115, 119:   // Home, End (fn ← / fn → on a laptop): go to start / end
                guard mods.isEmpty, self.spaceShouldControlPlayback(event),
                      let controller = self.controller else { return event }
                if event.keyCode == 115 { controller.goToStart() } else { controller.goToEnd() }
                return nil
            case 123, 124:   // left, right arrow
                guard mods.isEmpty || mods == .shift, self.spaceShouldControlPlayback(event),
                      !((event.window ?? NSApp.keyWindow)?.firstResponder is NSSlider),
                      let controller = self.controller else { return event }
                let direction = event.keyCode == 124 ? 1 : -1
                if mods == .shift { controller.stepSecond(by: direction) }
                else { controller.stepFrame(by: direction) }
                return nil
            default:
                // A / S / V (no modifiers) = Assets, Sound Design, Visual Design tabs; E = Export for YouTube.
                guard mods.isEmpty || mods == .shift, !event.isARepeat, self.spaceShouldControlPlayback(event),
                      let controller = self.controller,
                      let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                if mods == .shift {
                    // Shift-Z: zoom the timeline to fit (as in DaVinci).
                    guard key == "z" else { return event }
                    controller.zoomTimeline(0)
                    return nil
                }
                switch key {
                case "a": controller.selectTab(.assets)
                case "s": controller.selectTab(.soundDesign)
                case "v": controller.selectTab(.visualDesign)
                case "e": controller.exportVideo()
                case "x": controller.markCut()
                case "z": controller.insertZoomAtPlayhead()
                case "b": controller.addBrollAtPlayhead()
                default: return event
                }
                return nil
            }
        }
    }

    private func spaceShouldControlPlayback(_ event: NSEvent) -> Bool {
        // Leave dialogs alone: Open panel, alerts, save-preset sheets, etc.
        guard NSApp.modalWindow == nil,
              let window = event.window ?? NSApp.keyWindow,
              window.attachedSheet == nil else { return false }
        if let responder = window.firstResponder, Self.isTyping(in: responder) { return false }
        return true
    }

    private static func isTyping(in responder: NSResponder) -> Bool {
        // Standard Mac text fields edit through an NSTextView ("field editor").
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        // Plugins with custom-drawn UIs (e.g. JUCE-based) report an active text
        // cursor through the text-input protocol; no cursor means not typing.
        if let client = responder as? NSTextInputClient {
            return client.selectedRange().location != NSNotFound
        }
        return false
    }

    // MARK: One copy at a time (3.2)
    // Two copies of 1Shot fight over the Claude socket, the settings files and the graphics caches.
    // So a second copy hands any files it was asked to open to the one already running, then quits.

    private var runningCopy: NSRunningApplication?
    private var handOffURLs: [URL] = []

    private static func findRunningCopy() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private func handOff(to other: NSRunningApplication) {
        NSLog("1Shot: already running (pid \(other.processIdentifier)); handing over \(handOffURLs.count) file(s) and quitting")
        if !handOffURLs.isEmpty {
            // A standard "open documents" Apple event, sent straight to that process.
            let list = NSAppleEventDescriptor.list()
            for (i, url) in handOffURLs.enumerated() {
                list.insert(NSAppleEventDescriptor(fileURL: url), at: i + 1)
            }
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                               eventID: AEEventID(kAEOpenDocuments),
                                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: other.processIdentifier),
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(list, forKeyword: keyDirectObject)
            _ = try? event.sendEvent(options: [.noReply], timeout: 5)
        }
        other.activate()
        NSApp.terminate(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let other = Self.findRunningCopy() { runningCopy = other; return }
        UserDefaults.standard.register(defaults: ["TimecodeVisible": true, "NormalizeLoudness": true])
        NSApp.mainMenu = buildMenu()
        Project.installStyleGuides()
        GraphicsTuningStore.ensureFile()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = runningCopy { handOff(to: other); return }
        // The first project window (closing it hides it; the Dock icon or ⌘1 brings it back).
        let c = makeController()
        lastActive = c
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameMain(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
        if let url = pendingURL { c.open(url); pendingURL = nil }
        else { showProjectSelector() }
        installSpaceBarMonitor()
        ControlServer.shared.start()   // lets Claude drive the app (MCP, version 2.4)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Finder "Open With", dragging onto the Dock icon, etc.
    func application(_ application: NSApplication, open urls: [URL]) {
        if runningCopy != nil { handOffURLs += urls; return }
        guard !controllers.isEmpty else { pendingURL = urls.first; return }
        for url in urls { openRouted(url) }
    }

    // Like other Mac apps: closing the window doesn't quit. Quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Nothing on screen: a closed project window counts as closed, so this shows the project
        // picker (3.3.3; ⌘1 still brings the last project window back). A window in the Dock
        // comes back the usual way.
        if !flag { updateProjectPicker() }
        return true
    }

    @objc func showMainWindow(_ sender: Any?) {
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller?.open(url)
        }
    }

    @objc func toggleTimecode(_ sender: Any?) {
        guard let overlay = controller?.overlay else { return }
        overlay.isHidden.toggle()
        UserDefaults.standard.set(!overlay.isHidden, forKey: "TimecodeVisible")
    }

    @objc func selectVisualDesignTab(_ sender: Any?) {
        controller?.selectTab(.visualDesign)
    }

    @objc func toggleLoop(_ sender: Any?) {
        controller?.toggleLoop()
    }

    @objc func selectAssetsTab(_ sender: Any?) {
        controller?.selectTab(.assets)
    }

    @objc func showStepTipsAgain(_ sender: Any?) {
        StepTipCard.turnedOff = false
        controller?.resetStepTips()
    }

    @objc func resetTrim(_ sender: Any?) {
        controller?.resetTrim()
    }

    @objc func exportVideo(_ sender: Any?) {
        controller?.exportVideo()
    }

    @objc func selectSoundDesignTab(_ sender: Any?) {
        controller?.selectTab(.soundDesign)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTimecode(_:)) {
            menuItem.state = (controller?.overlay.isHidden == false) ? .on : .off
        }
        if menuItem.action == #selector(selectVisualDesignTab(_:)) {
            menuItem.state = (controller?.currentTab == .visualDesign) ? .on : .off
        }
        if menuItem.action == #selector(toggleLoop(_:)) {
            menuItem.state = (controller?.loopPlayback == true) ? .on : .off
        }
        if menuItem.action == #selector(selectAssetsTab(_:)) {
            menuItem.state = (controller?.currentTab == .assets) ? .on : .off
        }
        if menuItem.action == #selector(removeSelectedCut(_:)) {
            return controller?.hasSelectedCut == true
        }
        if menuItem.action == #selector(clearCuts(_:)) {
            return controller?.cuts.isEmpty == false
        }
        if menuItem.action == #selector(resetTrim(_:)) {
            return controller?.isTrimmed == true
        }
        if menuItem.action == #selector(toggleTimelineClips(_:)) {
            menuItem.state = controller?.timelineShowsClips == false ? .off : .on
        }
        if menuItem.action == #selector(selectSoundDesignTab(_:)) {
            menuItem.state = (controller?.currentTab == .soundDesign) ? .on : .off
        }
        if menuItem.action == #selector(exportDavinciTimeline(_:)) {
            return controller?.canExportDavinciTimeline == true
        }
        return true
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "1Shot"

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Project…", action: #selector(newProject(_:)), keyEquivalent: "n")
        let openProjectItem = file.addItem(withTitle: "Open Project…", action: #selector(openProject(_:)), keyEquivalent: "o")
        openProjectItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Open Video…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        recentMenu.autoenablesItems = false
        recentMenu.delegate = self
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: #selector(saveProject(_:)), keyEquivalent: "s")
        let saveAsItem = file.addItem(withTitle: "Save As…", action: #selector(saveProjectAs(_:)), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Show Style Guides", action: #selector(showStyleGuides(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Export for YouTube…", action: #selector(exportVideo(_:)), keyEquivalent: "y")
        file.addItem(withTitle: "Export Timeline for DaVinci…", action: #selector(exportDavinciTimeline(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file))

        // Edit (standard text editing — also makes copy/paste work in plugin preset names)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Reset Trim", action: #selector(resetTrim(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Remove Selected Cut (Delete)", action: #selector(removeSelectedCut(_:)), keyEquivalent: "")
        main.addItem(submenu(edit))

        // Automation: transcript-driven editing
        let automation = NSMenu(title: "Automation")
        automation.addItem(withTitle: "Create Edit Transcript", action: #selector(createEditTranscript(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Cut Pauses from Transcript", action: #selector(cutPauses(_:)), keyEquivalent: "")
        let pasteCuts = automation.addItem(withTitle: "Paste Cut List", action: #selector(pasteCutList(_:)), keyEquivalent: "v")
        pasteCuts.keyEquivalentModifierMask = [.command, .option]
        automation.addItem(withTitle: "Import Cut List…", action: #selector(importCutList(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Export Finalized Cut List…", action: #selector(exportCutList(_:)), keyEquivalent: "")
        automation.addItem(.separator())
        automation.addItem(withTitle: "Clear All Cuts", action: #selector(clearCuts(_:)), keyEquivalent: "")
        automation.addItem(.separator())
        automation.addItem(withTitle: "Import Zoom List…", action: #selector(importZoomList(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Paste Zoom List", action: #selector(pasteZoomList(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Clear All Zooms", action: #selector(clearZooms(_:)), keyEquivalent: "")
        automation.addItem(.separator())
        automation.addItem(withTitle: "Add B-roll at Playhead… (B)", action: #selector(addBrollAtPlayhead(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Import B-roll List…", action: #selector(importBrollList(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Paste B-roll List", action: #selector(pasteBrollList(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Download Missing B-roll", action: #selector(downloadMissingBroll(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Clear All B-roll", action: #selector(clearBroll(_:)), keyEquivalent: "")
        automation.addItem(withTitle: "Export B-roll Library List…", action: #selector(exportBrollLibrary(_:)), keyEquivalent: "")
        main.addItem(submenu(automation))

        // View
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Show Timecode", action: #selector(toggleTimecode(_:)), keyEquivalent: "t")
        let loopItem = view.addItem(withTitle: "Loop", action: #selector(toggleLoop(_:)), keyEquivalent: "l")
        loopItem.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        let assetsItem = view.addItem(withTitle: "Assets", action: #selector(selectAssetsTab(_:)), keyEquivalent: "a")
        assetsItem.keyEquivalentModifierMask = [.command, .option]
        let exportItem = view.addItem(withTitle: "Visual Design", action: #selector(selectVisualDesignTab(_:)), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Sound Design", action: #selector(selectSoundDesignTab(_:)), keyEquivalent: "e")
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In Timeline", action: #selector(zoomTimelineIn(_:)), keyEquivalent: "+")
        // ⌘+ is really ⌘⇧= on most keyboards; this hidden twin lets plain ⌘= work too.
        let zoomInAlt = view.addItem(withTitle: "Zoom In Timeline", action: #selector(zoomTimelineIn(_:)), keyEquivalent: "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out Timeline", action: #selector(zoomTimelineOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Zoom Timeline to Fit (⇧Z)", action: #selector(zoomTimelineFit(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Show Cuts as Clips", action: #selector(toggleTimelineClips(_:)), keyEquivalent: "")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen",
                              action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Front Project Window", action: #selector(showMainWindow(_:)), keyEquivalent: "1")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Show Step Tips Again", action: #selector(showStepTipsAgain(_:)), keyEquivalent: "")
        main.addItem(submenu(help))
        NSApp.helpMenu = help

        return main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

extension Timer {
    /// A repeating timer that keeps firing while you drag a slider or scrub
    /// (ordinary timers pause during mouse tracking).
    @discardableResult
    static func everyMode(withTimeInterval interval: TimeInterval, repeats: Bool,
                          block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// The last 5 videos opened (newest first), remembered between launches.
enum RecentFiles {
    private static let key = "RecentVideos"
    private static let limit = 5

    static func list() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != path }
        UserDefaults.standard.set(paths, forKey: key)
    }
}

