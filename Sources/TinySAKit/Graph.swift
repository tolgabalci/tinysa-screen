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
    guard best.count >= 4, let first = best.first, let last = best.last else { return nil }
    let step = best[1] - best[0]
    // The left edge: the first column with a grid line down most of the graph.
    var left: Int?
    for x in 0..<(width / 4) {
      var grey = 0
      for y in first..<last where isGrid(screen.pixels[y * width + x]) { grey += 1 }
      if grey > (last - first) / 3 {
        left = x
        break
      }
    }
    guard let left else { return nil }
    // The bottom grid line is often hidden under the trace or the waterfall's top: one step below the last seen, if
    // the screen goes that far.
    let bottom = min(last + step, height - 1)
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
    return [
      (right - levelsWidth, max(0, top - 2), right, min(screen.height, bottom + 2)),
      (left, max(bottom, screen.height - 20), right, screen.height),
    ]
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

  /// Reads the labels of a graph on a screen: nil when they can't be read with confidence.
  public static func read(_ graph: Graph, on screen: Snapshot) -> GraphScale? {
    guard let image = screen.image() else { return nil }
    let regions = graph.labelRegions(screen)
    let levelRegion = regions[0]
    let spanRegion = regions[1]
    let levels = LabelReader.lines(in: image, region: levelRegion)
    let span = LabelReader.lines(in: image, region: spanRegion).map(\.text).joined(separator: " ")
    guard let (level0, perRow) = fitLevels(levels, graph: graph), let (start, stop) = parseSpan(span) else {
      return nil
    }
    return GraphScale(level0: level0, perRow: perRow, start: start, stop: stop)
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
        guard perRow < 0, abs(perDivision - perDivision.rounded()) < 0.01 || [0.1, 0.2, 0.5].contains(abs(perDivision))
        else { continue }
        let level0 = points[i].value - perRow * Double(points[i].row)
        let agreeing = points.filter { abs(level0 + perRow * Double($0.row) - $0.value) < 0.01 }.count
        if agreeing > (best?.agreeing ?? 0) { best = (level0, perRow, agreeing) }
      }
    }
    guard let best, best.agreeing >= 3, best.agreeing * 3 >= points.count * 2 else { return nil }
    return (best.level0, best.perRow)
  }

  /// "START 902.000000MHz ... STOP 928.000000MHz", or "CENTER 915.000000MHz ... SPAN 26.000000MHz", as read: look-alike
  /// letters taken for what they look like ("$TART", a Cyrillic "М" in "МHz", "O" for a zero in a number).
  static func parseSpan(_ text: String) -> (Int64, Int64)? {
    let upper = LabelReader.plain(text).uppercased()
    func value(after word: String) -> Int64? {
      guard let at = upper.range(of: word) else { return nil }
      let rest = upper[at.upperBound...].trimmingCharacters(in: .whitespaces)
      let number = String(rest.prefix { $0.isNumber || $0 == "." || $0 == "O" }).replacingOccurrences(of: "O", with: "0")
      let unit = rest.dropFirst(number.count).prefix(3)
      guard !number.isEmpty, let base = Double(number) else { return nil }
      let factor: Double =
        unit.hasPrefix("GHZ") ? 1e9 : unit.hasPrefix("MHZ") ? 1e6 : unit.hasPrefix("KHZ") ? 1e3 : unit.hasPrefix("HZ") ? 1 : 0
      guard factor > 0 else { return nil }
      return Int64((base * factor).rounded())
    }
    if let start = value(after: "START"), let stop = value(after: "STOP"), start < stop { return (start, stop) }
    if let center = value(after: "CENTER"), let span = value(after: "SPAN"), span > 0, center >= span / 2 {
      return (center - span / 2, center + span / 2)
    }
    return nil
  }
}

/// Text on the analyzer's screen, read with the Mac's text recognition (Vision). The screen's small bitmap font reads
/// best enlarged eight times, pixels kept square (four times misreads "902.000000MHz" as "902D00000hHz").
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
    guard width > 0, height > 0,
      let crop = image.cropping(to: CGRect(x: region.minX, y: region.minY, width: width, height: height)),
      let context = CGContext(
        data: nil, width: width * zoom, height: height * zoom, bitsPerComponent: 8, bytesPerRow: width * zoom * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return [] }
    context.interpolationQuality = .none
    context.draw(crop, in: CGRect(x: 0, y: 0, width: width * zoom, height: height * zoom))
    guard let enlarged = context.makeImage() else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.customWords = ["START", "STOP", "CENTER", "SPAN", "MHz", "GHz", "kHz", "dBm"]
    guard (try? VNImageRequestHandler(cgImage: enlarged).perform([request])) != nil else { return [] }
    return (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      let top = region.minY + Int(((1 - observation.boundingBox.maxY) * Double(height)).rounded())
      return Line(text: text, top: top)
    }
  }
}
