import AppKit
import TinySAKit

/// The analyzer's screen, as large as the window allows with its pixels kept sharp, a note over its bottom when the
/// picture isn't live, and clicks turned into taps on the analyzer when it can take them. For presenting, the pointer
/// (a red dot following the mouse, which a call shows even when it doesn't show the cursor) and the pen (strokes that
/// fade after a few seconds) take the mouse instead.
final class ScreenView: NSView {
  enum Tool { case none, pointer, pen }

  /// The presenter's tool, or none: clicks tap the analyzer.
  var tool = Tool.none {
    didSet {
      guard tool != oldValue else { return }
      // A touch down on the analyzer when the tool came on is let go of now: the analyzer would wait for it, its
      // sweep stopped.
      if let held = touching {
        touching = nil
        onTap?(held.x, held.y, true)
      }
      if drawing != nil { endStroke() }
      pointer.isHidden = true
      window?.invalidateCursorRects(for: self)
      setAccessibilityValue(accessibilityText)
    }
  }
  /// Seconds a pen stroke stays before it fades.
  var inkSeconds: TimeInterval = 3
  /// Escape pressed: the tool ends, or the analyzer goes back to its graph.
  var onEscape: (() -> Void)?
  /// Whether clicks become taps: the picture is live over USB, or comes from a feeder that passes taps on, and control
  /// is on.
  var controllable = false {
    didSet {
      if controllable != oldValue { window?.invalidateCursorRects(for: self) }
    }
  }
  /// Whether a tap shows where it went, a small ring: through a feeder the analyzer's answer comes with its next
  /// picture, up to a second later.
  var tapEcho = false
  /// A tap at a pixel of the analyzer's screen: `released` when the button comes up.
  var onTap: ((_ x: Int, _ y: Int, _ released: Bool) -> Void)?
  /// A click on the picture that can't tap the analyzer.
  var onUntappable: (() -> Void)?

  private let picture = CALayer()
  private var pictureSize = CGSize(width: 480, height: 320)
  private let pointer = CALayer()
  private let ink = CALayer()
  private let peaks = PeakOverlay()
  /// The pen's strokes, in fractions of the picture (0 to 1 across and down from the top left), so they stay on what
  /// they mark when the window changes size.
  private var strokes: [(layer: CAShapeLayer, points: [CGPoint])] = []
  /// The stroke being drawn (strokes before it may fade and go meanwhile).
  private var drawing: CAShapeLayer?
  private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
  private let noteBox = NSView()
  private let noteLabel = NSTextField(wrappingLabelWithString: "")
  private var statusNote: String?
  private var flashNote: String?
  private var flashTimer: Timer?
  private var lastDrag = Date.distantPast

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    picture.contentsGravity = .resizeAspect
    picture.magnificationFilter = .nearest  // the analyzer's pixels, sharp, as on its own screen
    picture.minificationFilter = .trilinear
    layer?.addSublayer(picture)
    layer?.addSublayer(peaks.layer)
    layer?.addSublayer(ink)
    pointer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
    pointer.cornerRadius = 9
    pointer.backgroundColor = NSColor.systemRed.cgColor
    pointer.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
    pointer.borderWidth = 1.5
    pointer.shadowColor = NSColor.systemRed.cgColor
    pointer.shadowOpacity = 0.9
    pointer.shadowRadius = 10
    pointer.shadowOffset = .zero
    pointer.isHidden = true
    pointer.zPosition = 10
    layer?.addSublayer(pointer)

    noteBox.wantsLayer = true
    noteBox.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
    noteBox.layer?.cornerRadius = 8
    noteBox.isHidden = true
    noteBox.translatesAutoresizingMaskIntoConstraints = false
    noteLabel.font = .systemFont(ofSize: 14, weight: .medium)
    noteLabel.textColor = .white
    noteLabel.alignment = .center
    noteLabel.translatesAutoresizingMaskIntoConstraints = false
    noteBox.addSubview(noteLabel)
    addSubview(noteBox)
    NSLayoutConstraint.activate([
      noteLabel.leadingAnchor.constraint(equalTo: noteBox.leadingAnchor, constant: 14),
      noteLabel.trailingAnchor.constraint(equalTo: noteBox.trailingAnchor, constant: -14),
      noteLabel.topAnchor.constraint(equalTo: noteBox.topAnchor, constant: 9),
      noteLabel.bottomAnchor.constraint(equalTo: noteBox.bottomAnchor, constant: -9),
      noteBox.centerXAnchor.constraint(equalTo: centerXAnchor),
      noteBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
      noteBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -36),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("tinySA screen")
  }

  required init?(coder: NSCoder) { fatalError("not from a nib") }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    picture.frame = bounds
    ink.frame = bounds
    for stroke in strokes { stroke.layer.path = path(stroke.points) }
    CATransaction.commit()
    drawPeaks()
  }

  /// The peak hold over the picture, or nothing (nil).
  func showPeaks(_ state: PeakHold.State?) {
    peakState = state
    drawPeaks()
    setAccessibilityValue(accessibilityText)
  }

  private var peakState: PeakHold.State?

  /// The peak hold's colour.
  var peakColor: NSColor {
    get { peaks.color }
    set {
      guard newValue != peaks.color else { return }
      peaks.color = newValue
      drawPeaks()
    }
  }

  private func drawPeaks() {
    let (rect, scale) = pictureRect
    peaks.show(peakState, in: rect, scale: scale, contentsScale: window?.backingScaleFactor ?? 2)
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    drawPeaks()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {  // Escape
      onEscape?()
    } else {
      super.keyDown(with: event)
    }
  }

  func show(_ image: CGImage) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    picture.contents = image
    CATransaction.commit()
    let size = CGSize(width: image.width, height: image.height)
    if size != pictureSize {
      pictureSize = size
      window?.invalidateCursorRects(for: self)
    }
  }

  /// Why the picture isn't live, or nil.
  func say(_ note: String?) {
    if let note, note != statusNote { announce(note) }
    statusNote = note
    updateNote()
  }

  /// A note for a moment (a screenshot saved), unless the picture isn't live.
  func flash(_ note: String) {
    flashNote = note
    updateNote()
    announce(note)
    flashTimer?.invalidate()
    let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.flashNote = nil
        self?.updateNote()
      }
    }
    RunLoop.main.add(timer, forMode: .common)  // also while a menu is open
    flashTimer = timer
  }

  /// VoiceOver says the note too: it's shown only for a moment.
  private func announce(_ text: String) {
    NSAccessibility.post(
      element: self, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  private func updateNote() {
    let text = statusNote ?? flashNote
    if noteLabel.stringValue != text ?? "" { noteLabel.stringValue = text ?? "" }
    noteBox.isHidden = text == nil
    setAccessibilityValue(accessibilityText)
  }

  private var accessibilityText: String {
    var text = statusNote ?? "Live"
    switch tool {
    case .pointer: text += ", pointer on"
    case .pen: text += ", pen on"
    case .none: break
    }
    if let state = peakState, let scale = state.scale {
      let span = Double(scale.stop - scale.start) / Double(max(state.graph.right - state.graph.left - 1, 1))
      let peaks = state.peaks.sorted { $0.number < $1.number }.compactMap { peak -> String? in
        guard let frequency = peak.frequency, let level = peak.level else { return nil }
        return "\(peak.number) " + PeakOverlay.frequency(frequency, resolution: span) + " "
          + PeakOverlay.level(level, resolution: abs(scale.perRow))
      }
      text += ". " + PeakOverlay.title(state) + ": " + (peaks.isEmpty ? "no peaks" : peaks.joined(separator: "; "))
    }
    return text
  }

  // MARK: Taps

  /// Where the picture is drawn in the view, and how many points a pixel of it takes.
  private var pictureRect: (rect: CGRect, scale: CGFloat) {
    let scale = min(bounds.width / pictureSize.width, bounds.height / pictureSize.height)
    let size = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
    let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
    return (CGRect(origin: origin, size: size), scale)
  }

  /// The analyzer's pixel under a point of the view (its screen counts from the top left).
  private func pixel(at event: NSEvent) -> (x: Int, y: Int)? {
    let point = convert(event.locationInWindow, from: nil)
    let (rect, scale) = pictureRect
    guard scale > 0, rect.contains(point) else { return nil }
    let x = Int((point.x - rect.minX) / scale)
    let y = Int((rect.maxY - point.y) / scale)
    return (min(max(x, 0), Int(pictureSize.width) - 1), min(max(y, 0), Int(pictureSize.height) - 1))
  }

  override func resetCursorRects() {
    switch tool {
    case .pointer: addCursorRect(pictureRect.rect, cursor: Self.blankCursor)  // the red dot is the pointer
    case .pen: addCursorRect(pictureRect.rect, cursor: .crosshair)
    case .none: if controllable { addCursorRect(pictureRect.rect, cursor: .pointingHand) }
    }
  }

  /// A click on the picture taps the analyzer (or points, or draws) even while another window is the active one, as in
  /// a remote screen viewer: shared in a call, the call's own window usually is. (View › Control the tinySA by Clicking
  /// turns taps off.)
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { controllable || tool != .none }

  // MARK: Pointer and pen

  override func mouseMoved(with event: NSEvent) {
    guard tool == .pointer else { return }
    let point = convert(event.locationInWindow, from: nil)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pointer.position = point
    pointer.isHidden = !pictureRect.rect.contains(point)
    CATransaction.commit()
  }

  override func mouseExited(with event: NSEvent) {
    pointer.isHidden = true
  }

  /// A ring that grows and fades where the pointer clicks (look here), or smaller where a tap went.
  private func ripple(at point: CGPoint, radius: CGFloat = 30, color: NSColor = .systemRed, width: CGFloat = 3) {
    let ring = CAShapeLayer()
    ring.path = CGPath(
      ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
    ring.position = point
    ring.fillColor = nil
    ring.strokeColor = color.cgColor
    ring.lineWidth = width
    ring.opacity = 0
    layer?.addSublayer(ring)
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.3
    grow.toValue = 1.2
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    let both = CAAnimationGroup()
    both.animations = [grow, fade]
    both.duration = 0.6
    CATransaction.begin()
    CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
    ring.add(both, forKey: "ripple")
    CATransaction.commit()
  }

  /// A point of the view as a fraction of the picture.
  private func fraction(_ point: CGPoint) -> CGPoint {
    let rect = pictureRect.rect
    return CGPoint(x: (point.x - rect.minX) / rect.width, y: (rect.maxY - point.y) / rect.height)
  }

  private func path(_ fractions: [CGPoint]) -> CGPath {
    let rect = pictureRect.rect
    let path = CGMutablePath()
    for (i, f) in fractions.enumerated() {
      let point = CGPoint(x: rect.minX + f.x * rect.width, y: rect.maxY - f.y * rect.height)
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }

  private func startStroke(at point: CGPoint) {
    let stroke = CAShapeLayer()
    stroke.fillColor = nil
    stroke.strokeColor = NSColor.systemRed.cgColor
    stroke.lineWidth = 3.5
    stroke.lineCap = .round
    stroke.lineJoin = .round
    stroke.shadowColor = NSColor.black.cgColor
    stroke.shadowOpacity = 0.7
    stroke.shadowRadius = 1.5
    stroke.shadowOffset = .zero
    let points = [fraction(point)]
    stroke.path = path(points)
    ink.addSublayer(stroke)
    strokes.append((stroke, points))
    drawing = stroke
  }

  private func continueStroke(to point: CGPoint) {
    guard let drawing, let i = strokes.firstIndex(where: { $0.layer === drawing }) else { return }
    strokes[i].points.append(fraction(point))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drawing.path = path(strokes[i].points)
    CATransaction.commit()
  }

  /// The stroke stays for `inkSeconds`, then fades away.
  private func endStroke() {
    guard let layer = drawing else { return }
    drawing = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + inkSeconds) { [weak self] in
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.8)
      CATransaction.setCompletionBlock {
        layer.removeFromSuperlayer()
        self?.strokes.removeAll { $0.layer === layer }
      }
      layer.opacity = 0
      CATransaction.commit()
    }
  }

  /// Every stroke gone at once.
  func clearInk() {
    for stroke in strokes { stroke.layer.removeFromSuperlayer() }
    strokes.removeAll()
    drawing = nil
  }

  /// Where the button went down or last moved to, while it is down: a release always follows a touch, even when the
  /// pointer comes up off the picture.
  private var touching: (x: Int, y: Int)?
  /// A long press: the tinySA acts on a touch held half a second (on its keypad the erase key clears the entry; a
  /// value in a form slides while held). Holding the button is one; a right-click (a two-finger click, Control-click)
  /// is one without holding it, its touch released no sooner than this after it went down.
  static let longPress: TimeInterval = 0.6
  private var pressedAt = Date.distantPast
  private var longPressing = false
  /// Counts presses, so a long press's late release is for its own press only.
  private var pressID = 0

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    switch tool {
    case .pointer:
      if pictureRect.rect.contains(point) { ripple(at: point) }
      return
    case .pen:
      if pictureRect.rect.contains(point) { startStroke(at: point) }
      return
    case .none:
      break
    }
    press(event, long: event.modifierFlags.contains(.control))
  }

  override func rightMouseDown(with event: NSEvent) {
    if tool == .none { press(event, long: true) }
  }

  override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
  override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

  /// A touch down where the button went down, held at least `longPress` when `long`.
  private func press(_ event: NSEvent, long: Bool) {
    let point = convert(event.locationInWindow, from: nil)
    guard controllable, let p = pixel(at: event) else {
      if pictureRect.rect.contains(point) { onUntappable?() }
      return
    }
    if let held = touching {  // a long press still down for its half second: let go of it first
      pressID += 1
      onTap?(held.x, held.y, true)
    }
    touching = p
    longPressing = long
    pressedAt = Date()
    if tapEcho { ripple(at: point, radius: 14, color: .white, width: 2) }
    onTap?(p.x, p.y, false)
  }

  override func mouseDragged(with event: NSEvent) {
    if tool == .pen {
      continueStroke(to: convert(event.locationInWindow, from: nil))
      return
    }
    if tool == .pointer {
      mouseMoved(with: event)
      return
    }
    guard touching != nil, Date().timeIntervalSince(lastDrag) > 0.04, let p = pixel(at: event) else { return }
    lastDrag = Date()
    touching = p
    onTap?(p.x, p.y, false)
  }

  override func mouseUp(with event: NSEvent) {
    if tool == .pen { endStroke() }
    guard let last = touching else { return }  // a touch is always released, whatever the tool now
    let p = pixel(at: event) ?? last
    let held = Date().timeIntervalSince(pressedAt)
    if longPressing, held < Self.longPress {
      // A right-click: the analyzer lets go once it has held the touch long enough.
      pressID += 1
      let id = pressID
      touching = p
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPress - held) { [weak self] in
        guard let self, self.pressID == id, self.touching != nil else { return }
        self.touching = nil
        self.onTap?(p.x, p.y, true)
      }
      return
    }
    touching = nil
    onTap?(p.x, p.y, true)
  }
}
