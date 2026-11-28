import CoreGraphics
import Foundation
import Vision

/// The analyzer's graph, found from its screen alone: where the grid is, where the live trace (trace 1, yellow) runs,
/// and, read from the screen's own labels with the Mac's text recognition, the levels the grid lines stand for and the
/// frequencies at its edges. Nothing is asked of the analyzer, so this works on fed pictures too and never disturbs a
/// sweep.
public struct Graph: Equatable, Sendable {
  /// Columns of the graph: the first, and one past the last (a sweep point a column on a tinySA Ultra).
  public var left: Int
  public var right: Int
  /// Rows of the top and bottom grid lines, and of each grid line from the top.
  public var top: Int
  public var bottom: Int
  public var gridRows: [Int]

  /// The graph on a screen: nil when there isn't one to find (a menu over it, a screen of another kind).
  public static func find(on screen: Snapshot) -> Graph? {
    let width = screen.width
    let height = screen.height
    // Horizontal grid lines: dotted grey across the graph, a pixel in two or three.
    var rows: [Int] = []
    let from = width / 16
    let to = width * 15 / 16
    for y in 0..<height {
      var grey = 0
      for x in from..<to where isGrid(screen.pixels[y * width + x]) { grey += 1 }
      if grey > (to - from) / 4 { rows.append(y) }
    }
    // Evenly spaced: the longest run of lines one step apart.
    guard rows.count >= 4 else { return nil }
    var best: [Int] = []
    for i in rows.indices {
      for j in (i + 1)..<rows.count {
        let step = rows[j] - rows[i]
        guard step >= 8 else { continue }
        var run = [rows[i], rows[j]]
        while rows.contains(run.last! + step) { run.append(run.last! + step) }
        if run.count > best.count { best = run }
      }
    }
    guard best.count >= 4, let first = best.first else { return nil }
    let step = best[1] - best[0]
    // The left edge: where the horizontal grid lines start, the leftmost start two of them agree on. A trace crossing
    // the lines there hides their first dots (and the vertical line at the edge can be all trace where a signal sits
    // on the first point), but not on every line; one stray grey pixel doesn't make an edge.
    let starts = best.compactMap { y in (0..<(width / 4)).first { isGrid(screen.pixels[y * width + $0]) } }
    guard let left = Set(starts).sorted().first(where: { x in starts.filter { $0 == x }.count >= 2 }) else {
      return nil
    }
    // The graph has ten divisions (the firmware's NGRIDY), its bottom line often hidden under the trace or the
    // waterfall's top.
    let bottom = min(first + 10 * step, height - 1)
    let gridRows = stride(from: first, through: bottom, by: step).map { $0 }
    return Graph(left: left, right: width, top: first, bottom: bottom, gridRows: gridRows)
  }

  /// The grid's grey, alone or ORed with a trace's colour where they cross... but never a trace's own colour.
  static func isGrid(_ pixel: UInt32) -> Bool {
    let (r, g, b) = Snapshot.rgb(pixel)
    return r >= 0x70 && r < 0xF0 && g >= 0x70 && g < 0xF0 && b >= 0x70 && b < 0xF0
      && abs(Int(r) - Int(b)) < 24 && abs(Int(r) - Int(g)) < 24
  }

  /// Trace 1's colour, yellow, alone or ORed with the grid or another trace (red and green full, blue not).
  static func isTrace(_ pixel: UInt32) -> Bool {
    let (r, g, b) = Snapshot.rgb(pixel)
    return r == 0xFF && g == 0xFF && b < 0xF0
  }

  /// The live trace's highest row in each column of the graph, nil where it isn't drawn (a menu over it, say).
  ///
  /// The analyzer writes its markers' readouts ("1: 166.4MHz -55.4dBm") at the top of the graph in the trace's own
  /// yellow. The trace is one unbroken line from point to point, so in a column it is a single run of yellow; yellow
  /// in the top two divisions that ends there, with more yellow below it, is that text and is passed over. A trace
  /// reaching up into the text still counts from its top. The plates of the markers' symbols, in the same yellow
  /// (`MarkerSymbol`), are passed over too: the trace counts from its highest pixel above or below them.
  public func traceRows(on screen: Snapshot) -> [Int?] {
    let textBottom = min(gridRows.count > 2 ? gridRows[2] : top, bottom)
    var plates = [Bool](repeating: false, count: screen.pixels.count)
    let symbol = MarkerSymbol.on(screen)
    for corner in markerSymbols(on: screen) {
      for (row, columns) in symbol.rows.enumerated() {
        for column in columns { plates[(corner.y + row) * screen.width + corner.x + column] = true }
      }
    }
    return (left..<right).map { x in
      func isTrace(_ y: Int) -> Bool {
        let i = y * screen.width + x
        return Self.isTrace(screen.pixels[i]) && !plates[i]
      }
      var y = top
      while y <= bottom {
        guard isTrace(y) else {
          y += 1
          continue
        }
        let start = y
        while y <= bottom, isTrace(y) { y += 1 }
        if y <= textBottom, (y...bottom).contains(where: isTrace) { continue }
        return start
      }
      return nil
    }
  }

  /// A marker's symbol as the analyzer draws it, over the traces (the firmware's `marker_bitmap`): a plate in the
  /// colour of the trace the marker is on, pointing down at the marker's point just under its tip, with the marker's
  /// number on it in black. On a tinySA Ultra's screen (480 × 320) the plate is 9 pixels wide and 13 high, with a black
  /// border on its top and sides; on a tinySA's (320 × 240), 7 wide and 10 high, without one.
  struct MarkerSymbol: Sendable {
    /// The plate's columns in each of its rows, from its top left.
    var rows: [ClosedRange<Int>]
    /// The rows and columns the number may take: the rest of the plate is the trace's colour whatever the number. The
    /// rows below them are the plate's tip.
    var numberRows: ClosedRange<Int>
    var numberColumns: ClosedRange<Int>
    var bordered: Bool

    static let ultra = MarkerSymbol(
      rows: Array(repeating: 0...8, count: 9) + [1...7, 2...6, 3...5, 4...4], numberRows: 1...9, numberColumns: 1...7,
      bordered: true)
    static let tinySA = MarkerSymbol(
      rows: Array(repeating: 0...6, count: 7) + [1...5, 2...4, 3...3], numberRows: 1...7, numberColumns: 1...5,
      bordered: false)

    /// The symbol on a screen of the analyzer's.
    static func on(_ screen: Snapshot) -> MarkerSymbol { screen.width >= 480 ? ultra : tinySA }
  }

  /// The top left corners of the plates of markers' symbols in trace 1's yellow, or in another colour. A plate is
  /// told by its shape, which a trace never draws: its top and its tip whole (a trace, a line from point to point,
  /// never runs down from one row in three columns side by side), its number's black in its middle, and its sides
  /// and black border (on a tinySA Ultra) all but a few pixels, as another marker's symbol or a readout may cover some.
  func markerSymbols(on screen: Snapshot, colour isColour: (UInt32) -> Bool = Graph.isTrace) -> [(x: Int, y: Int)] {
    let symbol = MarkerSymbol.on(screen)
    let width = symbol.rows[0].count
    func pixel(_ x: Int, _ y: Int) -> UInt32? {
      x >= 0 && x < screen.width && y >= 0 && y < screen.height ? screen.pixels[y * screen.width + x] : nil
    }
    func isPlate(_ x: Int, _ y: Int) -> Bool {
      var off = 0
      var number = 0
      for (row, columns) in symbol.rows.enumerated() {
        for column in columns {
          guard let pixel = pixel(x + column, y + row) else { return false }
          if symbol.numberRows.contains(row), symbol.numberColumns.contains(column) {
            if isColour(pixel) { continue }
            guard Self.isBlack(pixel) else { return false }
            number += 1
          } else if !isColour(pixel) {
            guard row <= symbol.numberRows.upperBound else { return false }  // the tip
            off += 1
          }
        }
        if symbol.bordered {
          let sides = [columns.lowerBound - 1, columns.upperBound + 1]
          off += sides.filter { pixel(x + $0, y + row).map(isColour) == true }.count
        }
      }
      if symbol.bordered {
        off += (-1...width).filter { pixel(x + $0, y - 1).map(isColour) == true }.count
      }
      return number >= 4 && off <= 4
    }
    var corners: [(x: Int, y: Int)] = []
    for y in top...max(top, bottom - symbol.rows.count + 1) {
      var x = left
      while x + width <= right {
        // The plate's top: the colour all across.
        guard (x..<(x + width)).allSatisfy({ isColour(screen.pixels[y * screen.width + $0]) }), isPlate(x, y) else {
          x += 1
          continue
        }
        corners.append((x, y))
        x += width
      }
    }
    return corners
  }

  /// The screen's black, the analyzer's background.
  static func isBlack(_ pixel: UInt32) -> Bool {
    let (r, g, b) = Snapshot.rgb(pixel)
    return r < 0x40 && g < 0x40 && b < 0x40
  }

  /// The spacing of the vertical grid lines in pixels (the middle of the gaps between them; the left edge's line is
  /// left out, the grid lines being at round frequencies), or nil with fewer than three of them.
  func verticalSpacing(on screen: Snapshot) -> Double? {
    let rows = Array(stride(from: top + 1, to: bottom, by: 1))
    var lines: [Int] = []
    for x in (left + 2)..<max(left + 2, right - 36) {
      let grey = rows.filter { Graph.isGrid(screen.pixels[$0 * screen.width + x]) }.count
      if grey * 4 > rows.count, lines.last.map({ x - $0 > 2 }) ?? true { lines.append(x) }
    }
    guard lines.count >= 3 else { return nil }
    let gaps = zip(lines.dropFirst(), lines).map { Double($0 - $1) }.sorted()
    return gaps[gaps.count / 2]
  }

  /// A fingerprint of the labels, which changes when the span or the levels do: the span's text under the graph (its
  /// own rows only: the strongest dots of a waterfall just above are white too, and change every sweep) and the two
  /// top levels at the right edge (light grey; traces seldom reach that high, and a trace across a label hides some of
  /// its pixels), with the grid's rows.
  public func labelPrint(on screen: Snapshot) -> Int {
    var hasher = Hasher()
    let regions = labelRegions(screen)
    let span = regions[1]
    let levels = regions[0]
    let twoLevels = min(levels.maxY, (gridRows.count > 1 ? gridRows[1] : 24) + 10)
    for (rows, region) in [(max(span.minY, screen.height - 9)..<span.maxY, span), (levels.minY..<twoLevels, levels)] {
      for y in rows {
        for x in region.minX..<region.maxX where Self.isLabel(screen.pixels[y * screen.width + x]) {
          hasher.combine(x &* 31 &+ y)
        }
      }
    }
    hasher.combine(gridRows)
    return hasher.finalize()
  }

  /// A label's pixel: white (the span) or light grey (the levels), not the darker grid or a trace's colour.
  static func isLabel(_ pixel: UInt32) -> Bool {
    let (r, g, b) = (pixel & 0xFF, pixel >> 8 & 0xFF, pixel >> 16 & 0xFF)
    return r >= 160 && max(r, g, b) - min(r, g, b) <= 8
  }

  /// The levels at the right edge, and the span under the graph.
  func labelRegions(_ screen: Snapshot) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
    let levelsWidth = max(30, (right - left) / 11)
    let regions = [
      (max(left, right - levelsWidth), max(0, top - 2), right, min(screen.height, bottom + 2)),
      (left, min(screen.height, max(bottom, screen.height - 20)), right, screen.height),
    ]
    return regions.map { ($0.0, $0.1, max($0.0, min($0.2, screen.width)), max($0.1, $0.3)) }
  }
}

/// What the graph's grid lines and edges stand for, read from its labels.
public struct GraphScale: Equatable, Sendable {
  /// dBm at a row: `level0 + perRow * row`.
  public var level0: Double
  public var perRow: Double
  /// Hertz at the graph's left and right edges.
  public var start: Int64
  public var stop: Int64

  public init(level0: Double, perRow: Double, start: Int64, stop: Int64) {
    self.level0 = level0
    self.perRow = perRow
    self.start = start
    self.stop = stop
  }

  public func level(atRow row: Double) -> Double { level0 + perRow * row }

  /// The frequency of a column of the graph: the sweep's points spread evenly from its left edge to its right.
  public func frequency(column: Int, of graph: Graph) -> Int64 {
    let span = Double(stop - start)
    let index = Double(column - graph.left)
    let count = Double(max(graph.right - graph.left - 1, 1))
    return start + Int64((span * index / count).rounded())
  }

  /// Reads the labels of a graph on a screen: nil when they can't be read with confidence. They're read twice, at two
  /// sizes, and both reads must agree; the span must also agree with the grid (the label between START and STOP is
  /// the spacing of the vertical grid lines, whose pixels give the span by themselves). A misread digit ("438" for
  /// "433") would otherwise put every readout off.
  public static func read(_ graph: Graph, on screen: Snapshot) -> GraphScale? {
    guard let image = screen.image() else { return nil }
    let regions = graph.labelRegions(screen)
    var reads: [(scale: GraphScale, division: Int64?)] = []
    for zoom in [4, 8] {
      let levels = LabelReader.lines(in: image, region: regions[0], zoom: zoom)
      let span = LabelReader.lines(in: image, region: regions[1], zoom: zoom).map(\.text).joined(separator: " ")
      guard let (level0, perRow) = fitLevels(levels, graph: graph), let (start, stop) = parseSpan(span) else {
        return nil
      }
      reads.append((GraphScale(level0: level0, perRow: perRow, start: start, stop: stop), parseDivision(span)))
    }
    guard let scale = reads.first?.scale, reads.allSatisfy({ $0.scale.agrees(with: scale) }) else { return nil }
    if let division = reads.compactMap(\.division).first, let spacing = graph.verticalSpacing(on: screen) {
      guard fitsGrid(scale, division: division, spacing: spacing, width: graph.right - graph.left) else { return nil }
    }
    return scale
  }

  /// Whether a span agrees, within 3 %, with the one the grid gives: its width over the lines' spacing, times the
  /// spacing's frequency.
  static func fitsGrid(_ scale: GraphScale, division: Int64, spacing: Double, width: Int) -> Bool {
    let fromGrid = Double(width) * Double(division) / spacing
    let read = Double(scale.stop - scale.start)
    return abs(fromGrid - read) <= 0.03 * read
  }

  /// The same, to rounding.
  func agrees(with other: GraphScale) -> Bool {
    start == other.start && stop == other.stop && abs(level0 - other.level0) < 1e-6 && abs(perRow - other.perRow) < 1e-9
  }

  /// The grid's spacing from the label between START and STOP ("2.0MHz/"): the middle of the three values. Never 0:
  /// that's a misreading ("2„0MHz/" has the reading find "0MHz").
  static func parseDivision(_ text: String) -> Int64? {
    let values = spanValues(text)
    return values.count == 3 && values[1] > 0 ? values[1] : nil
  }


  /// A level label's value. A label is only ever a number, with or without its minus, so one mark before the digits
  /// that isn't one stands for the minus: a trace across the thin minus has it read as "H", "F", "P" or ":" ("H20" for
  /// "−20"; the reading on macOS 15 does), and an O among the digits is a zero.
  static func levelValue(_ label: String) -> Double? {
    let text = String(
      LabelReader.plain(label).replacingOccurrences(of: " ", with: "").map { $0 == "O" || $0 == "o" ? "0" : $0 })
    if let value = Double(text), value.isFinite { return value }
    guard let first = text.first, !first.isNumber, first != ".", text.dropFirst().first?.isNumber == true,
      let rest = Double(text.dropFirst()), rest.isFinite, rest >= 0
    else { return nil }
    return -rest
  }

  /// The values a level label may stand for: its value as read, or, read upside down, the right way up (`upright`);
  /// and a value without its minus may be its negative too, as the reading loses the screen's thin minus now and then
  /// ("30" for "−30"), never a digit that way.
  static func levelValues(_ label: String) -> [Double] {
    let values = levelValue(label).map { [$0] } ?? upright(label)?.compactMap(levelValue) ?? []
    return values.flatMap { $0 > 0 ? [$0, -$0] : [$0] }
  }

  /// Marks that stand for a minus: the reading takes the screen's thin minus for any of them.
  static let minusMarks: Set<Character> = ["-", "=", "÷", "~"]

  /// What each mark the reading gives for a label read upside down is the right way up: "09-" is "−60" turned half a
  /// turn, "Oh-" "−40", "OS-" "−50". An 8 may be a turned 3 as well (the reading takes "Ɛ" for "8").
  static let turned: [Character: [Character]] = [
    "0": ["0"], "O": ["0"], "o": ["0"], "1": ["1"], "I": ["1"], "l": ["1"], "i": ["1"], "|": ["1"], "2": ["2"],
    "Z": ["2"], "z": ["2"], "E": ["3"], "8": ["8", "3"], "h": ["4"], "5": ["5"], "S": ["5"], "s": ["5"], "9": ["6"],
    "6": ["9"], "L": ["7"], ".": ["."], "'": ["."], "`": ["."], "-": ["-"], "=": ["-"], "÷": ["-"], "~": ["-"],
  ]

  /// A level label read upside down, the right way up, or nil when it wasn't. The reading on macOS 27 turns some of
  /// the labels half a turn: a label is only digits and its minus, which read as something either way up. A label
  /// never ends with its minus, so one that does was read upside down. Several readings when an 8 may be a 3; none
  /// when a mark has no meaning turned.
  static func upright(_ label: String) -> [String]? {
    let marks = Array(LabelReader.plain(label).replacingOccurrences(of: " ", with: ""))
    guard let first = marks.first, let last = marks.last, minusMarks.contains(last), !minusMarks.contains(first) else {
      return nil
    }
    var readings = [""]
    for mark in marks.reversed() {
      guard let upright = turned[mark] else { return [] }
      readings = readings.flatMap { reading in upright.map { reading + String($0) } }
    }
    return readings
  }

  /// The level labels (numbers at grid lines, the top of each at its line) fitted to a straight line: the levels
  /// that agree on one step per grid line, at least three of them. A misread label disagrees and is left out.
  static func fitLevels(_ labels: [LabelReader.Line], graph: Graph) -> (Double, Double)? {
    var points: [(row: Int, values: [Double])] = []
    for label in labels {
      let values = levelValues(label.text)
      guard !values.isEmpty,
        let row = graph.gridRows.min(by: { abs($0 - label.top) < abs($1 - label.top) }),
        abs(row - label.top) <= 4
      else { continue }
      points.append((row, values))
    }
    guard points.count >= 3 else { return nil }
    let step = Double(graph.gridRows.count > 1 ? graph.gridRows[1] - graph.gridRows[0] : 1)
    // Each pair proposes a line, with each value either label may stand for; the line most labels agree with wins. A
    // label agrees when one of its values is the line's level at its row.
    var best: (level0: Double, perRow: Double, agreeing: Int)?
    for i in points.indices {
      for j in points.indices where j > i && points[j].row != points[i].row {
        for a in points[i].values {
          for b in points[j].values {
            let perRow = (b - a) / Double(points[j].row - points[i].row)
            let perDivision = perRow * step
            let fine = [0.1, 0.2, 0.5].contains { abs(abs(perDivision) - $0) < 0.001 }
            guard perRow < 0, abs(perDivision - perDivision.rounded()) < 0.01 || fine else { continue }
            let level0 = a - perRow * Double(points[i].row)
            let close = 0.001 + abs(perRow) * 0.01
            let agreeing = points.filter { point in
              let level = level0 + perRow * Double(point.row)
              return point.values.contains { abs(level - $0) < close }
            }
            .count
            if agreeing > (best?.agreeing ?? 0) { best = (level0, perRow, agreeing) }
          }
        }
      }
    }
    guard let best, best.agreeing >= 3, best.agreeing * 3 >= points.count * 2 else { return nil }
    return (best.level0, best.perRow)
  }

  /// The values with a unit under the graph, in order ("START 902.000000MHz 2.0MHz/ STOP 928.000000MHz" has three), as
  /// read: look-alike letters taken for what they look like, an "O" in a number for a zero.
  static func spanValues(_ text: String) -> [Int64] {
    var upper = Array(LabelReader.plain(text).uppercased())
    for i in upper.indices where upper[i] == "O" {
      let before = i > 0 && (upper[i - 1].isNumber || upper[i - 1] == ".")
      let after = i + 1 < upper.count && (upper[i + 1].isNumber || upper[i + 1] == ".")
      if before || after { upper[i] = "0" }
    }
    let line = String(upper)
    let pattern = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(GHZ|MHZ|KHZ|HZ)")
    return pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
      guard let numberRange = Range(match.range(at: 1), in: line), let unitRange = Range(match.range(at: 2), in: line),
        let value = Double(line[numberRange])
      else { return nil }
      let unit = line[unitRange]
      let factor: Double = unit == "GHZ" ? 1e9 : unit == "MHZ" ? 1e6 : unit == "KHZ" ? 1e3 : 1
      let hertz = (value * factor).rounded()
      return hertz < 1e11 ? Int64(exactly: hertz) : nil  // a misread number isn't a tinySA's span
    }
  }

  /// The span under the graph: its first and last values, START and STOP, or CENTER and SPAN. By their places, not
  /// their words, which recognition sometimes misspells ("STHRT", "$ToP").
  static func parseSpan(_ text: String) -> (Int64, Int64)? {
    let values = spanValues(text)
    guard values.count >= 2, let first = values.first, let last = values.last else { return nil }
    let upper = LabelReader.plain(text).uppercased()
    if upper.contains("CENT") || upper.contains("SPAN") {
      guard last > 0, first >= last / 2 else { return nil }
      return (first - last / 2, first + last / 2)
    }
    return first < last ? (first, last) : nil
  }

}

/// Text on the analyzer's screen, read with the Mac's text recognition (Vision). Recognition is made for dark text on a
/// light page, and the screen's is a small bitmap font in white on black: enlarged smoothly and turned dark on light,
/// with a margin, it reads right on macOS 13 to 15 as well as later (enlarged with square pixels, white on black,
/// macOS 15 read "MHz" as "642" or "6H2", and one smoothing-free try read "433" as "438"). The reading on macOS 27
/// gets more wrong, in ways the readers of the labels take back: an O with a diacritic ("-5Ö"), a comma for a point
/// ("2„0MHz/"), and level labels read upside down ("09-" for "−60").
enum LabelReader {
  /// Letters that look alike, as the screen's font has them: Cyrillic capitals for Latin ones, "$" for "S", "−" for
  /// "-", a comma for a point (the screen has no commas).
  static let lookAlikes: [Character: Character] = [
    "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T", "Х": "X",
    "а": "a", "с": "c", "е": "e", "о": "o", "р": "p", "х": "x", "$": "S", "−": "-", "–": "-", ",": ".", "„": ".",
  ]

  /// The text without diacritics (the screen's font has none: "Ö" is an O), its look-alikes as what they look like.
  static func plain(_ text: String) -> String {
    String(text.folding(options: .diacriticInsensitive, locale: nil).map { lookAlikes[$0] ?? $0 })
  }

  struct Line {
    var text: String
    /// The row of the line's top on the screen.
    var top: Int
  }

  static func lines(in image: CGImage, region: (minX: Int, minY: Int, maxX: Int, maxY: Int), zoom: Int = 8) -> [Line] {
    let width = region.maxX - region.minX
    let height = region.maxY - region.minY
    let margin = 8 * zoom
    let outWidth = width * zoom + 2 * margin
    let outHeight = height * zoom + 2 * margin
    guard width > 0, height > 0,
      let crop = image.cropping(to: CGRect(x: region.minX, y: region.minY, width: width, height: height))
    else { return [] }
    var grey = [UInt8](repeating: 0, count: outWidth * outHeight)
    let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: outWidth,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(crop, in: CGRect(x: margin, y: margin, width: width * zoom, height: height * zoom))
      return true
    }
    guard drawn else { return [] }
    for i in grey.indices { grey[i] = 255 - grey[i] }  // dark on light, the margin white
    guard let provider = CGDataProvider(data: Data(grey) as CFData),
      let enlarged = CGImage(
        width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: outWidth,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.customWords = ["START", "STOP", "CENTER", "SPAN", "MHz", "GHz", "kHz", "dBm"]
    guard (try? VNImageRequestHandler(cgImage: enlarged).perform([request])) != nil else { return [] }
    return (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      // The box's top in the enlarged picture, less the margin, back in the screen's rows.
      let topInPicture = (1 - observation.boundingBox.maxY) * Double(outHeight) - Double(margin)
      let top = region.minY + Int((topInPicture / Double(zoom)).rounded())
      return Line(text: text, top: top)
    }
  }
}
