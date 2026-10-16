import AppKit
import ImageIO
import TinySAKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, SessionDelegate {
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

  /// Clicks on the picture tap the analyzer's screen (View › Control the tinySA by Clicking).
  private var controlEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "controlEnabled") as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: "controlEnabled")
      view.controllable = status.controllable && newValue
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    window.title = "tinySA Screen"
    window.contentView = view
    window.contentAspectRatio = NSSize(width: 480, height: 320)
    window.contentMinSize = NSSize(width: 480, height: 320)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.isReleasedWhenClosed = false
    if !window.setFrameUsingName("tinySA Screen") { window.center() }
    window.setFrameAutosaveName("tinySA Screen")
    window.makeKeyAndOrderFront(nil)
    view.onTap = { [weak self] x, y, released in
      if released { self?.session.release(x: x, y: y) } else { self?.session.touch(x: x, y: y) }
    }
    session.delegate = self
    session.start()
    if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
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
    window.subtitle = status.source
    view.say(status.note)
    view.controllable = status.controllable && controlEnabled
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
    controlEnabled.toggle()
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
      item.state = controlEnabled ? .on : .off
      return true
    case #selector(actualSize(_:)), #selector(doubleSize(_:)), #selector(tripleSize(_:)):
      return !window.styleMask.contains(.fullScreen)
    default:
      return true
    }
  }
}
