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
  private let recordButton = NSButton()
  private let captureButton = NSButton()
  private let pointerButton = NSButton()
  private let penButton = NSButton()
  private let peaksButton = NSButton()
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
    setUpToolbarButton(recordButton, "Record", symbol: "record.circle", action: #selector(toggleRecording(_:)))
    setUpToolbarButton(captureButton, "Capture", symbol: "clock.arrow.circlepath", action: #selector(capture(_:)))
    setUpToolbarButton(pointerButton, "Pointer", symbol: "cursorarrow.rays", action: #selector(togglePointer(_:)))
    setUpToolbarButton(penButton, "Pen", symbol: "pencil.tip", action: #selector(togglePen(_:)))
    setUpToolbarButton(peaksButton, "Peaks", symbol: "chart.xyaxis.line", action: #selector(togglePeakHold(_:)))
    peaksButton.setButtonType(.pushOnPushOff)
    peaksButton.toolTip = "Hold the highest level at each frequency and label the highest peaks, on the Mac (⌥⌘P)"
    peakHold.onChange = { [weak self] state in
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
    window.title = "tinySA Screen"
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

  /// A recording in progress is stopped and saved, and GIFs being made are written, before the app quits (at most 15
  /// seconds).
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
    if status.instrument == .nanoVNA { view.showPeaks(nil) }
    updateSubtitle()
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

  /// The window's subtitle: where the picture comes from, and who records it from outside.
  private func updateSubtitle() {
    let recording = otherRecordings.isEmpty ? "" : " · recording for \(otherRecordings.joined(separator: ", "))"
    window.subtitle = status.source + recording
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

  /// Settings changed (here or in the Settings window): Capture keeps what they say, clicks tap or don't.
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

  // MARK: The toolbar: Record and Capture

  private func setUpToolbarButton(_ button: NSButton, _ title: String, symbol: String, action: Selector) {
    button.title = title
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.target = self
    button.action = action
    button.bezelStyle = .texturedRounded
    button.imagePosition = .imageLeading
    button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .pointer, .pen, .peaks, .band, .record, .capture]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .pointer, .pen, .peaks, .band, .record] + (Preferences.keptSeconds > 0 ? [.capture] : [])
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    // At the narrowest window, the pointer, pen and peaks go to the overflow menu first, Record and Capture last; in
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
      item.view = peaksButton
      item.menuFormRepresentation = menuForm("Peak Hold", #selector(togglePeakHold(_:)))
    case .band:
      item.label = "Band"
      item.view = bands.makeButton()
      let form = NSMenuItem(title: "Band", action: nil, keyEquivalent: "")
      form.submenu = bands.overflowMenu
      item.menuFormRepresentation = form
    case .record:
      item.label = "Record"
      item.view = recordButton
      item.menuFormRepresentation = menuForm("Record GIF", #selector(toggleRecording(_:)))
      item.visibilityPriority = .high
    case .capture:
      item.label = "Capture"
      item.view = captureButton
      item.menuFormRepresentation = menuForm("Capture as GIF…", #selector(capture(_:)))
      item.visibilityPriority = .high
    default:
      return nil
    }
    return item
  }

  /// The Record button shows the time recorded and turns into Stop; Capture is there while seconds are kept.
  private func updateGIFControls() {
    if gifs.isRecording {
      recordButton.title = CaptureSheet.duration(gifs.elapsed.rounded(.down))
      recordButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
      recordButton.contentTintColor = .systemRed
      recordButton.toolTip =
        "Stop recording and save the GIF to \(Preferences.saveFolderName) (⌘R). A recording stops by itself at 2:00."
      recordButton.setAccessibilityLabel("Stop recording, \(Int(gifs.elapsed)) seconds recorded")
    } else {
      recordButton.title = "Record"
      recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
      recordButton.contentTintColor = nil
      recordButton.toolTip =
        "Record a GIF of the screen until you stop it, up to 2 minutes, saved to \(Preferences.saveFolderName) (⌘R)"
      recordButton.setAccessibilityLabel("Record a GIF")
    }
    let kept = Preferences.keptSeconds
    captureButton.toolTip = "Save the last \(CaptureSheet.duration(Double(kept))), or part of them, as a GIF (⇧⌘R)"
    guard let toolbar = window.toolbar else { return }
    let index = toolbar.items.firstIndex { $0.itemIdentifier == .capture }
    if kept > 0, index == nil {
      toolbar.insertItem(withItemIdentifier: .capture, at: toolbar.items.count)
    } else if kept == 0, let index {
      toolbar.removeItem(at: index)
    }
  }

  @objc func toggleRecording(_ sender: Any?) {
    gifs.toggleRecording()
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
    view.peakColor = Preferences.peakColor.color
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

  @objc func capture(_ sender: Any?) {
    gifs.capture()
  }

  // MARK: Menu actions

  @objc func saveScreenshot(_ sender: Any?) {
    guard let image else { return }
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
    guard let image else { return }
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
      return image != nil && window.attachedSheet == nil  // ⌘S in the Capture sheet saves its GIF
    case #selector(copy(_:)):
      return image != nil && window.attachedSheet == nil  // ⌘C in the Capture sheet copies its GIF
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
      return gifs.isRecording || session.recorder.hasSnapshot
    case #selector(capture(_:)):
      let kept = Preferences.keptSeconds
      item.title = kept > 0 ? "Capture Last \(CaptureSheet.duration(Double(kept))) as GIF…" : "Capture as GIF…"
      return kept > 0 && gifs.canCapture
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
  static let capture = NSToolbarItem.Identifier("capture")
}
