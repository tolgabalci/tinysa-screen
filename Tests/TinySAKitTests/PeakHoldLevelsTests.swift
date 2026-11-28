import XCTest

@testable import TinySAKit

/// The hold when the analyzer's levels change under it (its automatic reference level, the decibels a division, the
/// waterfall's size): what's held moves to where its levels are now, its peaks keeping their numbers and times. Another
/// span starts it over.
final class PeakHoldLevelsTests: XCTestCase {
  let start = Date(timeIntervalSinceReferenceDate: 1000)
  /// +10 dBm at the top, 10 dB a division of 24 rows, 900 to 930 MHz.
  let top10 = GraphScale(level0: 10, perRow: -10.0 / 24, start: 900_000_000, stop: 930_000_000)
  /// The same span with +20 dBm at the top, as the analyzer's automatic reference level sets it for strong signals.
  let top20 = GraphScale(level0: 20, perRow: -10.0 / 24, start: 900_000_000, stop: 930_000_000)

  func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  /// A screen like the analyzer's: a dotted grid of ten divisions `step` rows high from x = 30, the noise floor at
  /// `floor`, peaks reaching up to their rows; `labels` sets a pixel among the levels' labels, so screens with other
  /// labels can be told apart.
  func screen(step: Int = 24, floor: Int = 200, peaks: [(column: Int, row: Int)], labels: Int) -> Snapshot {
    var screen = Snapshot(
      width: 480, height: 320, pixels: Array(repeating: Snapshot.pixel(r: 0, g: 0, b: 0), count: 480 * 320))
    let grey = Snapshot.pixel(r: 0x83, g: 0x81, b: 0x83)
    let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
    for y in stride(from: 0, through: 10 * step, by: step) {
      for x in stride(from: 30, to: 480, by: 2) { screen.pixels[y * 480 + x] = grey }
    }
    for y in stride(from: 0, through: 10 * step, by: 2) { screen.pixels[y * 480 + 30] = grey }
    for x in 30..<480 { screen.pixels[floor * 480 + x] = yellow }
    for peak in peaks {
      for y in peak.row...floor { screen.pixels[y * 480 + peak.column] = yellow }
    }
    screen.pixels[4 * 480 + 450 + labels] = Snapshot.pixel(r: 255, g: 255, b: 255)
    return screen
  }

  func numbers(_ state: PeakHold.State) -> [Int: Int] {
    Dictionary(uniqueKeysWithValues: state.peaks.map { ($0.column, $0.number) })
  }

  /// The reference level up from +10 to +20 dBm as strong signals come, and back down as they go (the analyzer's
  /// automatic reference level): nothing held is lost either way, each peak where its level is now, with its number,
  /// time and level, and the hold counts from where it began.
  func testOtherLevelsMoveWhatsHeld() throws {
    let hold = PeakHold(readsLabels: false)
    let before = screen(peaks: [(100, 48), (300, 72)], labels: 1)  // −10 and −20 dBm
    hold.know(top10, for: before)
    hold.add(before, at: at(0))
    let numbered = numbers(try XCTUnwrap(hold.state))
    XCTAssertEqual(Set(numbered.keys), [100, 300])

    let up = screen(peaks: [(400, 150)], labels: 2)  // −42.5 dBm under +20
    hold.know(top20, for: up)
    hold.add(up, at: at(5))
    let raised = try XCTUnwrap(hold.state)
    XCTAssertEqual(raised.scale, top20)
    XCTAssertEqual(raised.since, at(0), "not started over")
    XCTAssertEqual(raised.rows[100 - 30], 72)
    XCTAssertEqual(raised.rows[300 - 30], 96)
    XCTAssertEqual(Set(raised.peaks.map(\.column)), [100, 300, 400])
    for (column, number) in numbered { XCTAssertEqual(numbers(raised)[column], number, "peak at \(column)") }
    let held = try XCTUnwrap(raised.peaks.first { $0.column == 100 })
    XCTAssertEqual(held.level ?? 0, -10, accuracy: 0.5)
    XCTAssertEqual(held.time, at(0))

    let down = screen(peaks: [], labels: 1)  // +10 dBm at the top again, read before
    hold.add(down, at: at(40))
    let lowered = try XCTUnwrap(hold.state)
    XCTAssertEqual(lowered.scale, top10)
    XCTAssertEqual(lowered.since, at(0))
    XCTAssertEqual(lowered.rows[100 - 30], 48)
    XCTAssertEqual(lowered.rows[400 - 30], 126)
    XCTAssertEqual(Set(lowered.peaks.map(\.column)), [100, 300, 400], "all still there")
    let levels = Dictionary(uniqueKeysWithValues: lowered.peaks.map { ($0.column, $0.level ?? .nan) })
    XCTAssertEqual(levels[300] ?? 0, -20, accuracy: 0.5)
    XCTAssertEqual(levels[400] ?? 0, -42.5, accuracy: 0.5)
  }

  /// A level beyond the graph's top at the new levels stays at the top, as the analyzer draws a trace beyond it.
  func testALevelBeyondTheTopStaysAtTheTop() throws {
    let hold = PeakHold(readsLabels: false)
    let before = screen(peaks: [(100, 5)], labels: 1)  // about +8 dBm
    hold.know(top10, for: before)
    hold.add(before, at: at(0))
    let top0 = GraphScale(level0: 0, perRow: -10.0 / 24, start: 900_000_000, stop: 930_000_000)
    let after = screen(peaks: [], labels: 3)
    hold.know(top0, for: after)
    hold.add(after, at: at(1))
    XCTAssertEqual(hold.state?.rows[100 - 30], 0)
  }

  /// New levels whose labels take a moment to read: meanwhile only what comes shows (its levels unknown); read, what
  /// was held is back, moved, its peaks with their numbers.
  func testOtherLevelsReadAfterAMoment() throws {
    let hold = PeakHold(readsLabels: false)
    let before = screen(peaks: [(100, 48), (300, 72)], labels: 1)
    hold.know(top10, for: before)
    hold.add(before, at: at(0))
    let numbered = numbers(try XCTUnwrap(hold.state))

    let up = screen(peaks: [(400, 150)], labels: 2)
    hold.add(up, at: at(5))
    let meanwhile = try XCTUnwrap(hold.state)
    XCTAssertNil(meanwhile.scale)
    XCTAssertEqual(meanwhile.peaks.map(\.column), [400], "meanwhile only what came since")

    hold.know(top20, for: up)  // read, as the Mac's text recognition would
    hold.add(up, at: at(6))
    let read = try XCTUnwrap(hold.state)
    XCTAssertEqual(read.scale, top20)
    XCTAssertEqual(read.since, at(0))
    XCTAssertEqual(read.rows[100 - 30], 72)
    for (column, number) in numbered { XCTAssertEqual(numbers(read)[column], number, "peak at \(column)") }
  }

  /// Another span starts the hold over: none of the old span's levels stay.
  func testAnotherSpanStartsOver() throws {
    let hold = PeakHold(readsLabels: false)
    let before = screen(peaks: [(100, 48)], labels: 1)
    hold.know(top10, for: before)
    hold.add(before, at: at(0))
    let band = GraphScale(level0: 10, perRow: -10.0 / 24, start: 2_400_000_000, stop: 2_483_500_000)
    let other = screen(peaks: [(300, 72)], labels: 4)
    hold.know(band, for: other)
    hold.add(other, at: at(5))
    let state = try XCTUnwrap(hold.state)
    XCTAssertEqual(state.peaks.map(\.column), [300])
    XCTAssertEqual(state.since, at(5))
  }

  /// The waterfall's size changed (the grid's rows elsewhere, the columns the same): with both layouts' labels read,
  /// what's held moves to where its levels are; to a layout not read yet, the hold starts over.
  func testTheWaterfallsSizeMovesWhatsHeld() throws {
    let small = screen(peaks: [(100, 48)], labels: 1)  // −10 dBm
    let bigScale = GraphScale(level0: 10, perRow: -10.0 / 18, start: 900_000_000, stop: 930_000_000)
    let big = screen(step: 18, floor: 150, peaks: [(300, 90)], labels: 1)
    XCTAssertNotEqual(Graph.find(on: small), Graph.find(on: big))

    let hold = PeakHold(readsLabels: false)
    hold.know(top10, for: small)
    hold.know(bigScale, for: big)
    hold.add(small, at: at(0))
    hold.add(big, at: at(5))
    let state = try XCTUnwrap(hold.state)
    XCTAssertEqual(state.since, at(0))
    XCTAssertEqual(state.rows[100 - 30], 36)
    XCTAssertEqual(Set(state.peaks.map(\.column)), [100, 300])

    let unread = PeakHold(readsLabels: false)
    unread.know(top10, for: small)
    unread.add(small, at: at(0))
    unread.add(big, at: at(5))
    XCTAssertEqual(unread.state?.since, at(5))
  }
}
