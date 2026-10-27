import XCTest

@testable import TinySAKit

final class ScreenStateTests: XCTestCase {
  static let light = Snapshot.pixel(r: 230, g: 230, b: 230)
  static let dark = Snapshot.pixel(r: 0, g: 0, b: 0)

  /// A screen with `colour(x, y)` at each pixel.
  static func screen(_ colour: (Int, Int) -> UInt32) -> Snapshot {
    Snapshot(width: 480, height: 320, pixels: (0..<320).flatMap { y in (0..<480).map { x in colour(x, y) } })
  }

  /// The analyzer's graph, and its number keypad as it drew it tonight, START being typed: Escape taps the erase key.
  func testTheGraphAndTheNumberKeypad() throws {
    for name in ["screen-915.png", "screen-915-big.png", "screen-433.png", "screen-915-burst.png"] {
      XCTAssertEqual(ScreenState.of(try Fixture.screen(name)), .graph, name)
    }
    let keypad = try Fixture.screen("screen-keypad.png")
    XCTAssertEqual(ScreenState.of(keypad), .numberKeypad)
    XCTAssertTrue(ScreenState.of(keypad).isKeypad)
    let tap = try XCTUnwrap(ScreenState.numberKeypad.escapeTap(on: keypad))
    XCTAssertEqual([tap.x, tap.y], [300, 252])
  }

  /// Menus down the right edge, over the graph, as the analyzer drew them (the main menu, FREQUENCY, and SPEED, the
  /// quick menu of the Scan label, which stops short of the bottom): Escape taps the graph beside them.
  func testRealMenus() throws {
    for name in ["screen-menu.png", "screen-menu-frequency.png", "screen-menu-speed.png"] {
      let menu = try Fixture.screen(name)
      XCTAssertEqual(ScreenState.of(menu), .menu, name)
      XCTAssertFalse(ScreenState.of(menu).isKeypad, name)
      let tap = try XCTUnwrap(ScreenState.menu.escapeTap(on: menu))
      XCTAssertEqual([tap.x, tap.y], [120, 160], name)
    }
  }

  /// A menu down the right edge, over the graph: Escape taps the graph beside it.
  func testAMenuOverTheGraph() throws {
    let graph = try Fixture.screen("screen-915.png")
    var menu = graph
    for y in 0..<320 {
      for x in 400..<480 {
        // Light buttons with a line of dark words in each.
        menu.pixels[y * 480 + x] = (y % 29 > 20 && x % 7 < 3) ? Self.dark : Self.light
      }
    }
    XCTAssertEqual(ScreenState.of(menu), .menu)
    XCTAssertFalse(ScreenState.of(menu).isKeypad)
    let tap = try XCTUnwrap(ScreenState.menu.escapeTap(on: menu))
    XCTAssertEqual([tap.x, tap.y], [120, 160])
  }

  /// A keypad without the number keypad's columns (a name being typed): Escape leaves it to the analyzer's own keys.
  func testAnotherKeypad() {
    let keys = Self.screen { x, y in (x % 48 == 0 || y % 40 == 0) ? Self.dark : Self.light }
    XCTAssertEqual(ScreenState.of(keys), .keypad)
    XCTAssertNil(ScreenState.keypad.escapeTap(on: keys))
    XCTAssertNil(ScreenState.graph.escapeTap(on: keys))
  }
}
