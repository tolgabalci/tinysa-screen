import AppKit
import ImageIO
import TinySAKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSToolbarDelegate, SessionDelegate {
  static let repository = URL(string: "https://github.com/tolgabalci/tinysa-screen")!

  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
  private let view = ScreenView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
  private let session = Session()
  private var image: CGImage?
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
  private var keptSeconds = -1

  func applicationDidFinishLaunching(_ notification: Notification) {
    Preferences.register()
    // The toolbar asks for its buttons as soon as it is set: they come first.
    gifs = GIFController(recorder: session.recorder, window: window, view: view)
    let bandMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Band" }?.submenu
    bands = BandController(session: session, view: view, window: window, menuBarMenu: bandMenu)
    gifs.onChange = { [weak self] in self?.updateGIFControls() }
    setUpToolbarButton(recordButton, "Record", symbol: "record.circle", action: #selector(toggleRecording(_:)))
    setUpToolbarButton(captureButton, "Capture", symbol: "clock.arrow.circlepath", action: #selector(capture(_:)))
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
    window.makeKeyAndOrderFront(nil)
    view.onTap = { [weak self] x, y, released in
      if released { self?.session.release(x: x, y: y) } else { self?.session.touch(x: x, y: y) }
    }
    preferencesChanged()
    NotificationCenter.default.addObserver(
      self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
    startControl()
    session.delegate = self
    session.start()
    if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    control?.stop()
    gifs.stopRecording()
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
    self.status = status
    updateSubtitle()
    gifs.source = status.source
    bands.status = status
    view.say(status.note)
    view.controllable = status.controllable && Preferences.controlEnabled
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
    [.flexibleSpace, .band, .record, .capture]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .band, .record] + (Preferences.keptSeconds > 0 ? [.capture] : [])
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    switch identifier {
    case .band:
      item.label = "Band"
      item.view = bands.makeButton()
    case .record:
      item.label = "Record"
      item.view = recordButton
    case .capture:
      item.label = "Capture"
      item.view = captureButton
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
      recordButton.toolTip = "Stop recording and save the GIF to the Desktop (⌘R). A recording stops by itself at 2:00."
      recordButton.setAccessibilityLabel("Stop recording, \(Int(gifs.elapsed)) seconds recorded")
    } else {
      recordButton.title = "Record"
      recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
      recordButton.contentTintColor = nil
      recordButton.toolTip = "Record a GIF of the screen until you stop it, up to 2 minutes, saved to the Desktop (⌘R)"
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

  @objc func capture(_ sender: Any?) {
    gifs.capture()
  }

  // MARK: Menu actions

  @objc func saveScreenshot(_ sender: Any?) {
    guard let image else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let name = "tinySA \(formatter.string(from: Date())).png"
    let folder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    let url = folder.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) {
      view.flash("Saved to the Desktop: \(name)")
    } else {
      view.flash("The screenshot couldn't be saved.")
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
    case #selector(saveScreenshot(_:)), #selector(copy(_:)):
      return image != nil
    case #selector(toggleControl(_:)):
      item.state = Preferences.controlEnabled ? .on : .off
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
  static let band = NSToolbarItem.Identifier("band")
  static let record = NSToolbarItem.Identifier("record")
  static let capture = NSToolbarItem.Identifier("capture")
}
