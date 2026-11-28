import AppKit
import ImageIO
import TinySAKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate,
  SessionDelegate
{
  static let repository = URL(string: "https://github.com/tolgabalci/tinysa-screen")!

  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
  private let view = ScreenView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
  private let session = Session()
  private var image: CGImage?
  /// Escape's way back to the analyzer's graph, while it runs.
  private var escapeRun: EscapeRun?
  private var status = Status(source: "", note: nil, controllable: false)
  /// Shared in a call, the window often sits behind the call's own window, where App Nap would slow the app down and
  /// the picture would freeze.
  private let activity = ProcessInfo.processInfo.beginActivity(
    options: .userInitiatedAllowingIdleSystemSleep, reason: "Showing the tinySA's screen live")

  private var gifs: GIFController!
  private var bands: BandController!
  /// Other programs' requests (the command line, scripts, AI agents), through the control socket.
  private var automation: Automation!
  private var control: ControlServer?
  private var otherRecordings: [String] = []
  private let recordButton = ToolbarButton()
  /// ⌥ is down: Stop is Stop & Save.
  private var optionDown = false
  /// The link to the latest GIF, right of Record, once there is one.
  private let lastGIFLink = LastGIFLink()
  private var lastGIFButton: LinkButton { lastGIFLink.button }
  private var lastGIF: URL?
  private let pointerButton = ToolbarButton()
  private let penButton = ToolbarButton()
  private let peaksButton = ToolbarButton()
  /// Beside Peaks while the hold is on.
  private let clearPeaksButton = ToolbarButton()
  /// The peak hold, while it's on: fed each frame by the session.
  private let peakHold = PeakHold()
  private var peakFrames: UUID?
  private var peakSettings: (TimeInterval?, Int)?
  private var keptSeconds = -1

  func applicationDidFinishLaunching(_ notification: Notification) {
    Preferences.register()
    NSWindow.allowsAutomaticWindowTabbing = false  // one window: no tab bar items in the menus
    // The toolbar asks for its buttons as soon as it is set: they come first.
    gifs = GIFController(recorder: session.recorder, window: window, view: view)
    let bandMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Band" }?.submenu
    bands = BandController(session: session, view: view, window: window, menuBarMenu: bandMenu)
    gifs.onChange = { [weak self] in self?.updateGIFControls() }
    gifs.onMade = { [weak self] url in self?.showLastGIF(url) }
    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.modifiersChanged(event.modifierFlags)
      return event
    }
    lastGIFButton.target = self
    lastGIFButton.action = #selector(openLastGIF(_:))
    setUpToolbarButton(recordButton, "Record", symbol: "record.circle", action: #selector(toggleRecording(_:)))
    setUpToolbarButton(pointerButton, "Pointer", symbol: "cursorarrow.rays", action: #selector(togglePointer(_:)))
    setUpToolbarButton(penButton, "Pen", symbol: "pencil.tip", action: #selector(togglePen(_:)))
    setUpToolbarButton(peaksButton, "Peaks", symbol: "chart.xyaxis.line", action: #selector(togglePeakHold(_:)))
    peaksButton.setButtonType(.pushOnPushOff)
    peaksButton.toolTip = "Hold the highest level at each frequency and label the highest peaks, on the Mac (⌥⌘P)"
    setUpToolbarButton(clearPeaksButton, "Clear Peaks", symbol: "eraser", action: #selector(clearPeakHold(_:)))
    clearPeaksButton.toolTip = "Start the peak hold over, from the next sweep (⌥⌘⌫)"
    let recorder = session.recorder
    peakHold.onChange = { [weak self] state in
      recorder.notePeaks(state, at: Date())  // for GIFs to draw it as the window does
      DispatchQueue.main.async { self?.peaksChanged(state) }
    }
    for button in [pointerButton, penButton] {
      button.setButtonType(.pushOnPushOff)
      button.imagePosition = .imageOnly
      button.setAccessibilityLabel(button.title)
    }
    pointerButton.toolTip = "A red dot follows the mouse over the picture, for everyone in a call to see (⌘L). Esc ends it."
    penButton.toolTip = "Draw on the picture; each stroke fades after a few seconds (⌘D). Esc ends it."
    view.onEscape = { [weak self] in self?.escape(nil) }
    window.title = TitleBar.title(Bundle.main.infoDictionary)
    updateSubtitle()
    window.contentView = view
    window.contentAspectRatio = NSSize(width: 480, height: 320)
    window.contentMinSize = NSSize(width: 480, height: 320)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.isReleasedWhenClosed = false
    let toolbar = NSToolbar(identifier: "tinySA Screen")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact
    if !window.setFrameUsingName("tinySA Screen") { window.center() }
    window.setFrameAutosaveName("tinySA Screen")
    window.delegate = self
    updateWindowLevel()
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(updateWindowLevel), name: name, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(activeChanged), name: name, object: nil)
    }
    // The toolbar bright in front, dimmer behind.
    for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(frontChanged), name: name, object: window)
    }
    window.makeKeyAndOrderFront(nil)
    view.onTap = { [weak self] x, y, released in
      self?.stopEscape()  // a click takes the analyzer's screen back
      if released { self?.session.release(x: x, y: y) } else { self?.session.touch(x: x, y: y) }
    }
    view.onUntappable = { [weak self] in self?.untappable() }
    preferencesChanged()
    NotificationCenter.default.addObserver(
      self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
    #if DEBUG
      // The window alone, pictured, without the analyzer or the control socket: EditorDemo.window.
      if let screen = ProcessInfo.processInfo.environment["TINYSA_SCREEN_WINDOW_DEMO"] {
        EditorDemo.window(
          window, screen: URL(fileURLWithPath: screen),
          show: { [weak self] image in self.map { $0.session($0.session, show: image) } },
          made: { [weak self] url in self?.showLastGIF(url) })
        return
      }
    #endif
    startControl()
    session.delegate = self
    session.start()
    if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// The app's one window closed (Settings may still be open): the app quits, letting go of the analyzer.
  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === window { NSApp.terminate(nil) }
  }

  /// A recording in progress is stopped and saved (and the GIF the editor shows saved), and GIFs being made are
  /// written, before the app quits (at most 15 seconds).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let gifs, gifs.isBusy else { return .terminateNow }
    var answered = false
    let answer = {
      guard !answered else { return }
      answered = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    gifs.finish(then: answer)
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { MainActor.assumeIsolated { answer() } }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    control?.stop()
    session.stop()
    ProcessInfo.processInfo.endActivity(activity)
  }

  // MARK: SessionDelegate

  func session(_ session: Session, show image: CGImage) {
    let sizeChanged = self.image.map { $0.width != image.width || $0.height != image.height } ?? true
    self.image = image
    view.show(image)
    if sizeChanged {
      // The window keeps the picture's shape (the original tinySA's screen is 320 × 240), at least 480 points wide,
      // whatever size a feeding program's pictures are.
      window.contentAspectRatio = NSSize(width: image.width, height: image.height)
      window.contentMinSize = NSSize(width: 480, height: 480 * CGFloat(image.height) / CGFloat(image.width))
    }
  }

  func session(_ session: Session, status: Status) {
    // When the picture stopped coming, for GIFs: they end there rather than show it as live.
    if let note = status.note {
      gifs.notLive = (note, gifs.notLive?.since ?? Date())
    } else {
      gifs.notLive = nil
    }
    self.status = status
    peaksButton.isEnabled = status.instrument != .nanoVNA
    clearPeaksButton.isEnabled = peaksButton.isEnabled
    if status.instrument == .nanoVNA { view.showPeaks(nil) }
    gifs.source = status.source
    bands.status = status
    view.say(status.note)
    view.controllable = status.controllable && Preferences.controlEnabled
    view.tapEcho = status.feeder != nil
  }

  /// A click on the picture that can't tap the analyzer: why, for a moment, when clicks are on and the window's note
  /// doesn't say it already (a feeder that doesn't pass taps on has the analyzer).
  private func untappable() {
    guard Preferences.controlEnabled, !status.controllable, status.note == nil, let feeder = status.feeder else {
      return
    }
    view.flash("Clicks don't reach the tinySA: \(feeder) has it and doesn't pass them on.")
  }

  /// The window's subtitle: the tagline, or who records the screen from outside while they do.
  private func updateSubtitle() {
    window.subtitle = TitleBar.subtitle(recordingFor: otherRecordings)
  }

  // MARK: Other programs

  /// Answers the command line and other programs on the control socket; the window says what they record.
  private func startControl() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(built from source)"
    automation = Automation(session: session, isApp: true, version: version)
    automation.announce = { [weak self] note in
      DispatchQueue.main.async { self?.view.flash(note) }
    }
    automation.onRecordingsChange = { [weak self] names in
      DispatchQueue.main.async {
        self?.otherRecordings = names
        self?.updateSubtitle()
      }
    }
    let automation = automation!
    let server = ControlServer { request, isOpen in automation.handle(request) { !isOpen() } }
    do {
      try server.start()
      control = server
    } catch {
      // Another copy of the app answers already, or the socket can't be made: the window works without it.
      FileHandle.standardError.write(Data("tinySA Screen: no control socket (\(error))\n".utf8))
    }
  }

  // MARK: Settings

  /// Settings changed (here or in the Settings window): the seconds kept are what they say, clicks tap or don't.
  @objc private func preferencesChanged() {
    view.controllable = status.controllable && Preferences.controlEnabled
    view.inkSeconds = TimeInterval(Preferences.inkSeconds)
    updatePeakHold()
    let kept = Preferences.keptSeconds
    guard kept != keptSeconds else { return }
    keptSeconds = kept
    session.recorder.keepRecent = TimeInterval(kept)
    updateGIFControls()
  }

  @objc func showSettings(_ sender: Any?) {
    SettingsWindow.shared.show()
  }

  // MARK: The toolbar: Record

  private func setUpToolbarButton(_ button: NSButton, _ title: String, symbol: String, action: Selector) {
    button.title = title
    button.image = ToolbarLook.symbol(symbol)
    button.target = self
    button.action = action
    button.bezelStyle = .texturedRounded
    button.imagePosition = .imageLeading
    button.imageHugsTitle = true
    button.font = ToolbarLook.font
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .pointer, .pen, .peaks, .clearPeaks, .band, .record, .lastGIF] + NSToolbarItem.Identifier.gaps
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    let gaps = NSToolbarItem.Identifier.gaps
    return [.flexibleSpace, .pointer, gaps[0], .pen, gaps[1], .peaks, gaps[2], .band, gaps[3], .record]
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    // At the narrowest window, the pointer, pen and peaks go to the overflow menu first, Record and its link last; in
    // that menu each is a menu item (Band with its bands).
    let item = NSToolbarItem(itemIdentifier: identifier)
    func menuForm(_ title: String, _ action: Selector) -> NSMenuItem {
      NSMenuItem(title: title, action: action, keyEquivalent: "")
    }
    switch identifier {
    case .pointer:
      item.label = "Pointer"
      item.view = pointerButton
      item.menuFormRepresentation = menuForm("Pointer", #selector(togglePointer(_:)))
      item.visibilityPriority = .low
    case .pen:
      item.label = "Pen"
      item.view = penButton
      item.menuFormRepresentation = menuForm("Pen", #selector(togglePen(_:)))
      item.visibilityPriority = .low
    case .peaks:
      item.label = "Peaks"
      item.view = OutlinedToolbarItem(peaksButton)
      item.menuFormRepresentation = menuForm("Peak Hold", #selector(togglePeakHold(_:)))
    case .clearPeaks:
      item.label = "Clear Peaks"
      item.view = OutlinedToolbarItem(clearPeaksButton)
      item.menuFormRepresentation = menuForm("Clear Peak Hold", #selector(clearPeakHold(_:)))
    case .band:
      item.label = "Band"
      item.view = OutlinedToolbarItem(bands.makeButton())
      let form = NSMenuItem(title: "Band", action: nil, keyEquivalent: "")
      form.submenu = bands.overflowMenu
      item.menuFormRepresentation = form
    case .record:
      item.label = "Record"
      item.view = OutlinedToolbarItem(recordButton)
      item.menuFormRepresentation = menuForm("Record GIF", #selector(toggleRecording(_:)))
      item.visibilityPriority = .high
    case .lastGIF:
      item.label = "Last recording"
      item.view = lastGIFLink
      item.menuFormRepresentation = menuForm("Open Last Recording", #selector(openLastGIF(_:)))
      item.visibilityPriority = .high
    case let gap where NSToolbarItem.Identifier.gaps.contains(gap):
      // Room between the buttons: an item of nothing, 13 points wide, so they're 11 apart (they touched). The first
      // items to give way when the window is narrow; the » menu leaves them out.
      let nothing = NSView()
      nothing.translatesAutoresizingMaskIntoConstraints = false
      nothing.widthAnchor.constraint(equalToConstant: 13).isActive = true
      item.view = nothing
      item.isBordered = false
      item.visibilityPriority = NSToolbarItem.VisibilityPriority(
        rawValue: NSToolbarItem.VisibilityPriority.low.rawValue - 1)
    default:
      return nil
    }
    return item
  }

  /// The Record button turns into Stop while recording, with the GIF's length so far (from the lead-in before Record),
  /// and into Stop & Save while ⌥ is down.
  private func updateGIFControls() {
    if gifs.isRecording {
      let length = gifs.length.rounded(.down)
      let time = TimeText.duration(length)
      recordButton.title = optionDown ? "Stop & Save \(time)" : "Stop \(time)"
      recordButton.image = ToolbarLook.symbol("stop.fill")
      recordButton.contentTintColor = .systemRed
      recordButton.toolTip =
        "Stop, and trim the GIF before it's saved (⌘R); ⌥-click to save it as it is, to \(Preferences.saveFolderName) "
        + "(⌥⌘R). A recording stops by itself \(TimeText.duration(gifs.longest)) after Record was pressed."
      recordButton.setAccessibilityLabel(
        optionDown
          ? "Stop and save the GIF, \(TimeText.spoken(length)) long"
          : "Stop recording, the GIF is \(TimeText.spoken(length)) long")
    } else {
      recordButton.title = "Record"
      recordButton.image = ToolbarLook.symbol("record.circle")
      recordButton.contentTintColor = nil
      let leadIn = gifs.leadIn
      let from =
        leadIn > 0 ? "starting \(TimeText.spoken(leadIn)) before you press Record" : "starting when you press Record"
      recordButton.toolTip =
        "Record a GIF of the screen (⌘R), \(from), until you stop it: \(TimeText.duration(gifs.longest)) at most"
      recordButton.setAccessibilityLabel("Record a GIF")
    }
  }

  /// Record, or Stop; ⌥-click Stop (or ⌥⌘R) to save the GIF as it is.
  @objc func toggleRecording(_ sender: Any?) {
    gifs.toggleRecording(andSave: NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
  }

  /// File › Stop and Save Recording (⌥⌘R), File › Record GIF's alternate: Record while not recording.
  @objc func stopAndSaveRecording(_ sender: Any?) {
    gifs.toggleRecording(andSave: true)
  }

  /// ⌥ went down or up: Stop says whether it saves.
  private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
    let down = flags.contains(.option)
    guard down != optionDown else { return }
    optionDown = down
    if gifs.isRecording { updateGIFControls() }
  }

  /// ⌥ isn't seen going up in another app: Stop is as the keys are when the app is in front again.
  @objc private func activeChanged() {
    modifiersChanged(NSApp.isActive ? NSEvent.modifierFlags : [])
    frontChanged()
  }

  /// The window came in front or went behind: the toolbar's words and symbols brighten or dim.
  @objc private func frontChanged() {
    ToolbarLook.redraw(window.toolbar)
  }

  /// The link to the GIF just made, right of Record, pulsing for a few seconds to show where it is.
  private func showLastGIF(_ url: URL) {
    lastGIF = url
    lastGIFButton.setLink("Last recording")
    lastGIFButton.toolTip = "Open \(url.lastPathComponent), the GIF made last"
    lastGIFButton.setAccessibilityLabel("Open the last recording")
    if let toolbar = window.toolbar, !toolbar.items.contains(where: { $0.itemIdentifier == .lastGIF }) {
      let record = toolbar.items.firstIndex { $0.itemIdentifier == .record } ?? toolbar.items.count - 1
      toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier.gaps[4], at: record + 1)
      toolbar.insertItem(withItemIdentifier: .lastGIF, at: record + 2)
    }
    // Once the toolbar has put the link in its place.
    DispatchQueue.main.async { [weak self] in self?.lastGIFLink.drawAttention() }
  }

  /// Opens the latest GIF where it plays: in the app the Mac opens GIFs with, or in the browser when that app shows a
  /// GIF still (Preview, an image editor) or no app opens GIFs (`GIFViewer`).
  @objc func openLastGIF(_ sender: Any?) {
    guard let url = lastGIF else { return }
    guard FileManager.default.fileExists(atPath: url.path) else {
      view.flash("The recording isn't there anymore: \(url.lastPathComponent)")
      return
    }
    let workspace = NSWorkspace.shared
    let app = workspace.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    guard GIFViewer.usesBrowser(insteadOf: app),
      let browser = workspace.urlForApplication(toOpen: URL(string: "https://github.com")!)
    else {
      workspace.open(url)
      return
    }
    workspace.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) { _, error in
      guard let error else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.view.flash("The GIF couldn't be opened: \(error.localizedDescription)") }
      }
    }
  }

  // MARK: Presenting

  @objc func togglePointer(_ sender: Any?) { setTool(view.tool == .pointer ? .none : .pointer) }
  @objc func togglePen(_ sender: Any?) { setTool(view.tool == .pen ? .none : .pen) }

  /// The pointer or the pen takes the mouse (clicks no longer tap the analyzer), or neither.
  private func setTool(_ tool: ScreenView.Tool) {
    if tool != .none { stopEscape() }
    if tool != .pen { view.clearInk() }
    view.tool = tool
    pointerButton.state = tool == .pointer ? .on : .off
    penButton.state = tool == .pen ? .on : .off
    if tool != .none { window.makeFirstResponder(view) }  // for Esc
  }

  // MARK: Peak hold

  @objc func togglePeakHold(_ sender: Any?) {
    Preferences.peakHold.toggle()
  }

  @objc func clearPeakHold(_ sender: Any?) {
    peakHold.reset()
  }

  /// View › Hold Peaks For: the item's tag is the seconds (0: until cleared).
  @objc func setPeakWindow(_ sender: NSMenuItem) {
    Preferences.defaults.set(sender.tag, forKey: Preferences.Key.peakWindow)
  }

  /// The peak hold on or off, and its settings, as the preferences say.
  private func updatePeakHold() {
    let on = Preferences.peakHold
    peaksButton.state = on ? .on : .off
    showClearPeaks(on)
    view.peakColor = Preferences.peakColor.color
    view.peaksListed = Preferences.peakListed
    view.peakArrowColor = Preferences.peakArrowColor.color
    let settings = (Preferences.peakWindow, Preferences.peakCount)
    if peakSettings.map({ $0.0 != settings.0 || $0.1 != settings.1 }) ?? true {
      peakSettings = settings
      peakHold.peakCount = settings.1
      peakHold.window = settings.0
    }
    if on, peakFrames == nil {
      let hold = peakHold
      let session = session
      peakFrames = session.onFrame { snapshot, time in
        if session.status.instrument != .nanoVNA { hold.add(snapshot, at: time) }  // a VNA's trace isn't a spectrum
      }
    } else if !on, let token = peakFrames {
      session.removeFrameHandler(token)
      peakFrames = nil
      peakHold.reset()
    }
  }

  /// Clear Peaks beside Peaks, while the hold is on.
  private func showClearPeaks(_ shown: Bool) {
    guard let toolbar = window.toolbar else { return }
    let showing = toolbar.items.contains { $0.itemIdentifier == .clearPeaks }
    if shown, !showing, let peaks = toolbar.items.firstIndex(where: { $0.itemIdentifier == .peaks }) {
      toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier.gaps[5], at: peaks + 1)
      toolbar.insertItem(withItemIdentifier: .clearPeaks, at: peaks + 2)
    } else if !shown, showing {
      for id in [NSToolbarItem.Identifier.clearPeaks, NSToolbarItem.Identifier.gaps[5]] {
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) { toolbar.removeItem(at: index) }
      }
    }
  }

  /// The hold drawn while it's on, over a spectrum (a NanoVNA's yellow trace is a measurement, not a level).
  private func peaksChanged(_ state: PeakHold.State?) {
    view.showPeaks(Preferences.peakHold && status.instrument != .nanoVNA ? state : nil)
  }

  @objc func toggleFloatOnTop(_ sender: Any?) {
    Preferences.floatOnTop.toggle()
    updateWindowLevel()
  }

  /// Float on Top keeps the window above other apps' windows while another app is in front (a call's, say); while this
  /// app is, its own windows (Settings, About, sheets) open above it as usual.
  @objc private func updateWindowLevel() {
    window.level = Preferences.floatOnTop && !NSApp.isActive ? .floating : .normal
  }

  // MARK: Menu actions

  /// What a screenshot saves or copies: the analyzer's screen, with the peak hold over it as the window shows it while
  /// it's on (at twice the screen's size then, so its words can be read), unless Settings leaves it out.
  private func screenshot() -> CGImage? {
    guard let image else { return nil }
    guard Preferences.screenshotPeaks, Preferences.peakHold, status.instrument != .nanoVNA,
      let state = peakHold.state, let screen = Snapshot(image)
    else { return image }
    let options = GIFOptions(scale: 2, showsDate: false, showsTime: false, peaks: Preferences.peakLook)
    return GIF.still(screen, caption: Caption(clock: Date()), options: options, peaks: state).image() ?? image
  }

  @objc func saveScreenshot(_ sender: Any?) {
    guard let image = screenshot() else { return }
    do {
      // Named after when its picture came (not now: the picture may have stopped coming), never over another file.
      let start = session.recorder.latestSnapshot()?.time ?? Date()
      let saved = try Preferences.saveFolder.save(for: start, extension: "png") { url in
        guard
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
      }
      if let moved = saved.moved { Preferences.saveFolder = moved }
      view.flash(saved.note())
    } catch {
      view.flash("The screenshot couldn't be saved: \(error.localizedDescription)")
    }
  }

  @objc func copy(_ sender: Any?) {
    guard let image = screenshot() else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    view.flash("Copied")
  }

  @objc func actualSize(_ sender: Any?) { setScale(1) }
  @objc func doubleSize(_ sender: Any?) { setScale(2) }
  @objc func tripleSize(_ sender: Any?) { setScale(3) }

  /// The window at a whole number of the analyzer's pixels to each of its points, as far as the screen allows.
  private func setScale(_ scale: CGFloat) {
    guard !window.styleMask.contains(.fullScreen) else { return }
    let pixels = image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 480, height: 320)
    var content = NSRect(origin: .zero, size: CGSize(width: pixels.width * scale, height: pixels.height * scale))
    var frame = window.frameRect(forContentRect: content)
    if let visible = window.screen?.visibleFrame, frame.width > visible.width || frame.height > visible.height {
      let fit = min(visible.width / frame.width, visible.height / frame.height)
      content.size = CGSize(width: content.width * fit, height: content.height * fit)
      frame = window.frameRect(forContentRect: content)
    }
    frame.origin = CGPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
    window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true, animate: true)
  }

  @objc func toggleControl(_ sender: Any?) {
    Preferences.controlEnabled.toggle()
  }

  /// Escape (the key, or View › Back to the tinySA's Main Screen): the pointer or the pen ends when one is on, else the
  /// analyzer goes back to its graph by its own touches (`EscapeRun`): a number being typed cancelled, a menu closed.
  @objc func escape(_ sender: Any?) {
    if view.tool != .none {
      setTool(.none)
      return
    }
    guard Preferences.controlEnabled else {
      view.flash("Clicks are off, so Escape can't reach the tinySA: View › Control the tinySA by Clicking.")
      return
    }
    guard status.controllable else {
      if status.note == nil { untappable() }  // otherwise the note over the picture says why
      return
    }
    stopEscape()
    escapeRun = EscapeRun(session: session, current: image.flatMap { Snapshot($0) }) { [weak self] message in
      self?.escapeRun = nil
      if let message { self?.view.flash(message) }
    }
  }

  private func stopEscape() {
    escapeRun?.stop()
    escapeRun = nil
  }

  @objc func openRepository(_ sender: Any?) {
    NSWorkspace.shared.open(Self.repository)
  }

  @objc func openIntegrationGuide(_ sender: Any?) {
    NSWorkspace.shared.open(Self.repository.appendingPathComponent("blob/main/docs/INTEGRATION.md"))
  }

  @objc func showAbout(_ sender: Any?) {
    let credits = NSMutableAttributedString(
      string: "The screen of a tinySA spectrum analyzer, live on the Mac.\n"
        + "An independent project, not made by the makers of the tinySA (tinysa.org).\n\n",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
    credits.append(
      NSAttributedString(
        string: "github.com/tolgabalci/tinysa-screen",
        attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Self.repository]))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(saveScreenshot(_:)):
      item.title = "Save Screenshot to \(Preferences.saveFolderName)"
      return image != nil && window.attachedSheet == nil && !gifs.isEditorKey  // ⌘S in the editor saves its GIF
    case #selector(copy(_:)):
      return image != nil && window.attachedSheet == nil && !gifs.isEditorKey  // ⌘C in the editor copies its GIF
    case #selector(toggleControl(_:)):
      item.state = Preferences.controlEnabled ? .on : .off
      return true
    case #selector(togglePointer(_:)):
      item.state = view.tool == .pointer ? .on : .off
      return true
    case #selector(escape(_:)):
      return window.isKeyWindow && window.attachedSheet == nil  // elsewhere Escape does what it does there
    case #selector(togglePen(_:)):
      item.state = view.tool == .pen ? .on : .off
      return true
    case #selector(togglePeakHold(_:)):
      item.state = Preferences.peakHold ? .on : .off
      return status.instrument != .nanoVNA
    case #selector(clearPeakHold(_:)):
      return Preferences.peakHold && status.instrument != .nanoVNA
    case #selector(setPeakWindow(_:)):
      item.state = Preferences.defaults.integer(forKey: Preferences.Key.peakWindow) == item.tag ? .on : .off
      return status.instrument != .nanoVNA
    case #selector(toggleFloatOnTop(_:)):
      item.state = Preferences.floatOnTop ? .on : .off
      return true
    case #selector(toggleRecording(_:)):
      item.title = gifs.isRecording ? "Stop Recording" : "Record GIF"
      return gifs.canRecord
    case #selector(stopAndSaveRecording(_:)):
      item.title = gifs.isRecording ? "Stop and Save Recording" : "Record GIF"
      return gifs.canRecord
    case #selector(actualSize(_:)), #selector(doubleSize(_:)), #selector(tripleSize(_:)):
      return !window.styleMask.contains(.fullScreen)
    default:
      return true
    }
  }
}

extension NSToolbarItem.Identifier {
  static let pointer = NSToolbarItem.Identifier("pointer")
  static let pen = NSToolbarItem.Identifier("pen")
  static let peaks = NSToolbarItem.Identifier("peaks")
  static let band = NSToolbarItem.Identifier("band")
  static let record = NSToolbarItem.Identifier("record")
  static let lastGIF = NSToolbarItem.Identifier("lastGIF")
  /// The room between the buttons, and before the link to the last GIF.
  /// Clear Peaks, beside Peaks while the hold is on.
  static let clearPeaks = NSToolbarItem.Identifier("clearPeaks")
  /// The room between the buttons: before the link to the last GIF the fifth, before Clear Peaks the sixth.
  static let gaps = (1...6).map { NSToolbarItem.Identifier("gap\($0)") }
}

/// The link to the last GIF in the toolbar, with a glow behind it that pulses for a few seconds when a GIF is saved,
/// to show where to find it.
final class LastGIFLink: NSView {
  let button = LinkButton()
  private let glow = NSView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    glow.wantsLayer = true
    glow.alphaValue = 0
    for view in [glow, button] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
        view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }
  }

  required init?(coder: NSCoder) { fatalError("not from a nib") }

  override func layout() {
    super.layout()
    glow.layer?.cornerRadius = glow.bounds.height / 2
  }

  /// The glow, a ring in the accent color around a light wash of it (the link's blue stays easy to read on it), pulses
  /// three times in 4.5 seconds; with Reduce Motion on, it holds still as long.
  func drawAttention() {
    guard let layer = glow.layer else { return }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
      layer.borderColor = NSColor.controlAccentColor.cgColor
    }
    layer.borderWidth = 2
    let seconds: CFTimeInterval = 4.5
    let animation: CAAnimation
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let still = CAKeyframeAnimation(keyPath: "opacity")
      still.values = [0, 1, 1, 0]
      still.keyTimes = [0, 0.05, 0.93, 1]
      still.duration = seconds
      animation = still
    } else {
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0
      pulse.toValue = 1
      pulse.duration = seconds / 6
      pulse.autoreverses = true
      pulse.repeatCount = 3
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animation = pulse
    }
    layer.add(animation, forKey: "attention")  // replacing one still running
  }
}

/// A link in the toolbar: its text in the link color, the pointing hand over it. The toolbar buttons' own bezel, shown
/// only while the mouse is over it, keeps its text on their line (a borderless button's sat 2.5 points lower).
final class LinkButton: NSButton {
  override init(frame: NSRect) {
    super.init(frame: frame)
    bezelStyle = .texturedRounded
    showsBorderOnlyWhileMouseInside = true
  }

  required init?(coder: NSCoder) { fatalError("not from a nib") }

  func setLink(_ title: String) {
    attributedTitle = NSAttributedString(
      string: title,
      attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: ToolbarLook.textSize)])
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
