import XCTest

@testable import TinySAKit

final class PeakHoldTests: XCTestCase {
  /// How long to wait for the labels to be read: a second, as a rule, but the first read after a macOS update takes
  /// most of a minute, the Mac's text recognition preparing itself for the program (here the tests) first.
  let labelsRead: TimeInterval = 60

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

  /// A marker's readout, written in the trace's yellow at the top of the graph ("1: 166.4MHz -55.4dBm"), isn't taken
  /// for the trace (issue #1), nor its peaks; a trace reaching up into the text, or drawn there alone, still is.
  func testMarkerReadoutIsNotTheTrace() throws {
    let clean = try Fixture.screen("screen-915.png")
    let graph = try XCTUnwrap(Graph.find(on: clean))
    let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
    let black = Snapshot.pixel(r: 0, g: 0, b: 0)
    var screen = clean
    // Glyph-like boxes and strokes, 10 rows high, across the left half of the graph.
    for cell in 0..<26 {
      let x0 = 32 + cell * 8
      for y in 2...11 {
        screen.pixels[y * 480 + x0] = yellow
        if cell % 3 != 1 { screen.pixels[y * 480 + x0 + 5] = yellow }
      }
      for x in x0...(x0 + 5) where cell % 2 == 0 {
        screen.pixels[2 * 480 + x] = yellow
        screen.pixels[11 * 480 + x] = yellow
      }
    }
    // A spike from the trace up into the text's rows, and, in another column, the trace drawn there alone.
    let spike = 300
    let spikeBottom = try XCTUnwrap(graph.traceRows(on: clean)[spike - 30])
    for y in 6...spikeBottom { screen.pixels[y * 480 + spike] = yellow }
    let alone = 400
    for y in 0...240 where Graph.isTrace(screen.pixels[y * 480 + alone]) { screen.pixels[y * 480 + alone] = black }
    for y in 10...12 { screen.pixels[y * 480 + alone] = yellow }

    let rows = graph.traceRows(on: screen)
    let cleanRows = graph.traceRows(on: clean)
    for x in 32..<240 { XCTAssertEqual(rows[x - 30], cleanRows[x - 30], "column \(x)") }
    XCTAssertEqual(rows[spike - 30], 6)
    XCTAssertEqual(rows[alone - 30], 10)

    // With the text alone, the hold finds the same peaks as without it.
    var text = screen
    for y in 0...240 {
      for x in [spike, alone] { text.pixels[y * 480 + x] = clean.pixels[y * 480 + x] }
    }
    let (withText, without) = (PeakHold(), PeakHold())
    withText.add(text, at: Date())
    without.add(clean, at: Date())
    let peaks = try XCTUnwrap(withText.state?.peaks)
    XCTAssertEqual(peaks.map(\.column), without.state?.peaks.map(\.column))
    XCTAssertEqual(peaks.map(\.row), without.state?.peaks.map(\.row))
    XCTAssertTrue(peaks.allSatisfy { $0.row > 11 })
  }

  /// Marker 1's symbol as a tinySA Ultra draws it over the traces (the firmware's `marker_bitmap`, 11 × 14): "#" its
  /// plate, in the trace's colour, and "o" black, its number and a border; its tip is just above the marker's point.
  static let ultraMarker = [
    "ooooooooooo",
    "o#########o",
    "o####oo###o",
    "o###ooo###o",
    "o##o#oo###o",
    "o####oo###o",
    "o####oo###o",
    "o####oo###o",
    "o####oo###o",
    "o####oo###o",
    ".o##oooo#o.",
    "..o#####o..",
    "...o###o...",
    "....o#o....",
  ]

  /// The same on a tinySA (7 × 10, without a border).
  static let tinySAMarker = [
    "#######",
    "###o###",
    "##oo###",
    "###o###",
    "###o###",
    "###o###",
    "##ooo##",
    ".#####.",
    "..###..",
    "...#...",
  ]

  /// `symbol` drawn on `screen` in trace 1's yellow, as the analyzer draws a marker at `point`.
  func draw(_ symbol: [String], at point: (x: Int, y: Int), on screen: inout Snapshot) {
    let (yellow, black) = (Snapshot.pixel(r: 255, g: 255, b: 0), Snapshot.pixel(r: 0, g: 0, b: 0))
    let (left, top) = (point.x - symbol[0].count / 2, point.y - symbol.count)
    for (row, line) in symbol.enumerated() {
      for (column, mark) in line.enumerated() where mark != "." {
        screen.pixels[(top + row) * screen.width + left + column] = mark == "#" ? yellow : black
      }
    }
  }

  /// Nor is a marker's symbol (issue #1's screen has marker 1's): a plate in the trace's yellow, pointing down at the
  /// marker's point, with its number in black. With the marker on a peak, the plate held the peak 13 rows too high
  /// (5 dB here, 4 dB on the issue's screen), and elsewhere it made a peak of its own. A trace rising past the plate
  /// still counts from its top.
  func testMarkerSymbolIsNotTheTrace() throws {
    let clean = try Fixture.screen("screen-915.png")
    let graph = try XCTUnwrap(Graph.find(on: clean))
    let cleanRows = graph.traceRows(on: clean)
    let without = PeakHold()
    without.add(clean, at: Date())
    let cleanPeaks = try XCTUnwrap(without.state?.peaks)
    let highest = try XCTUnwrap(cleanPeaks.first)
    // Marker 1 on the highest peak, where a peak search puts it, or on the trace's highest point in the left half,
    // which isn't a peak.
    let column = try XCTUnwrap((40..<240).min { (cleanRows[$0 - 30] ?? .max, $0) < (cleanRows[$1 - 30] ?? .max, $1) })
    let point = (x: column, y: try XCTUnwrap(cleanRows[column - 30]))
    for marker in [(x: highest.column, y: highest.row), point] {
      var screen = clean
      draw(Self.ultraMarker, at: marker, on: &screen)
      let rows = graph.traceRows(on: screen)
      for x in 30..<480 { XCTAssertEqual(rows[x - 30], cleanRows[x - 30], "column \(x), marker at \(marker.x)") }
      let withMarker = PeakHold()
      withMarker.add(screen, at: Date())
      XCTAssertEqual(withMarker.state?.peaks.map(\.column), cleanPeaks.map(\.column), "marker at \(marker.x)")
      XCTAssertEqual(withMarker.state?.peaks.map(\.row), cleanPeaks.map(\.row), "marker at \(marker.x)")
    }

    // On the issue's screen the trace rose past the plate beside the marker's point; the analyzer drew the symbol over
    // it, its border hiding a row of it.
    var risen = clean
    for y in (point.y - 20)...point.y { risen.pixels[y * 480 + point.x + 1] = Snapshot.pixel(r: 255, g: 255, b: 0) }
    draw(Self.ultraMarker, at: point, on: &risen)
    let risenRows = graph.traceRows(on: risen)
    XCTAssertEqual(risenRows[point.x + 1 - 30], point.y - 20)
    XCTAssertEqual(risenRows[point.x - 30], point.y)
  }

  /// The analyzer's own symbols are told by their shape: a recorded screen has markers 1 to 5 on its green trace, found
  /// in green where they are; nothing on any recorded screen is taken for one in the trace's yellow.
  func testFindsTheAnalyzersMarkerSymbols() throws {
    let burst = try Fixture.screen("screen-915-burst.png")
    let graph = try XCTUnwrap(Graph.find(on: burst))
    let green = graph.markerSymbols(
      on: burst,
      colour: { pixel in
        let (r, g, b) = Snapshot.rgb(pixel)
        return g > 200 && r < 0x90 && b < 0x90
      })
    XCTAssertEqual(green.map { [$0.x, $0.y] }, [[240, 46], [30, 47], [98, 47], [199, 47], [137, 105]])
    let recorded = [
      "screen-915.png", "screen-915-big.png", "screen-915-burst.png", "screen-433.png", "screen-2400.png",
      "screen-2400-later.png",
    ]
    for name in recorded {
      let screen = try Fixture.screen(name)
      let graph = try XCTUnwrap(Graph.find(on: screen), name)
      XCTAssertTrue(graph.markerSymbols(on: screen).isEmpty, name)
    }
  }

  /// A tinySA's smaller screen (320 × 240) has the smaller symbol, without a border.
  func testTinySAMarkerSymbolIsNotTheTrace() throws {
    let black = Snapshot.pixel(r: 0, g: 0, b: 0)
    var clean = Snapshot(width: 320, height: 240, pixels: Array(repeating: black, count: 320 * 240))
    let grey = Snapshot.pixel(r: 0x83, g: 0x81, b: 0x83)
    let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
    for y in stride(from: 0, through: 230, by: 23) {
      for x in stride(from: 25, to: 320, by: 2) { clean.pixels[y * 320 + x] = grey }
    }
    for x in 25..<320 { clean.pixels[200 * 320 + x] = yellow }
    for y in 100...200 { clean.pixels[y * 320 + 160] = yellow }
    let graph = try XCTUnwrap(Graph.find(on: clean))
    XCTAssertEqual([graph.left, graph.top, graph.bottom], [25, 0, 230])
    var screen = clean
    draw(Self.tinySAMarker, at: (160, 100), on: &screen)
    let rows = graph.traceRows(on: screen)
    XCTAssertEqual(rows, graph.traceRows(on: clean))
    XCTAssertEqual(rows[160 - 25], 100)
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

  /// A trace across the minus signs has the reading on macOS 15 take them for letters: still minus signs, as a label is
  /// only ever a number. These are its readings of the 2.4 GHz screen, at both zooms.
  func testLevelFitTakesMinusSignsReadAsLetters() throws {
    let graph = Graph(left: 30, right: 480, top: 0, bottom: 240, gridRows: stride(from: 0, through: 240, by: 24).map { $0 })
    let readings = [
      [(".......", -1), ("10", 2), ("-10", 49), ("H20", 72), ("F30", 95), ("F40", 119), ("H50", 144), (":60", 169),
        ("H80", 216)],
      [("OT", 2), ("...... .", -1), ("F10", 48), ("F20", 70), ("F30", 94), ("P40", 119), ("H50", 144), ("60", 169),
        ("H8O", 216)],
    ]
    for reading in readings {
      let fit = try XCTUnwrap(GraphScale.fitLevels(reading.map { LabelReader.Line(text: $0.0, top: $0.1) }, graph: graph))
      XCTAssertEqual(fit.0, 10, accuracy: 0.001)
      XCTAssertEqual(fit.1 * 24, -10, accuracy: 0.001)
    }
    XCTAssertEqual(GraphScale.levelValue("H8O"), -80)
    XCTAssertEqual(GraphScale.levelValue("+10"), 10)
    XCTAssertNil(GraphScale.levelValue("OT"))
    XCTAssertNil(GraphScale.levelValue("......."))
    XCTAssertNil(GraphScale.levelValue("dBm"))
  }

  /// The reading on macOS 27 turns level labels upside down ("09-" for "−60"), reads a zero as "Ö", and loses minus
  /// signs: these are its readings of the 915 MHz screens and the 433 MHz one, which still give the levels.
  func testLevelFitTakesMacOS27Readings() throws {
    let small = Graph(left: 30, right: 480, top: 0, bottom: 240, gridRows: Array(stride(from: 0, through: 240, by: 24)))
    let big = Graph(left: 30, right: 480, top: 0, bottom: 180, gridRows: Array(stride(from: 0, through: 180, by: 18)))
    let cases: [(Graph, [(String, Int)], Double, Double)] = [
      // screen-915.png at 8 times: all but the top label upside down, "−30" read as "08-" (a turned 3 is an "8").
      (small, [("09-", 170), ("OS-", 145), ("Oh-", 119), ("08-", 96), ("OI-", 50), ("10", 1)], 10, -10),
      // screen-915.png at 4 times: zeros read as "Ö".
      (small, [("10", 1), ("-10", 49), ("-20", 73), ("-30", 97), ("-5Ö", 144), ("-6Ö", 167)], 10, -10),
      // screen-433.png at 8 times, two labels upside down.
      (small, [("- 10", 25), ("-20", 50), ("-30", 73), ("-4ö", 96), ("OS-", 121), ("09-", 145), ("-70", 170),
        ("-80", 194)], 0, -10),
      // screen-915-big.png at 4 times: three labels, two without their minus.
      (big, [("10", 1), ("10", 37), ("20", 54)], 10, -10),
    ]
    for (graph, reading, level0, perDivision) in cases {
      let labels = reading.map { LabelReader.Line(text: $0.0, top: $0.1) }
      let fit = try XCTUnwrap(GraphScale.fitLevels(labels, graph: graph), "\(reading)")
      XCTAssertEqual(fit.0, level0, accuracy: 0.001, "\(reading)")
      XCTAssertEqual(fit.1 * Double(graph.gridRows[1]), perDivision, accuracy: 0.001, "\(reading)")
    }
    XCTAssertEqual(GraphScale.levelValues("09-"), [-60])
    XCTAssertEqual(GraphScale.levelValues("08-"), [-80, -30])
    XCTAssertEqual(GraphScale.levelValues(".OI-"), [-10])
    XCTAssertEqual(GraphScale.levelValues("30"), [30, -30])
    XCTAssertEqual(GraphScale.levelValues("-5Ö"), [-50])
    XCTAssertNil(GraphScale.upright("-60"))
    XCTAssertNil(GraphScale.upright("10"))
    XCTAssertEqual(GraphScale.upright("0Q-"), [])
    XCTAssertEqual(GraphScale.levelValues("dBm"), [])
    // The spacing of the grid's lines, read with a comma ("2„0MHz/"), or with a "Õ" for a zero.
    XCTAssertEqual(GraphScale.parseDivision("START 902.000000MHz 2„0МНz/ STOP 928.000000MHz"), 2_000_000)
    XCTAssertEqual(GraphScale.parseDivision("START 2.400000GHZ 10.ÕМНz/ STOP 2.483500GHZ"), 10_000_000)
    XCTAssertNil(GraphScale.parseDivision("START 902.000000MHz 0MHz/ STOP 928.000000MHz"))
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
    wait(for: [read], timeout: labelsRead)
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
    wait(for: [read], timeout: labelsRead)
    hold.onChange = nil
    hold.reset()
    hold.add(screen, at: Date())
    XCTAssertNotNil(hold.state?.scale)
    XCTAssertNotNil(hold.state?.peaks.first?.level)
    hold.window = 30
    hold.add(screen, at: Date())
    XCTAssertNotNil(hold.state?.scale)
  }

  /// An answer that can't wait for more frames (`tinysa-screen peaks`, its seconds up) waits for the read under way,
  /// then reads the labels once more from the latest frame when no read has had it: here the first frame's can't be
  /// read (the levels below the top two hidden, as a trace across them may hide them) and the next comes before the
  /// hold would try again, 2 s on, with the same labels' fingerprint. The hold alone would read them from a frame that
  /// never comes once the seconds are up.
  func testTheLabelsAreReadOnceMoreForAnAnswer() throws {
    let screen = try Fixture.screen("screen-915-burst.png")
    let graph = try XCTUnwrap(Graph.find(on: screen))
    var hidden = screen
    let levels = graph.labelRegions(screen)[0]
    for y in (graph.gridRows[2] - 2)..<levels.maxY {
      for x in levels.minX..<levels.maxX { hidden.pixels[y * screen.width + x] = Snapshot.pixel(r: 0, g: 0, b: 0) }
    }
    XCTAssertEqual(Graph.find(on: hidden), graph)
    XCTAssertEqual(graph.labelPrint(on: hidden), graph.labelPrint(on: screen))
    XCTAssertNil(GraphScale.read(graph, on: hidden))

    let hold = PeakHold()
    let start = Date()
    hold.add(hidden, at: start)
    hold.add(screen, at: start.addingTimeInterval(1))
    let (state, stillReading) = hold.labelsRead(by: Date().addingTimeInterval(labelsRead))
    XCTAssertFalse(stillReading)
    XCTAssertEqual(state?.scale?.start, 902_000_000)
    XCTAssertEqual(state?.scale?.stop, 928_000_000)
    XCTAssertEqual(try XCTUnwrap(state?.peaks.first?.level), -23.2, accuracy: 0.5)
    XCTAssertEqual(hold.state, state)
  }

  /// A read under way is waited for until the deadline (or until cancelled): then the state as it is, and that a read
  /// is under way.
  func testAnAnswerWaitsForTheReadUnderWay() throws {
    let hold = PeakHold()
    hold.add(try Fixture.screen("screen-915.png"), at: Date())
    for early in [hold.labelsRead(by: Date()), hold.labelsRead(by: .distantFuture, cancelled: { true })] {
      XCTAssertNotNil(early.state)
      if early.state?.scale == nil { XCTAssertTrue(early.stillReading) }  // a read takes a moment at least, as a rule
    }
    let (state, stillReading) = hold.labelsRead(by: Date().addingTimeInterval(labelsRead))
    XCTAssertFalse(stillReading)
    XCTAssertEqual(state?.scale?.start, 902_000_000)
    // Nothing more to read: at once.
    let again = Date()
    XCTAssertEqual(hold.labelsRead(by: .distantFuture).state, state)
    XCTAssertLessThan(Date().timeIntervalSince(again), 0.1)
    XCTAssertNil(PeakHold().labelsRead(by: .distantFuture).state)
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
    wait(for: [read], timeout: labelsRead)
    read = expectation(description: "2.4 GHz read")
    read.assertForOverFulfill = false
    hold.onChange = { state in
      if state?.scale?.start == 2_400_000_000 { read.fulfill() }
    }
    let changed = Date()
    hold.add(band2400, at: changed)
    XCTAssertEqual(hold.state?.rows, own)
    wait(for: [read], timeout: labelsRead)
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
    wait(for: [read], timeout: labelsRead)
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
