import XCTest

@testable import TinySAKit

/// The window's list of peaks: every peak since the app started, a row each, never taken out.
final class PeakLogTests: XCTestCase {
  let start = Date(timeIntervalSinceReferenceDate: 1000)  // 2001-01-01 00:16:40 UTC
  let graph = Graph(
    left: 30, right: 480, top: 0, bottom: 240, gridRows: [0, 24, 48, 72, 96, 120, 144, 168, 192, 216, 240])

  func state(_ peaks: [PeakHold.Peak], window: TimeInterval? = 60) -> PeakHold.State {
    PeakHold.State(
      graph: graph, rows: Array(repeating: 200, count: 450),
      scale: GraphScale(level0: 10, perRow: -10.0 / 24, start: 900_000_000, stop: 930_000_000), peaks: peaks,
      since: start, window: window)
  }

  func peak(
    _ number: Int, at column: Int, _ megahertz: Double, _ level: Double, _ seconds: TimeInterval
  ) -> PeakHold.Peak {
    PeakHold.Peak(
      number: number, column: column, row: 50, frequency: Int64(megahertz * 1e6), level: level,
      time: start.addingTimeInterval(seconds))
  }

  /// A peak held stays one row, its level and time brought up to date; one gone stays, no longer held; a peak coming
  /// again after it went, or elsewhere under a freed number, is a new row; the hold off keeps them all.
  func testTheListKeepsEveryPeak() {
    var log = PeakLog()
    XCTAssertTrue(log.update(with: state([peak(1, at: 100, 905, -40, 0), peak(2, at: 300, 920, -50, 1)])))
    XCTAssertEqual(log.entries.map(\.number), [1, 2])
    XCTAssertEqual(log.title, "Peak hold, last 1:00")

    log.update(with: state([peak(1, at: 101, 905.05, -35, 2), peak(2, at: 200, 912, -45, 3)]))
    XCTAssertEqual(log.entries.count, 3)
    XCTAssertEqual(log.entries[0].level, -35, "peak 1 came in higher: its row")
    XCTAssertEqual(log.entries[0].time, start.addingTimeInterval(2))
    XCTAssertTrue(log.entries[0].held)
    XCTAssertFalse(log.entries[1].held, "the peak at column 300 is gone, its row kept")
    XCTAssertEqual(log.entries[2].column, 200, "number 2 elsewhere: another peak")

    XCTAssertTrue(log.update(with: nil))
    XCTAssertEqual(log.entries.count, 3)
    XCTAssertTrue(log.entries.allSatisfy { !$0.held })
    XCTAssertFalse(log.update(with: nil), "nothing changed")
  }

  /// While the hold reads new labels (other levels, another span), the list waits: its peaks stay held, no row added.
  func testTheListWaitsWhileLabelsAreRead() {
    var log = PeakLog()
    log.update(with: state([peak(1, at: 100, 905, -40, 0)]))
    var reading = state([peak(1, at: 100, 905, -40, 0)])
    reading.scale = nil
    XCTAssertFalse(log.update(with: reading))
    XCTAssertEqual(log.entries.count, 1)
    XCTAssertTrue(log.entries[0].held)
    log.update(with: state([peak(1, at: 100, 905, -40, 0)]))
    XCTAssertEqual(log.entries.count, 1, "the same row, not a new one")
  }

  /// The CSV: a header, then a row a peak, its date and time to the second with AM or PM, its megahertz as the list
  /// shows them, its level with a plain minus.
  func testTheListAsACSVFile() {
    var log = PeakLog()
    log.update(with: state([peak(1, at: 100, 905.2, -45, 0), peak(2, at: 300, 921.75, -52.4, 5)]))
    let lines = log.csv(timeZone: TimeZone(identifier: "UTC")!).split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.first, "Peak,Time,Frequency (MHz),Level (dBm)")
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[1].hasPrefix("1,2001-01-01 12:16:40 AM,905.2"), lines[1])
    XCTAssertTrue(lines[1].hasSuffix(",-45"), lines[1])
    XCTAssertTrue(lines[2].hasPrefix("2,2001-01-01 12:16:45 AM,921.7"), lines[2])
  }
}
