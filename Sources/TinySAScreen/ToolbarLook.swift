import AppKit

/// The toolbar's look: macOS 13's (the app keeps it, see scripts/build-app.sh), with larger words and symbols, bright
/// while the window is the one in front and dimmer behind, as macOS draws the toolbars of apps in its current look. In
/// macOS 13's look a bordered toolbar button's words stay grey in front too, whatever color they're given, so the
/// buttons with words are borderless, in an outline of their own like that border (`OutlinedToolbarItem`).
@MainActor
enum ToolbarLook {
  /// The size of the toolbar's words and symbols (macOS's own are 13 points).
  static let textSize: CGFloat = 16

  /// Digits of one width, so Stop's time doesn't jiggle as it counts.
  static var font: NSFont { .monospacedDigitSystemFont(ofSize: textSize, weight: .regular) }

  #if DEBUG
    /// For the window demo: the toolbar drawn as in the window in front, while the app stays behind.
    static var drawnInFront = false
  #endif

  /// The window is the one in front: the main window of the app in front.
  static func isInFront(_ window: NSWindow?) -> Bool {
    #if DEBUG
      if drawnInFront { return true }
    #endif
    guard let window else { return false }
    return window.isMainWindow && NSApp.isActive
  }

  /// The color of a control's words and symbol: its own tint (Stop's red), else bright in the window in front, dimmer
  /// behind; dimmer still while it can't be used.
  static func ink(for control: NSControl, tint: NSColor?) -> NSColor {
    guard control.isEnabled else { return .tertiaryLabelColor }
    if let tint { return tint }
    return isInFront(control.window) ? .labelColor : .secondaryLabelColor
  }

  static func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: textSize, weight: .regular))
  }

  /// The toolbar's buttons drawn again: the window came in front or went behind.
  static func redraw(_ toolbar: NSToolbar?) {
    for item in toolbar?.items ?? [] {
      item.view?.needsDisplay = true
      item.view?.subviews.forEach { $0.needsDisplay = true }
    }
  }

}

/// `title` in `color`.
private func inked(_ title: NSAttributedString, _ color: NSColor) -> NSAttributedString {
  let inked = NSMutableAttributedString(attributedString: title)
  inked.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: inked.length))
  return inked
}

/// A symbol in `color`: AppKit would draw a template image in its own grey.
private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
  guard image.isTemplate else { return image }
  let tinted = NSImage(size: image.size, flipped: false) { rect in
    image.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    return true
  }
  tinted.accessibilityDescription = image.accessibilityDescription
  return tinted
}

/// A button's cell drawing its words and symbol in the toolbar's ink.
final class InkedButtonCell: NSButtonCell {
  override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
    guard let button = controlView as? NSButton else {
      return super.drawTitle(title, withFrame: frame, in: controlView)
    }
    let ink = MainActor.assumeIsolated { ToolbarLook.ink(for: button, tint: button.contentTintColor) }
    return super.drawTitle(inked(title, ink), withFrame: frame, in: controlView)
  }

  override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
    guard let button = controlView as? NSButton else {
      return super.drawImage(image, withFrame: frame, in: controlView)
    }
    let ink = MainActor.assumeIsolated { ToolbarLook.ink(for: button, tint: button.contentTintColor) }
    super.drawImage(tinted(image, ink), withFrame: frame, in: controlView)
  }
}

/// A toolbar button in the toolbar's ink: with words, borderless, a little room either side of them, inside an
/// `OutlinedToolbarItem`; a symbol alone, as AppKit draws it.
final class ToolbarButton: NSButton {
  override class var cellClass: AnyClass? {
    get { InkedButtonCell.self }
    set {}
  }

  /// Its colors as given, not blended into the title bar's.
  override var allowsVibrancy: Bool { false }

  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize
    return isBordered ? size : NSSize(width: size.width + 16, height: max(size.height, 28))
  }

  // The outline around it shows it on, or pressed.
  override var state: NSControl.StateValue {
    didSet { superview?.needsDisplay = true }
  }

  override func highlight(_ flag: Bool) {
    super.highlight(flag)
    superview?.needsDisplay = true
  }

  /// A menu shown below the button as it's pressed, as a pop-up button shows its menu (Band's): its outline has the
  /// pop-up's chevron.
  var menuOnPress: NSMenu?

  override func mouseDown(with event: NSEvent) {
    guard menuOnPress != nil, isEnabled else { return super.mouseDown(with: event) }
    showMenu()
  }

  /// The menu below the button's outline, the button pressed while it's open.
  func showMenu() {
    guard let menu = menuOnPress else { return }
    let outline = superview ?? self
    highlight(true)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: outline.isFlipped ? outline.bounds.height + 4 : -4), in: outline)
    highlight(false)
  }
}

/// A toolbar button with words, borderless, in an outline drawn here like macOS 13's toolbar border: filled while the
/// button is on or pressed; with a chevron at its right for a button with a menu.
final class OutlinedToolbarItem: NSView {
  let button: ToolbarButton
  private let chevronWidth: CGFloat

  init(_ button: ToolbarButton) {
    self.button = button
    chevronWidth = button.menuOnPress == nil ? 0 : 14
    super.init(frame: .zero)
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -chevronWidth),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("not from a nib") }

  override var allowsVibrancy: Bool { false }

  /// A press on the chevron is a press on the button.
  override func mouseDown(with event: NSEvent) {
    button.mouseDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    if button.state == .on || button.isHighlighted {
      NSColor.labelColor.withAlphaComponent(button.isHighlighted ? 0.2 : 0.14).setFill()
      outline.fill()
    }
    NSColor.labelColor.withAlphaComponent(0.2).setStroke()
    outline.lineWidth = 1
    outline.stroke()
    guard chevronWidth > 0,
      let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    else { return }
    let size = chevron.size
    let place = NSRect(
      x: (bounds.maxX - chevronWidth - 4 + (chevronWidth - size.width) / 2).rounded(),
      y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    tinted(chevron, ToolbarLook.ink(for: button, tint: nil)).draw(in: place)
  }
}
