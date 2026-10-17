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
  public func traceRows(on screen: Snapshot) -> [Int?] {
    (left..<right).map { x in
      for y in top...bottom where Self.isTrace(screen.pixels[y * screen.width + x]) { return y }
      return nil
    }
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

  /// A fingerprint of the labels around the graph (white text), which changes when the span or the levels do.
  public func labelPrint(on screen: Snapshot) -> Int {
    var hasher = Hasher()
    let white = Snapshot.pixel(r: 255, g: 255, b: 255)
    for region in labelRegions(screen) {
      for y in region.minY..<region.maxY {
        for x in region.minX..<region.maxX where screen.pixels[y * screen.width + x] == white {
          hasher.combine(x &* 31 &+ y)
        }
      }
    }
    hasher.combine(gridRows)
    return hasher.finalize()
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

  /// The grid's spacing from the label between START and STOP ("2.0MHz/"): the middle of the three values.
  static func parseDivision(_ text: String) -> Int64? {
    let values = spanValues(text)
    return values.count == 3 ? values[1] : nil
  }


  /// The level labels (numbers at grid lines, the top of each at its line) fitted to a straight line: the levels
  /// that agree on one step per grid line, at least three of them. A misread label ("30" for "−30") disagrees and is
  /// left out.
  static func fitLevels(_ labels: [LabelReader.Line], graph: Graph) -> (Double, Double)? {
    var points: [(row: Int, value: Double)] = []
    for label in labels {
      let text = LabelReader.plain(label.text).replacingOccurrences(of: " ", with: "")
      guard let value = Double(text), let row = graph.gridRows.min(by: { abs($0 - label.top) < abs($1 - label.top) }),
        abs(row - label.top) <= 4
      else { continue }
      points.append((row, value))
    }
    guard points.count >= 3 else { return nil }
    let step = Double(graph.gridRows.count > 1 ? graph.gridRows[1] - graph.gridRows[0] : 1)
    // Each pair proposes a line; the line most labels agree with wins.
    var best: (level0: Double, perRow: Double, agreeing: Int)?
    for i in points.indices {
      for j in points.indices where j > i && points[j].row != points[i].row {
        let perRow = (points[j].value - points[i].value) / Double(points[j].row - points[i].row)
        let perDivision = perRow * step
        let fine = [0.1, 0.2, 0.5].contains { abs(abs(perDivision) - $0) < 0.001 }
        guard perRow < 0, abs(perDivision - perDivision.rounded()) < 0.01 || fine else { continue }
        let level0 = points[i].value - perRow * Double(points[i].row)
        let agreeing = points.filter { abs(level0 + perRow * Double($0.row) - $0.value) < 0.001 + abs(perRow) * 0.01 }
          .count
        if agreeing > (best?.agreeing ?? 0) { best = (level0, perRow, agreeing) }
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
/// macOS 15 read "MHz" as "642" or "6H2", and one smoothing-free try read "433" as "438").
enum LabelReader {
  /// Letters that look alike, as the screen's font has them: Cyrillic capitals for Latin ones, "$" for "S", "−" for
  /// "-".
  static let lookAlikes: [Character: Character] = [
    "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T", "Х": "X",
    "а": "a", "с": "c", "е": "e", "о": "o", "р": "p", "х": "x", "$": "S", "−": "-", "–": "-",
  ]

  static func plain(_ text: String) -> String { String(text.map { lookAlikes[$0] ?? $0 }) }

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
