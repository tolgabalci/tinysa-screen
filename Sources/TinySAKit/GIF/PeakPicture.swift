import CoreGraphics
import CoreText
import Foundation

/// How the peak hold is drawn: its colour, and its peaks' readouts listed in a box, each by its number, or written
/// beside each peak.
public struct PeakLook: Hashable, Sendable {
  public var color: Color
  /// The readouts in a box, the peaks numbered; or beside each peak: when, the megahertz and the level.
  public var listed: Bool

  public init(color: Color = .cyan, listed: Bool = true) {
    self.color = color
    self.listed = listed
  }

  public struct Color: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
      self.red = red
      self.green = green
      self.blue = blue
    }

    public static let cyan = Color(red: 0, green: 255, blue: 255)

    var pixel: UInt32 { Snapshot.pixel(r: red, g: green, b: blue) }
  }
}

extension PeakHold.State {
  /// What the hold is, for VoiceOver: "Peak hold", or with how long it keeps levels, "Peak hold, last 1:00".
  public var title: String {
    guard let window else { return "Peak hold" }
    let seconds = Int(window)
    let held = seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) s"
    return "Peak hold, last " + held
  }

  /// The box of readouts, a peak a line in the order their levels came in (a peak whose level came in again later
  /// moves down): its number, when, the frequency and the level, as finely as the graph resolves,
  /// "1  11:09:21 PM  915.200 MHz  −45 dBm". None before the screen's labels are read, or without a peak.
  public func readouts(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
    guard let scale, !peaks.isEmpty else { return [] }
    let perColumn = Double(scale.stop - scale.start) / Double(max(graph.right - graph.left - 1, 1))
    let inOrder = peaks.sorted { ($0.time ?? .distantPast, $0.number) < ($1.time ?? .distantPast, $1.number) }
    return inOrder.compactMap { peak in
      guard let frequency = peak.frequency, let level = peak.level else { return nil }
      let when = peak.time.map { PeakHold.clock($0, locale: locale, timeZone: timeZone) + "  " } ?? ""
      return "\(peak.number)  " + when + PeakHold.frequency(frequency, resolution: perColumn) + "  "
        + PeakHold.level(level, resolution: abs(scale.perRow))
    }
  }
}

extension PeakHold.Peak {
  /// Written beside the peak when the peaks aren't listed in a box: when its level came in, its frequency to the
  /// nearest megahertz and its level to the decibel, a line each: "11:09:21 PM", "911 MHz", "−58 dBm". Before the
  /// screen's labels are read, when only.
  public func label(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
    var lines = time.map { [PeakHold.clock($0, locale: locale, timeZone: timeZone)] } ?? []
    if let frequency, let level {
      lines.append("\(Int((Double(frequency) / 1e6).rounded())) MHz")
      lines.append(PeakHold.level(level, resolution: 1))
    }
    return lines.isEmpty ? ["\(number)"] : lines
  }
}

extension PeakHold {
  /// A frequency in megahertz with as many decimals as a column of the graph resolves.
  public static func frequency(_ hertz: Int64, resolution: Double) -> String {
    let decimals = max(0, min(6, Int((-log10(max(resolution, 1) / 1e6)).rounded(.up))))
    return String(format: "%.\(decimals)f MHz", Double(hertz) / 1e6)
  }

  /// A level to the decibel, or the tenth where a row of the graph resolves that finely.
  public static func level(_ dBm: Double, resolution: Double) -> String {
    let text = resolution < 0.25 ? String(format: "%.1f dBm", dBm) : String(format: "%.0f dBm", dBm)
    return text.replacingOccurrences(of: "-", with: "−")
  }

  /// The time of day to the second, as the Mac writes it: "11:09:21 PM".
  public static func clock(_ moment: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return moment.formatted(
      Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone))
  }
}

/// Where the labels written beside peaks go, and which are away from their peaks, with an arrow to show whose they are.
public enum PeakLabels {
  public struct Place: Equatable, Sendable {
    public var rect: CGRect
    /// Away from its peak: an arrow from it to the peak's top says whose it is.
    public var away: Bool
  }

  /// Places for labels of `sizes` for peaks whose tops are at `tops`, inside `bounds`, top-down, taken in `order` (the
  /// oldest peak's first, so a newer one gives way): beside its top, right or left, or above it, where that's clear of
  /// the labels placed and of every peak (its top, and its line down from there); else the nearest clear spot around
  /// it, a spot to the side counting further and one below further still (above is the graph's emptier part), with an
  /// arrow; else beside it all the same.
  public static func place(
    _ sizes: [CGSize], at tops: [CGPoint], order: [Int]? = nil, within bounds: CGRect, gap: CGFloat
  ) -> [Place] {
    var places = sizes.map { Place(rect: CGRect(origin: .zero, size: $0), away: false) }
    var taken: [CGRect] = []
    // Each peak's line, from its top down.
    let stems = tops.map { CGRect(x: $0.x - 1, y: $0.y, width: 2, height: max(bounds.maxY - $0.y, 0)) }
    for i in order ?? Array(sizes.indices) where i < sizes.count && i < tops.count {
      let (size, top) = (sizes[i], tops[i])
      func fits(_ rect: CGRect) -> Bool {
        bounds.contains(rect) && !taken.contains { $0.intersects(rect) }
          && !tops.contains { rect.insetBy(dx: -2, dy: -2).contains($0) }
          && !stems.contains { $0.intersects(rect) }
      }
      func at(_ center: CGPoint) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
      }
      let beside = [
        CGRect(x: top.x + gap, y: top.y - size.height / 2, width: size.width, height: size.height),
        CGRect(x: top.x - gap - size.width, y: top.y - size.height / 2, width: size.width, height: size.height),
        at(CGPoint(x: top.x, y: top.y - gap - size.height / 2)),
      ]
      var place = beside.first(where: fits).map { Place(rect: $0, away: false) }
      if place == nil {
        // Spots on rings around the top, nearest first: to the side counts half as far again, below three times.
        let directions: [(x: CGFloat, y: CGFloat)] = [
          (0, -1), (0.5, -1), (-0.5, -1), (1, -1), (-1, -1), (1, 0), (-1, 0), (1, 1), (-1, 1), (0, 1),
        ]
        let step = (x: size.width / 2 + gap, y: size.height + gap)
        var spots: [(cost: CGFloat, rect: CGRect)] = []
        for ring in 1...12 {
          for direction in directions {
            let offset = CGPoint(x: direction.x * CGFloat(ring) * step.x, y: direction.y * CGFloat(ring) * step.y)
            let weight: CGFloat = direction.y > 0 ? 3 : direction.y == 0 ? 1.5 : 1
            spots.append((hypot(offset.x, offset.y) * weight, at(CGPoint(x: top.x + offset.x, y: top.y + offset.y))))
          }
        }
        place = spots.sorted { $0.cost < $1.cost }.first { fits($0.rect) }.map { Place(rect: $0.rect, away: true) }
      }
      let chosen = place ?? Place(rect: inside(beside[0], bounds), away: false)
      places[i] = chosen
      taken.append(chosen.rect)
    }
    return places
  }

  /// The arrow from a label away from its peak: from the label's edge nearest the peak's top to that top.
  public static func arrow(from rect: CGRect, to top: CGPoint) -> (from: CGPoint, to: CGPoint) {
    (CGPoint(x: min(max(top.x, rect.minX), rect.maxX), y: min(max(top.y, rect.minY), rect.maxY)), top)
  }

  private static func inside(_ rect: CGRect, _ bounds: CGRect) -> CGRect {
    var rect = rect
    rect.origin.x = min(max(rect.minX, bounds.minX), max(bounds.maxX - rect.width, bounds.minX))
    rect.origin.y = min(max(rect.minY, bounds.minY), max(bounds.maxY - rect.height, bounds.minY))
    return rect
  }
}

/// The peak hold drawn into a picture of the screen (a GIF's frames, a screenshot), as the window draws it over the
/// screen: the held trace, a line in the hold's colour edged in black; with the peaks listed, each high peak's number
/// in a tag of that colour and the readouts in a black box edged in it, where the window puts them; else beside each
/// peak, when, the megahertz and the level in a black box edged in it. In few colours, its edges crisp and its words in
/// eight shades over their tags and boxes, so a GIF keeps every colour exact.
struct PeakPicture {
  let width: Int
  let height: Int
  let scale: Int
  let look: PeakLook
  let locale: Locale
  let timeZone: TimeZone
  private let color: UInt32
  private let font: CTFont
  private let lineHeight: Int
  private let descent: CGFloat

  static let black = Snapshot.pixel(r: 0, g: 0, b: 0)
  static let white = Snapshot.pixel(r: 255, g: 255, b: 255)

  /// For a picture `width` by `height` pixels, `scale` of them to each of the screen's.
  init(width: Int, height: Int, scale: Int, look: PeakLook, locale: Locale = .current, timeZone: TimeZone = .current) {
    self.width = width
    self.height = height
    self.scale = max(scale, 1)
    self.look = look
    self.locale = locale
    self.timeZone = timeZone
    color = look.color.pixel
    // The window's size of words over the screen, legible at the screen's own size too.
    let size = max(8, 5.5 * CGFloat(self.scale))
    let base = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
    let descriptor = CTFontDescriptorCreateCopyWithFeature(
      CTFontCopyFontDescriptor(base), kNumberSpacingType as CFNumber, kMonospacedNumbersSelector as CFNumber)
    font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    descent = CTFontGetDescent(font).rounded(.up)
    lineHeight = Int((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up))
  }

  /// What the hold covers, in its colours; 0 where it leaves the screen as it is.
  func pixels(for state: PeakHold.State) -> [UInt32] {
    var pixels = [UInt32](repeating: 0, count: width * height)
    drawLine(state, into: &pixels)
    if look.listed {
      for peak in state.peaks {
        let top = center(peak.column, peak.row)
        let number = "\(peak.number)"
        let box = (
          x: top.x + 3 * scale, y: top.y - lineHeight / 2, width: measure(number) + 4 * scale, height: lineHeight
        )
        fill(box, color, into: &pixels)
        write(number, x: box.x + 2 * scale, y: box.y, ink: Self.black, over: color, into: &pixels)
      }
      drawReadouts(state, into: &pixels)
    } else {
      drawLabels(state, into: &pixels)
    }
    return pixels
  }

  /// The middle of one of the screen's pixels, in the picture's.
  private func center(_ column: Int, _ row: Int) -> (x: Int, y: Int) {
    (column * scale + scale / 2, row * scale + scale / 2)
  }

  private func drawLine(_ state: PeakHold.State, into pixels: inout [UInt32]) {
    let thickness = max(1, Int((0.75 * Double(scale)).rounded()))
    var line = [Bool](repeating: false, count: width * height)
    var edge = line
    var previous: (x: Int, y: Int)?
    for (i, row) in state.rows.enumerated() {
      guard let row else {
        previous = nil
        continue
      }
      let point = center(state.graph.left + i, row)
      stroke(from: previous ?? point, to: point, thickness: thickness, into: &line)
      stroke(from: previous ?? point, to: point, thickness: thickness + 2, into: &edge)
      previous = point
    }
    for i in pixels.indices where edge[i] { pixels[i] = line[i] ? color : Self.black }
  }

  /// A straight line `thickness` pixels across, square pen.
  private func stroke(from a: (x: Int, y: Int), to b: (x: Int, y: Int), thickness: Int, into mask: inout [Bool]) {
    let steps = max(abs(b.x - a.x), abs(b.y - a.y), 1)
    let back = thickness / 2
    for k in 0...steps {
      let x = a.x + (b.x - a.x) * k / steps - back
      let y = a.y + (b.y - a.y) * k / steps - back
      for py in Self.within(y, y + thickness, height) {
        for px in Self.within(x, x + thickness, width) { mask[py * width + px] = true }
      }
    }
  }

  /// The readouts' box, hanging from the emptiest spot the hold found, kept inside the graph.
  private func drawReadouts(_ state: PeakHold.State, into pixels: inout [UInt32]) {
    let lines = state.readouts(locale: locale, timeZone: timeZone)
    guard !lines.isEmpty else { return }
    let padding = 3 * scale
    let box = (width: (lines.map(measure).max() ?? 0) + 2 * padding, height: lines.count * lineHeight + 2 * padding)
    let right = state.graph.right * scale - 36 * scale
    let x = max(0, min(state.quietSpot.x * scale, right - box.width))
    let y = max(0, state.quietSpot.y * scale)
    drawBox(lines, x: x, y: y, width: box.width, padding: padding, into: &pixels)
  }

  /// Each peak's label beside it, inside the graph.
  private func drawLabels(_ state: PeakHold.State, into pixels: inout [UInt32]) {
    let padding = 2 * scale
    let labels = state.peaks.map { $0.label(locale: locale, timeZone: timeZone) }
    let sizes = labels.map { lines in
      CGSize(
        width: (lines.map(measure).max() ?? 0) + 2 * padding, height: lines.count * lineHeight + 2 * padding)
    }
    let tops = state.peaks.map { peak in
      let top = center(peak.column, peak.row)
      return CGPoint(x: top.x, y: top.y)
    }
    let graph = CGRect(
      x: state.graph.left * scale, y: state.graph.top * scale, width: (state.graph.right - state.graph.left) * scale,
      height: (state.graph.bottom - state.graph.top) * scale)
    let order = state.peaks.indices.sorted {
      (state.peaks[$0].time ?? .distantPast, state.peaks[$0].number)
        < (state.peaks[$1].time ?? .distantPast, state.peaks[$1].number)
    }
    let places = PeakLabels.place(sizes, at: tops, order: order, within: graph, gap: CGFloat(4 * scale))
    for (place, top) in zip(places, tops) where place.away {
      drawArrow(PeakLabels.arrow(from: place.rect, to: top), into: &pixels)
    }
    for (lines, place) in zip(labels, places) {
      let rect = place.rect
      drawBox(lines, x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), padding: padding, into: &pixels)
    }
  }

  /// A line in the hold's colour from a label to its peak's top, its head there.
  private func drawArrow(_ arrow: (from: CGPoint, to: CGPoint), into pixels: inout [UInt32]) {
    let (from, to) = arrow
    let length = hypot(to.x - from.x, to.y - from.y)
    guard length > 1 else { return }
    let (ux, uy) = ((to.x - from.x) / length, (to.y - from.y) / length)
    let head = CGFloat(5 * scale)
    let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
    var mask = [Bool](repeating: false, count: width * height)
    stroke(
      from: (Int(from.x), Int(from.y)), to: (Int(base.x), Int(base.y)), thickness: max(1, scale / 2 + scale % 2),
      into: &mask)
    // The head: a triangle, its tip at the top.
    let side = CGFloat(2.5 * Double(scale))
    let corners = [
      to, CGPoint(x: base.x - uy * side, y: base.y + ux * side), CGPoint(x: base.x + uy * side, y: base.y - ux * side),
    ]
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    func sign(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
      (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
    }
    for y in Self.within(Int(ys.min()!.rounded(.down)), Int(ys.max()!.rounded(.up)) + 1, height) {
      for x in Self.within(Int(xs.min()!.rounded(.down)), Int(xs.max()!.rounded(.up)) + 1, width) {
        let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
        let (d1, d2, d3) = (
          sign(p, corners[0], corners[1]), sign(p, corners[1], corners[2]), sign(p, corners[2], corners[0])
        )
        let inside = !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
        if inside { mask[y * width + x] = true }
      }
    }
    for i in pixels.indices where mask[i] { pixels[i] = color }
  }

  /// White words on black in a box edged in the hold's colour.
  private func drawBox(
    _ lines: [String], x: Int, y: Int, width boxWidth: Int, padding: Int, into pixels: inout [UInt32]
  ) {
    let boxHeight = lines.count * lineHeight + 2 * padding
    fill((x, y, boxWidth, boxHeight), color, into: &pixels)
    fill((x + 1, y + 1, boxWidth - 2, boxHeight - 2), Self.black, into: &pixels)
    for (i, line) in lines.enumerated() {
      write(line, x: x + padding, y: y + padding + i * lineHeight, ink: Self.white, over: Self.black, into: &pixels)
    }
  }

  private func fill(_ box: (x: Int, y: Int, width: Int, height: Int), _ color: UInt32, into pixels: inout [UInt32]) {
    for y in Self.within(box.y, box.y + box.height, height) {
      for x in Self.within(box.x, box.x + box.width, width) { pixels[y * width + x] = color }
    }
  }

  /// From `start` up to `end`, inside 0 up to `limit`: empty where they don't meet.
  private static func within(_ start: Int, _ end: Int, _ limit: Int) -> Range<Int> {
    let (low, high) = (max(start, 0), min(end, limit))
    return low < high ? low..<high : 0..<0
  }

  private func line(_ text: String) -> CTLine {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
  }

  private func measure(_ text: String) -> Int {
    Int(CTLineGetTypographicBounds(line(text), nil, nil, nil).rounded(.up))
  }

  /// `text` from its top left at `x`, `y`, in `ink` over `under` (what's there already), in eight shades.
  private func write(_ text: String, x: Int, y: Int, ink: UInt32, over under: UInt32, into pixels: inout [UInt32]) {
    let textWidth = measure(text)
    guard textWidth > 0 else { return }
    var coverage = [UInt8](repeating: 0, count: textWidth * lineHeight)
    coverage.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: textWidth, height: lineHeight, bitsPerComponent: 8, bytesPerRow: textWidth,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return }
      context.setShouldSmoothFonts(false)
      context.setFillColor(gray: 1, alpha: 1)
      context.textPosition = CGPoint(x: 0, y: descent)
      CTLineDraw(line(text), context)
    }
    let top = CaptionStrip.levels - 1
    for row in 0..<lineHeight where y + row >= 0 && y + row < height {
      for column in 0..<textWidth where x + column >= 0 && x + column < width {
        let level = (Int(coverage[row * textWidth + column]) * top + 127) / 255
        if level > 0 { pixels[(y + row) * width + x + column] = CaptionStrip.blend(under, ink, level) }
      }
    }
  }
}
