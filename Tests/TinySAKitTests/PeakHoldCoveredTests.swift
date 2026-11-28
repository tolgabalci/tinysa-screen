import XCTest

@testable import TinySAKit

/// What covers the analyzer's graph isn't its trace: the peak hold takes nothing from under a menu, whose buttons down
/// the screen's right side read as levels at the top of the graph (held there as peaks at +10 dBm), nor from a frame
/// with a keypad over the graph.
final class PeakHoldCoveredTests: XCTestCase {
  let start = Date(timeIntervalSinceReferenceDate: 1000)

  func testAMenuIsNotTheTrace() throws {
    let graph = try Fixture.screen("screen-915.png")
    let hold = PeakHold()
    hold.add(graph, at: start)
    let before = try XCTUnwrap(hold.state)
    for (k, name) in ["screen-menu.png", "screen-menu-frequency.png", "screen-menu-speed.png"].enumerated() {
      let menu = try Fixture.screen(name)
      XCTAssertEqual(ScreenState.of(menu), .menu, name)
      hold.add(menu, at: start.addingTimeInterval(Double(k + 1)))
      // While it's open (its labels covered, the hold shows what came since): nothing higher under it, no peak there.
      let during = try XCTUnwrap(hold.state, name)
      XCTAssertEqual(during.graph, before.graph, "\(name): the graph held, not the narrower one beside the menu")
      let under = (menu.width - menu.width / 6 - 4) - during.graph.left
      for i in during.rows.indices where i >= under {
        if let row = during.rows[i], let was = before.rows[i] {
          XCTAssertGreaterThanOrEqual(row, was, "\(name): column \(during.graph.left + i), under the menu")
        }
      }
      XCTAssertFalse(during.peaks.contains { $0.column - during.graph.left >= under }, "\(name): a peak under it")
    }
    // Closed: under it, the hold as it was (left of it, the menu screens' own sweeps, from another time, count).
    hold.add(graph, at: start.addingTimeInterval(4))
    let after = try XCTUnwrap(hold.state)
    let under = (graph.width - graph.width / 6 - 4) - after.graph.left
    XCTAssertEqual(Array(after.rows[under...]), Array(before.rows[under...]))
  }

  func testAKeypadIsNotTheTrace() throws {
    let hold = PeakHold()
    hold.add(try Fixture.screen("screen-915.png"), at: start)
    let before = try XCTUnwrap(hold.state)
    let keypad = try Fixture.screen("screen-keypad.png")
    XCTAssertEqual(ScreenState.of(keypad), .numberKeypad)
    hold.add(keypad, at: start.addingTimeInterval(1))
    XCTAssertEqual(hold.state?.rows, before.rows)
  }
}
