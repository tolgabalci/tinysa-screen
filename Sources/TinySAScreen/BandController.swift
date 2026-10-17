import AppKit
import TinySAKit

/// The Band menu, in the title bar and the menu bar: a click sets the analyzer's span to a band, built in or saved by
/// the user; Back to the span it had before the first band chosen; and Save Current Span as a Band.
@MainActor
final class BandController: NSObject, NSMenuDelegate, NSMenuItemValidation {
  private let session: Session
  private let view: ScreenView
  private weak var window: NSWindow?
  /// The menu of the title bar's Band button: a pull-down, so its first item is the button's own title.
  let toolbarMenu = NSMenu(title: "Band")
  /// The menu bar's Band menu.
  private let menuBarMenu: NSMenu?
  var status = Status(source: "", note: nil, controllable: false) {
    didSet {
      if status != oldValue { refresh() }
    }
  }
  /// The span before the first band was chosen, for Back.
  private var original: SweepRange? {
    didSet { refresh() }
  }
  private var busy = false

  init(session: Session, view: ScreenView, window: NSWindow, menuBarMenu: NSMenu?) {
    self.session = session
    self.view = view
    self.window = window
    self.menuBarMenu = menuBarMenu
    super.init()
    toolbarMenu.delegate = self
    menuBarMenu?.delegate = self
    refresh()
    NotificationCenter.default.addObserver(
      self, selector: #selector(refresh), name: UserDefaults.didChangeNotification, object: nil)
  }

  /// Both menus filled now, not only as they open, so they read right to VoiceOver and other assistive apps.
  @objc func refresh() {
    fill(toolbarMenu)
    if let menuBarMenu { fill(menuBarMenu) }
  }

  /// The title bar's Band button.
  func makeButton() -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    button.bezelStyle = .texturedRounded
    button.menu = toolbarMenu
    button.toolTip = "Set the tinySA to a band"
    button.setAccessibilityLabel("Band")
    return button
  }

  func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

  private func fill(_ menu: NSMenu) {
    menu.removeAllItems()
    if menu === toolbarMenu {
      let title = NSMenuItem(title: "Band", action: nil, keyEquivalent: "")
      title.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
      menu.addItem(title)
    }
    if let reason = unavailableReason {
      let note = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
      note.isEnabled = false
      menu.addItem(note)
      menu.addItem(.separator())
    }
    let saved = Preferences.savedBands
    for (i, group) in ((saved.isEmpty ? [] : [saved]) + BandPreset.builtIn).enumerated() {
      if i > 0 { menu.addItem(.separator()) }
      for band in group { menu.addItem(item(for: band)) }
    }
    menu.addItem(.separator())
    if let original {
      let back = NSMenuItem(title: "Back to \(original.label)", action: #selector(goBack(_:)), keyEquivalent: "")
      back.target = self
      menu.addItem(back)
    }
    let save = NSMenuItem(title: "Save Current Span as a Band…", action: #selector(saveCurrentSpan(_:)), keyEquivalent: "")
    save.target = self
    menu.addItem(save)
  }

  /// "915 MHz (Americas): LoRa, RFID   902–928 MHz", the span in grey.
  private func item(for band: BandPreset) -> NSMenuItem {
    let item = NSMenuItem(title: band.name, action: #selector(choose(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = band
    let title = NSMutableAttributedString(string: band.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
    title.append(
      NSAttributedString(
        string: "   " + band.range.label,
        attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
    item.attributedTitle = title
    item.setAccessibilityLabel("\(band.name), \(band.range.label)")
    return item
  }

  /// Why bands can't be chosen now, or nil.
  private var unavailableReason: String? {
    if status.tunable { return nil }
    if status.source.hasPrefix("Pictures from") { return "\(status.source.dropFirst("Pictures from ".count)) has the tinySA: set its band there" }
    if status.controllable { return "Bands need a tinySA Ultra" }
    return "Bands need the tinySA on USB here"
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    status.tunable && !busy
  }

  @objc private func choose(_ sender: NSMenuItem) {
    guard let band = sender.representedObject as? BandPreset else { return }
    apply(band.range, name: band.name)
  }

  @objc private func goBack(_ sender: Any?) {
    guard let original else { return }
    apply(original, name: nil, back: true)
  }

  private func apply(_ range: SweepRange, name: String?, back: Bool = false) {
    busy = true
    view.flash("Setting the tinySA to \(range.label)…")
    session.sweep(range) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy = false
        switch result {
        case let .success(change):
          if back {
            self.original = nil
          } else if self.original == nil {
            self.original = change.before
          }
          self.view.flash((name.map { "\($0): " } ?? "Back to ") + change.after.label)
        case let .failure(error):
          self.view.flash("The band couldn't be set: \(error)")
        }
      }
    }
  }

  /// Reads the analyzer's span and saves it under a name the user gives.
  @objc private func saveCurrentSpan(_ sender: Any?) {
    busy = true
    session.sweep(nil) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy = false
        switch result {
        case let .success(change): self.askName(for: change.before)
        case let .failure(error): self.view.flash("The span couldn't be read: \(error)")
        }
      }
    }
  }

  private func askName(for range: SweepRange) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Save \(range.label) as a band"
    alert.informativeText = "It goes at the top of the Band menu. Settings removes it."
    let field = NSTextField(string: range.label)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      let name = field.stringValue.trimmingCharacters(in: .whitespaces)
      var saved = Preferences.savedBands.filter { $0.name != name }
      saved.append(BandPreset(name: name.isEmpty ? range.label : name, start: range.start, stop: range.stop))
      Preferences.savedBands = saved
      self.view.flash("Saved the band \(name.isEmpty ? range.label : name)")
    }
  }
}
