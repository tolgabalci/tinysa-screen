import AppKit

/// The analyzer's screen, as large as the window allows with its pixels kept sharp, a note over its bottom when the
/// picture isn't live, and clicks turned into taps on the analyzer when it can take them.
final class ScreenView: NSView {
  /// Whether clicks become taps: the picture is live over USB and control is on.
  var controllable = false {
    didSet {
      if controllable != oldValue { window?.invalidateCursorRects(for: self) }
    }
  }
  /// A tap at a pixel of the analyzer's screen: `released` when the button comes up.
  var onTap: ((_ x: Int, _ y: Int, _ released: Bool) -> Void)?

  private let picture = CALayer()
  private var pictureSize = CGSize(width: 480, height: 320)
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
    CATransaction.commit()
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
    statusNote = note
    updateNote()
  }

  /// A note for a moment (a screenshot saved), unless the picture isn't live.
  func flash(_ note: String) {
    flashNote = note
    updateNote()
    flashTimer?.invalidate()
    flashTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.flashNote = nil
        self?.updateNote()
      }
    }
  }

  private func updateNote() {
    let text = statusNote ?? flashNote
    if noteLabel.stringValue != text ?? "" { noteLabel.stringValue = text ?? "" }
    noteBox.isHidden = text == nil
    setAccessibilityValue(statusNote ?? "Live")
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
    if controllable { addCursorRect(pictureRect.rect, cursor: .pointingHand) }
  }

  /// A click on the picture taps the analyzer even while another window is the active one, as in a remote screen
  /// viewer: shared in a call, the call's own window usually is. (View › Control the tinySA by Clicking turns taps off.)
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { controllable }

  /// Where the button went down or last moved to, while it is down: a release always follows a touch, even when the
  /// pointer comes up off the picture.
  private var touching: (x: Int, y: Int)?

  override func mouseDown(with event: NSEvent) {
    guard controllable, let p = pixel(at: event) else { return }
    touching = p
    onTap?(p.x, p.y, false)
  }

  override func mouseDragged(with event: NSEvent) {
    guard touching != nil, Date().timeIntervalSince(lastDrag) > 0.04, let p = pixel(at: event) else { return }
    lastDrag = Date()
    touching = p
    onTap?(p.x, p.y, false)
  }

  override func mouseUp(with event: NSEvent) {
    guard let last = touching else { return }
    let p = pixel(at: event) ?? last
    touching = nil
    onTap?(p.x, p.y, true)
  }
}
