/// What the analyzer's screen shows over its graph, read from its pixels: its number keypad (a value being typed),
/// another keypad (a name being typed), a menu (the light column at its right), or just the graph. Escape gets back to
/// the graph with the analyzer's own touches: the number keypad's erase key (a character a press, then, with nothing
/// typed, the keypad, nothing changed), and for a menu a tap on the graph beside it (the firmware closes a menu on a
/// touch outside it).
///
/// The keypad matters beyond Escape: while it is open the analyzer doesn't sweep, so `waitscan` holds its console until
/// the keypad closes (or its jog wheel moves), and a command the sweep runs (`sweep`, `menu`, `pause`, `data`) gives up
/// after 20 s with "Command timeout" and no prompt; `touch`, `release`, `status` and `capture` still answer.
public enum ScreenState: Equatable, Sendable {
  case graph
  case menu
  case numberKeypad
  /// A keypad other than the number keypad (a name being typed): its own keys close it.
  case keypad

  public static func of(_ screen: Snapshot) -> ScreenState {
    if keypadOpen(screen) { return numberKeypad(screen) ? .numberKeypad : .keypad }
    return menuOpen(screen) ? .menu : .graph
  }

  /// Whether the analyzer waits on a keypad, not sweeping.
  public var isKeypad: Bool { self == .numberKeypad || self == .keypad }

  /// Where Escape taps on the analyzer's screen in this state: the number keypad's erase key, or the graph left of a
  /// menu; nil on the graph, and on a keypad Escape can't close.
  public func escapeTap(on screen: Snapshot) -> (x: Int, y: Int)? {
    switch self {
    case .numberKeypad: return Self.erase
    case .menu: return (screen.width / 4, screen.height / 2)
    case .graph, .keypad: return nil
    }
  }

  /// The number keypad's erase key (the firmware's KP_BS): the third key of its bottom row, on the tinySA Ultra's
  /// screen of 480 × 320, whose keypad is 4 × 4 keys of 120 × 72 pixels over the line with the value typed.
  static let erase = (x: 300, y: 252)

  /// A colour over about 150 of 255 in red, green and blue: a key, a menu button, white text; the graph is black.
  static func light(_ screen: Snapshot, _ x: Int, _ y: Int) -> Bool {
    let (r, g, b) = screen.rgb(x: x, y: y)
    return r > 150 && g > 150 && b > 150
  }

  /// Light over most of the screen, above the line along its bottom.
  static func keypadOpen(_ screen: Snapshot) -> Bool {
    var light = 0
    var count = 0
    for y in stride(from: 0, to: max(screen.height - 40, 0), by: 8) {
      for x in stride(from: 0, to: screen.width, by: 8) {
        count += 1
        if Self.light(screen, x, y) { light += 1 }
      }
    }
    return count > 0 && Double(light) > 0.6 * Double(count)
  }

  /// The number keypad's columns: light key faces with darker lines between them, on the tinySA Ultra's screen.
  static func numberKeypad(_ screen: Snapshot) -> Bool {
    guard screen.width == 480, screen.height == 320 else { return false }
    let faces = [60, 180, 300, 420].allSatisfy { Self.light(screen, $0, 10) }
    let lines = [121, 241, 361].allSatisfy { !Self.light(screen, $0, 10) }
    return faces && lines
  }

  /// A menu: its buttons, light with dark words, down the right edge (80 pixels of the Ultra's 480), where the graph
  /// has its black margin and scale.
  static func menuOpen(_ screen: Snapshot) -> Bool {
    let left = screen.width - screen.width / 6 + 4
    var light = 0
    var count = 0
    for y in stride(from: 4, to: screen.height - 24, by: 4) {
      for x in stride(from: left, to: screen.width - 4, by: 4) {
        count += 1
        if Self.light(screen, x, y) { light += 1 }
      }
    }
    return count > 0 && Double(light) > 0.45 * Double(count)
  }
}
