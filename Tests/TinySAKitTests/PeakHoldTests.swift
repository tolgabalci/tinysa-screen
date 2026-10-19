import XCTest

@testable import TinySAKit

final class PeakHoldTests: XCTestCase {
  /// The grid is found from the pixels, whatever the waterfall's size.
  func testFindsTheGraph() throws {
    let small = try XCTUnwrap(Graph.find(on: Fixture.screen("screen-915.png")))
    XCTAssertEqual([small.left, small.right, small.top, small.bottom], [30, 480, 0, 240])
    XCTAssertEqual(small.gridRows, stride(from: 0, through: 240, by: 24).map { $0 })
    let big = try XCTUnwrap(Graph.find(on: Fixture.screen("screen-915-big.png")))
    XCTAssertEqual([big.left, big.top, big.bottom], [30, 0, 180])
    XCTAssertEqual(big.gridRows[1], 18)
    let black = Snapshot(width: 480, height: 320, pixels: Array(repeating: Snapshot.pixel(r: 0, g: 0, b: 0), count: 480 * 320))
    XCTAssertNil(Graph.find(on: black))
  }

  /// The live trace (yellow) is found in every column of the graph, and nothing else is taken for it: not the green
  /// max hold above it, nor white text.
  func testReadsTheTrace() throws {
    let screen = try Fixture.screen("screen-915.png")
    let graph = try XCTUnwrap(Graph.find(on: screen))
    let rows = graph.traceRows(on: screen)
    XCTAssertEqual(rows.count, 450)
    XCTAssertGreaterThan(rows.compactMap { $0 }.count, 440)
    XCTAssertEqual(rows[240 - 30], 216)
    // The noise floor sits between -80 and -60 dBm here: rows 168 to 216.
    for row in rows.compactMap({ $0 }) { XCTAssertTrue((168...228).contains(row), "row \(row)") }
  }

  /// The levels and the span are read from the screen's own labels.
  func testReadsTheScale() throws {
    let cases: [(String, Double, Double, Int64, Int64)] = [
      ("screen-915.png", 10, -10.0 / 24, 902_000_000, 928_000_000),
      ("screen-915-big.png", 10, -10.0 / 18, 902_000_000, 928_000_000),
      ("screen-433.png", 0, -10.0 / 24, 433_050_000, 434_790_000),
      // Wi-Fi and Bluetooth, a burst at the right edge across the −70 label: read without the minus signs above it.
      ("screen-2400.png", 10, -10.0 / 24, 2_400_000_000, 2_483_500_000),
    ]
    for (name, level0, perRow, start, stop) in cases {
      let screen = try Fixture.screen(name)
      let graph = try XCTUnwrap(Graph.find(on: screen), name)
      let scale = try XCTUnwrap(GraphScale.read(graph, on: screen), "\(name), read as:\n\(readings(graph, on: screen))")
      XCTAssertEqual(scale.level0, level0, accuracy: 0.001, name)
      XCTAssertEqual(scale.perRow, perRow, accuracy: 0.0001, name)
      XCTAssertEqual(scale.start, start, name)
      XCTAssertEqual(scale.stop, stop, name)
      XCTAssertEqual(scale.frequency(column: graph.left, of: graph), start)
      XCTAssertEqual(scale.frequency(column: graph.right - 1, of: graph), stop)
    }
  }

  /// What the labels were read as at each zoom, for a failure's message: the reading differs between macOS versions.
  private func readings(_ graph: Graph, on screen: Snapshot) -> String {
    guard let image = screen.image() else { return "no image" }
    let regions = graph.labelRegions(screen)
    let zooms = [4, 8].map { zoom -> String in
      let levels = LabelReader.lines(in: image, region: regions[0], zoom: zoom)
      let span = LabelReader.lines(in: image, region: regions[1], zoom: zoom).map(\.text).joined(separator: " ")
      let fit = GraphScale.fitLevels(levels, graph: graph).map { "\($0.0) + \($0.1)/row" } ?? "none"
      let parsed = GraphScale.parseSpan(span).map { "\($0.0)–\($0.1)" } ?? "none"
      let division = GraphScale.parseDivision(span).map { "\($0)" } ?? "none"
      return "zoom \(zoom): levels \(levels.map { "\($0.text)@\($0.top)" }) fit \(fit); span \"\(span)\" \(parsed), "
        + "division \(division)"
    }
    return zooms.joined(separator: "\n") + "\ngrid spacing \(graph.verticalSpacing(on: screen).map { "\($0)" } ?? "none")"
  }

  /// A misread label is outvoted by the others; too few labels, no scale.
  func testLevelFitOutvotesAMisreading() throws {
    let graph = Graph(left: 30, right: 480, top: 0, bottom: 240, gridRows: stride(from: 0, through: 240, by: 24).map { $0 })
    let labels = [("10", 0), ("-10", 48), ("-20", 72), ("30", 96), ("-40", 120), ("-50", 144)].map {
      LabelReader.Line(text: $0.0, top: $0.1)
    }
    let fit = try XCTUnwrap(GraphScale.fitLevels(labels, graph: graph))
    XCTAssertEqual(fit.0, 10, accuracy: 0.001)
    XCTAssertEqual(fit.1 * 24, -10, accuracy: 0.001)
    XCTAssertNil(GraphScale.fitLevels(Array(labels.prefix(2)), graph: graph))
  }

  /// A minus sign the reading lost ("30" for "−30", it does now and then) still counts, where the label's negative fits.
  func testLevelFitTakesBackLostMinusSigns() throws {
    let graph = Graph(left: 30, right: 480, top: 0, bottom: 240, gridRows: stride(from: 0, through: 240, by: 24).map { $0 })
    // As read from the right side of a 2.4 GHz screen: −70 missing, the four above it without their signs.
    let labels = [("10", 0), ("0", 24), ("-10", 48), ("-20", 72), ("30", 96), ("40", 120), ("50", 144), ("60", 168),
      ("-80", 216)].map { LabelReader.Line(text: $0.0, top: $0.1) }
    let fit = try XCTUnwrap(GraphScale.fitLevels(labels, graph: graph))
    XCTAssertEqual(fit.0, 10, accuracy: 0.001)
    XCTAssertEqual(fit.1 * 24, -10, accuracy: 0.001)
  }

  func testParsesTheSpan() {
    XCTAssertEqual(GraphScale.parseSpan("START 902.000000MHz 2.0MHz/ SToP 928.000000MHz").map { [$0.0, $0.1] }, [902_000_000, 928_000_000])
    XCTAssertEqual(GraphScale.parseSpan("START 2.400000GHz 10.0MHz/ STOP 2.483500GHz").map { [$0.0, $0.1] }, [2_400_000_000, 2_483_500_000])
    XCTAssertEqual(GraphScale.parseSpan("CENTER 915.000000MHz SPAN 26.000000MHz").map { [$0.0, $0.1] }, [902_000_000, 928_000_000])
    XCTAssertEqual(GraphScale.parseSpan("$TART 902.000000МHz 2.0MHzr $ToP 928.000000MHz").map { [$0.0, $0.1] }, [902_000_000, 928_000_000])
    XCTAssertNil(GraphScale.parseSpan("START 902-000000MH2 STOP 928.000000MHz"))
    // Words misspelled by recognition (seen on macOS 15): the values' places say which is which.
    for text in [
      "STHRT 902.000000MHz 2.0MHz/ STOP 928.000000MHz", "ISTART 902.000000MHz 2.0MHz1 STOP 928.000000MHz",
      "START 9O2.000000MHz 2.0MHz/ SToP | 928.000000MHz",
    ] {
      XCTAssertEqual(GraphScale.parseSpan(text).map { [$0.0, $0.1] }, [902_000_000, 928_000_000], text)
    }
  }

  /// The hold keeps the highest point of each column, finds the peaks, and gives them frequencies and levels once
  /// the labels are read: the same, to the screen's resolution, as the analyzer's own marker on that peak.
  func testHoldsPeaks() throws {
    let hold = PeakHold()
    let read = expectation(description: "labels read")
    hold.onChange = { state in
      if state?.scale != nil { read.fulfill() }
    }
    let screen = try Fixture.screen("screen-915-burst.png")
    hold.add(screen, at: Date())
    wait(for: [read], timeout: 20)
    hold.onChange = nil
    let state = try XCTUnwrap(hold.state)
    let top = try XCTUnwrap(state.peaks.first)
    // The analyzer's marker: 902.231 MHz, −23.2 dBm. A column is 57.9 kHz here, a row 0.42 dB.
    XCTAssertEqual(Double(try XCTUnwrap(top.frequency)), 902_231_000, accuracy: 60_000)
    XCTAssertEqual(try XCTUnwrap(top.level), -23.2, accuracy: 0.5)
    // The noise isn't taken for peaks: everything else on this sweep's trace is within 6 dB of its noise.
    XCTAssertEqual(state.peaks.count, 1)
    // A quieter sweep afterwards (the same screen with the burst gone) doesn't lower what's held.
    var quieter = screen
    for y in 0..<140 {
      for x in 30..<480 where Graph.isTrace(quieter.pixels[y * 480 + x]) {
        quieter.pixels[y * 480 + x] = Snapshot.pixel(r: 0, g: 0, b: 0)
      }
    }
    hold.add(quieter, at: Date())
    XCTAssertEqual(hold.state?.peaks.first?.row, top.row)
    XCTAssertEqual(hold.state?.scale, state.scale)
    hold.reset()
    XCTAssertNil(hold.state)
  }

  /// A trace that is all noise has no peaks.
  func testNoiseHasNoPeaks() throws {
    let hold = PeakHold()
    hold.add(try Fixture.screen("screen-915-big.png"), at: Date())
    XCTAssertEqual(hold.state?.peaks.count, 0)
    XCTAssertEqual(hold.state?.rows.compactMap { $0 }.count, 450)
  }

  /// Peaks: the tops that stand out from the valleys around them, highest first; flat tops once.
  func testFindsPeaks() throws {
    let graph = Graph(left: 30, right: 50, top: 0, bottom: 100, gridRows: [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    var rows: [Int?] = Array(repeating: 80, count: 20)
    rows[3] = 40  // a peak 40 rows up
    rows[10] = 60
    rows[11] = 60  // a flat top, 20 up
    rows[16] = 77  // too small to count
    rows[18] = nil
    let state = PeakHold.State(graph: graph, rows: rows, scale: nil, peaks: [], since: Date(), window: nil)
    let peaks = PeakHold.peaks(in: state, count: 5)
    XCTAssertEqual(peaks.map(\.column), [33, 40])
    XCTAssertEqual(peaks.map(\.row), [40, 60])
  }

  /// A screen like the analyzer's: a dotted grid every 24 rows from x = 30, the noise floor at row 200, and a peak.
  func screen(peakAt column: Int, row: Int) -> Snapshot {
    var screen = Snapshot(width: 480, height: 320, pixels: Array(repeating: Snapshot.pixel(r: 0, g: 0, b: 0), count: 480 * 320))
    let grey = Snapshot.pixel(r: 0x83, g: 0x81, b: 0x83)
    let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
    for y in stride(from: 0, through: 240, by: 24) {
      for x in stride(from: 30, to: 480, by: 2) { screen.pixels[y * 480 + x] = grey }
    }
    for y in stride(from: 0, through: 240, by: 2) { screen.pixels[y * 480 + 30] = grey }
    for x in 30..<480 { screen.pixels[200 * 480 + x] = yellow }
    for y in row...200 { screen.pixels[y * 480 + column] = yellow }
    return screen
  }

  /// A screen like `screen(peakAt:row:)` with several peaks.
  func screen(peaks: [(column: Int, row: Int)]) -> Snapshot {
    var screen = screen(peakAt: peaks[0].column, row: peaks[0].row)
    let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
    for peak in peaks.dropFirst() {
      for y in peak.row...200 { screen.pixels[y * 480 + peak.column] = yellow }
    }
    return screen
  }

  /// The numbers of the held peaks, by column.
  func numbers(_ hold: PeakHold) -> [Int: Int] {
    Dictionary(uniqueKeysWithValues: (hold.state?.peaks ?? []).map { ($0.column, $0.number) })
  }

  /// Peaks keep their numbers while they're held, as an analyzer's markers stay on their peaks: a higher one coming
  /// doesn't renumber them.
  func testPeaksKeepTheirNumbers() {
    let hold = PeakHold()
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    hold.add(screen(peaks: [(100, 120), (300, 150)]), at: start)
    XCTAssertEqual(numbers(hold), [100: 1, 300: 2])  // highest first, to begin with
    hold.add(screen(peaks: [(100, 120), (300, 150), (200, 60)]), at: start.addingTimeInterval(1))
    XCTAssertEqual(numbers(hold), [100: 1, 300: 2, 200: 3])
    XCTAssertEqual(hold.state?.peaks.first?.column, 200)  // the list itself stays highest first
  }

  /// A peak gone frees its number, and a new one takes the lowest free.
  func testANewPeakTakesTheLowestFreeNumber() {
    let hold = PeakHold()
    hold.window = 2
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    hold.add(screen(peaks: [(100, 120), (300, 150)]), at: start)
    XCTAssertEqual(numbers(hold), [100: 1, 300: 2])
    hold.add(screen(peaks: [(300, 150), (400, 100)]), at: start.addingTimeInterval(3))  // 100 MHz's out of the window
    XCTAssertEqual(numbers(hold), [300: 2, 400: 1])
  }

  /// A peak that moves a few columns (2 % of the graph: half a megahertz of 26 MHz) is the same peak; further, another.
  func testAPeakMovedALittleKeepsItsNumber() {
    let hold = PeakHold()
    hold.window = 2
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    hold.add(screen(peaks: [(400, 100), (100, 120), (200, 150)]), at: start)
    XCTAssertEqual(numbers(hold), [400: 1, 100: 2, 200: 3])
    // 100 gone, 200 moved to 205: still 3, though 2 is free.
    hold.add(screen(peaks: [(400, 100), (205, 150)]), at: start.addingTimeInterval(3))
    XCTAssertEqual(numbers(hold), [400: 1, 205: 3])
    // Moved 95 columns: a new peak, with the lowest free number.
    hold.add(screen(peaks: [(400, 100), (300, 150)]), at: start.addingTimeInterval(6))
    XCTAssertEqual(numbers(hold), [400: 1, 300: 2])
  }

  /// With a window, a level is held only that long; without one, until the hold starts over.
  func testWindowForgets() throws {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let hold = PeakHold()
    hold.window = 2
    hold.add(screen(peakAt: 100, row: 50), at: start)
    hold.add(screen(peakAt: 300, row: 120), at: start.addingTimeInterval(1))
    XCTAssertEqual(hold.state?.peaks.map(\.column), [100, 300])
    hold.add(screen(peakAt: 300, row: 120), at: start.addingTimeInterval(2.5))
    XCTAssertEqual(hold.state?.peaks.map(\.column), [300], "the first peak is more than 2 s old")
    let forever = PeakHold()
    forever.add(screen(peakAt: 100, row: 50), at: start)
    forever.add(screen(peakAt: 300, row: 120), at: start.addingTimeInterval(600))
    XCTAssertEqual(forever.state?.peaks.map(\.column), [100, 300])
    XCTAssertEqual(forever.state?.since, start)
  }

  /// After the hold starts over (Clear, a setting changed), the readouts come back at once: the labels read before are
  /// remembered.
  func testReadoutsComeBackAfterStartingOver() throws {
    let hold = PeakHold()
    let read = expectation(description: "labels read")
    hold.onChange = { state in
      if state?.scale != nil { read.fulfill() }
    }
    let screen = try Fixture.screen("screen-915-burst.png")
    hold.add(screen, at: Date())
    wait(for: [read], timeout: 20)
    hold.onChange = nil
    hold.reset()
    hold.add(screen, at: Date())
    XCTAssertNotNil(hold.state?.scale)
    XCTAssertNotNil(hold.state?.peaks.first?.level)
    hold.window = 30
    hold.add(screen, at: Date())
    XCTAssertNotNil(hold.state?.scale)
  }

  /// Another span: until its labels are read, only its own sweeps show (nothing of the old span's levels); read, they
  /// stay, and the hold counts from when the span changed.
  func testANewSpansSweepsAreKeptApartUntilItsLabelsAreRead() throws {
    let band915 = try Fixture.screen("screen-915.png")
    let band2400 = try Fixture.screen("screen-2400.png")
    let graph = try XCTUnwrap(Graph.find(on: band2400))
    XCTAssertEqual(Graph.find(on: band915), graph)  // the same layout: only the labels tell the spans apart
    let own = graph.traceRows(on: band2400)
    let mixed = zip(graph.traceRows(on: band915), own).map { a, b in [a, b].compactMap { $0 }.min() }
    XCTAssertNotEqual(mixed, own)

    let hold = PeakHold()
    var read = expectation(description: "902–928 MHz read")
    read.assertForOverFulfill = false
    hold.onChange = { state in
      if state?.scale?.start == 902_000_000 { read.fulfill() }
    }
    hold.add(band915, at: Date())
    wait(for: [read], timeout: 20)
    read = expectation(description: "2.4 GHz read")
    read.assertForOverFulfill = false
    hold.onChange = { state in
      if state?.scale?.start == 2_400_000_000 { read.fulfill() }
    }
    let changed = Date()
    hold.add(band2400, at: changed)
    XCTAssertEqual(hold.state?.rows, own)
    wait(for: [read], timeout: 20)
    hold.onChange = nil
    XCTAssertEqual(hold.state?.rows, own)
    XCTAssertEqual(hold.state?.since, changed)
  }

  /// Labels covered for a while (a menu opened on the analyzer): meanwhile only what comes shows; once they're back
  /// and the same, what was held before is there again with it.
  func testLabelsCoveredForAWhileKeepTheHold() throws {
    let screen = try Fixture.screen("screen-915.png")
    let graph = try XCTUnwrap(Graph.find(on: screen))
    var covered = screen
    let span = graph.labelRegions(screen)[1]
    for y in span.minY..<min(span.maxY, covered.height) {
      for x in span.minX..<min(span.maxX, covered.width) {
        covered.pixels[y * 480 + x] = Snapshot.pixel(r: 200, g: 200, b: 200)
      }
    }
    for y in 0..<graph.bottom {
      for x in 100..<200 where Graph.isTrace(covered.pixels[y * 480 + x]) {
        covered.pixels[y * 480 + x] = Snapshot.pixel(r: 0, g: 0, b: 0)
      }
    }
    XCTAssertNotEqual(graph.labelPrint(on: covered), graph.labelPrint(on: screen))
    let before = graph.traceRows(on: screen)
    let meanwhile = graph.traceRows(on: covered)
    XCTAssertNotEqual(before, meanwhile)

    let hold = PeakHold()
    let read = expectation(description: "labels read")
    read.assertForOverFulfill = false
    hold.onChange = { state in
      if state?.scale != nil { read.fulfill() }
    }
    let started = Date()
    hold.add(screen, at: started)
    wait(for: [read], timeout: 20)
    hold.onChange = nil
    hold.add(covered, at: Date())
    XCTAssertEqual(hold.state?.rows, meanwhile)
    hold.add(screen, at: Date())
    XCTAssertEqual(hold.state?.rows, before)
    XCTAssertEqual(hold.state?.since, started)
    XCTAssertNotNil(hold.state?.scale)
  }

  /// The labels' fingerprint is theirs alone: the same span with another waterfall and other traces has the same one
  /// (a busy band's waterfall has white dots just above the span's text); another top level changes it, a trace across
  /// a lower level doesn't.
  func testTheLabelsPrintChangesWithTheLabelsOnly() throws {
    let now = try Fixture.screen("screen-2400.png")
    let later = try Fixture.screen("screen-2400-later.png")
    let graph = try XCTUnwrap(Graph.find(on: now))
    XCTAssertNotEqual(now.pixels, later.pixels)
    XCTAssertEqual(graph.labelPrint(on: later), graph.labelPrint(on: now))

    let levels = graph.labelRegions(now)[0]
    var otherTop = now
    otherTop.pixels[4 * 480 + levels.minX + 20] = Snapshot.pixel(r: 197, g: 198, b: 197)
    XCTAssertNotEqual(graph.labelPrint(on: otherTop), graph.labelPrint(on: now))
    var traceAcross = now
    for x in levels.minX..<levels.maxX { traceAcross.pixels[100 * 480 + x] = Snapshot.pixel(r: 65, g: 255, b: 65) }
    XCTAssertEqual(graph.labelPrint(on: traceAcross), graph.labelPrint(on: now))
  }

  /// A peak at the graph's edge counts: nothing on its outer side holds it down.
  func testPeaksAtTheEdges() {
    let left = PeakHold()
    left.add(screen(peakAt: 30, row: 60), at: Date())
    XCTAssertEqual(left.state?.peaks.map(\.column), [30])
    let right = PeakHold()
    right.add(screen(peakAt: 479, row: 60), at: Date())
    XCTAssertEqual(right.state?.peaks.map(\.column), [479])
  }

  /// Pictures too small for a box of readouts, or for the labels, don't trip anything up.
  func testSmallPictures() {
    for (width, height) in [(120, 100), (28, 50), (40, 40)] {
      var picture = Snapshot(width: width, height: height, pixels: Array(repeating: Snapshot.pixel(r: 0, g: 0, b: 0), count: width * height))
      for y in stride(from: 0, to: height, by: 10) {
        for x in stride(from: 0, to: width, by: 2) { picture.pixels[y * width + x] = Snapshot.pixel(r: 0x83, g: 0x81, b: 0x83) }
      }
      for y in stride(from: 0, to: height, by: 2) { picture.pixels[y * width + 2] = Snapshot.pixel(r: 0x83, g: 0x81, b: 0x83) }
      let hold = PeakHold()
      hold.add(picture, at: Date())
      hold.add(picture, at: Date())
      if let graph = Graph.find(on: picture) {
        _ = graph.labelPrint(on: picture)
        for region in graph.labelRegions(picture) {
          XCTAssertLessThanOrEqual(region.minX, region.maxX)
          XCTAssertLessThanOrEqual(region.minY, region.maxY)
        }
      }
    }
  }

  /// Fine scales (0.1, 0.2, 0.5 dB a division) fit despite the decimals not being exact in binary.
  func testFineScales() throws {
    let graph = Graph(left: 30, right: 480, top: 0, bottom: 240, gridRows: stride(from: 0, through: 240, by: 24).map { $0 })
    for perDivision in [0.1, 0.2, 0.5] {
      let labels = (0..<6).map { n in
        LabelReader.Line(text: String(format: "%.1f", -20.1 - perDivision * Double(n)), top: 24 * n)
      }
      let fit = try XCTUnwrap(GraphScale.fitLevels(labels, graph: graph), "\(perDivision) dB a division")
      XCTAssertEqual(fit.1 * 24, -perDivision, accuracy: 0.0001)
    }
  }

  func testMisreadSpansAreRefused() {
    XCTAssertNil(GraphScale.parseSpan("START 90200000000000MHz STOP 928.000000MHz"))
  }

  /// The grid's own spacing gives the span, to check the one read: 2 MHz a division is 34.6 pixels on 902–928 MHz,
  /// 200 kHz is 51.7 on 433.05–434.79 MHz.
  func testTheGridChecksTheSpan() throws {
    let wide = try Fixture.screen("screen-915.png")
    let wideGraph = try XCTUnwrap(Graph.find(on: wide))
    XCTAssertEqual(try XCTUnwrap(wideGraph.verticalSpacing(on: wide)), 34.6, accuracy: 0.6)
    let narrow = try Fixture.screen("screen-433.png")
    let narrowGraph = try XCTUnwrap(Graph.find(on: narrow))
    XCTAssertEqual(try XCTUnwrap(narrowGraph.verticalSpacing(on: narrow)), 51.7, accuracy: 0.6)
    XCTAssertEqual(GraphScale.parseDivision("START 902.000000MHz 2.0MHz/ STOP 928.000000MHz"), 2_000_000)
    XCTAssertEqual(GraphScale.parseDivision("START 433.050000MHz 200.0kHz/ STOP 434.790000MHz"), 200_000)
    XCTAssertEqual(GraphScale.parseDivision("START 2.400000GHz 10.0MHz/ STOP 2.483500GHz"), 10_000_000)
    XCTAssertNil(GraphScale.parseDivision("START 902.000000MHz STOP 928.000000MHz"))
    let right = GraphScale(level0: 10, perRow: -10.0 / 24, start: 902_000_000, stop: 928_000_000)
    XCTAssertTrue(GraphScale.fitsGrid(right, division: 2_000_000, spacing: 34.6, width: 450))
    // A misread digit: 908 for 902.
    let misread = GraphScale(level0: 10, perRow: -10.0 / 24, start: 908_000_000, stop: 928_000_000)
    XCTAssertFalse(GraphScale.fitsGrid(misread, division: 2_000_000, spacing: 34.6, width: 450))
  }
}
