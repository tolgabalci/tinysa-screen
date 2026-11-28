import CoreGraphics
import CoreText
import Foundation

/// How the peak hold is drawn: its colour, and its peaks' readouts: in a box, each peak numbered; beside each peak;
/// or only the numbers (the window's list beside the screen has the rest).
public struct PeakLook: Hashable, Sendable {
  public var color: Color
  public var readouts: Readouts
  /// The colour of the labels' edges and of the arrows from labels moved away from their peaks: not the hold's, so
  /// neither is taken for part of its line.
  public var labelColor: Color

  public init(color: Color = .cyan, readouts: Readouts = .box, labelColor: Color = .orange) {
    self.color = color
    self.readouts = readouts
    self.labelColor = labelColor
  }

  public enum Readouts: String, CaseIterable, Hashable, Sendable {
    /// Numbered tags, and a box listing each peak: its number, when, the frequency and the level.
    case box
    /// Beside each peak, when, the megahertz and the level.
    case labels
    /// Numbered tags only.
    case numbers
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
    public static let orange = Color(red: 255, green: 153, blue: 26)

    var pixel: UInt32 { Snapshot.pixel(r: red, g: green, b: blue) }
  }
}

extension PeakHold.State {
  /// The hold's period, over its box and its list: "Peak hold, last 1:00", or "Peak hold, until cleared".
  public var title: String {
    guard let window else { return "Peak hold, until cleared" }
    let seconds = Int(window)
    let held = seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) s"
    return "Peak hold, last " + held
  }

  /// The box of readouts: the hold's period, then a peak a line in the order their levels came in (a peak whose
  /// level came in again later moves down): its number, when, the frequency and the level, as finely as the graph
  /// resolves, "1  11:09:21 PM  915.200 MHz  −45 dBm". None before the screen's labels are read, or without a peak.
  public func readouts(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
    guard let scale, !peaks.isEmpty else { return [] }
    let perColumn = Double(scale.stop - scale.start) / Double(max(graph.right - graph.left - 1, 1))
    let inOrder = peaks.sorted { ($0.time ?? .distantPast, $0.number) < ($1.time ?? .distantPast, $1.number) }
    return [title] + inOrder.compactMap { peak in
      guard let frequency = peak.frequency, let level = peak.level else { return nil }
      let when = peak.time.map { PeakHold.clock($0, locale: locale, timeZone: timeZone) + "  " } ?? ""
      return "\(peak.number)  " + when + PeakHold.frequency(frequency, resolution: perColumn) + "  "
        + PeakHold.level(level, resolution: abs(scale.perRow))
    }
  }
}

extension PeakHold.Peak {
  /// Written beside the peak when the peaks aren't listed in a box: when its level came in (without AM or PM, for
  /// room), its frequency to the nearest megahertz and its level to the decibel, a line each: "11:09:21", "911 MHz",
  /// "−58 dBm". Before the screen's labels are read, when only.
  public func label(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
    var lines = time.map { [PeakHold.clock($0, locale: locale, timeZone: timeZone, dayPeriod: false)] } ?? []
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

  /// The time of day to the second, as the Mac writes it: "11:09:21 PM"; without its AM or PM, "11:09:21".
  public static func clock(
    _ moment: Date, locale: Locale = .current, timeZone: TimeZone = .current, dayPeriod: Bool = true
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let text = moment.formatted(
      Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone))
    guard !dayPeriod else { return text }
    // The language's own time, its AM or PM taken out (a 24-hour clock has none).
    let names = DateFormatter()
    names.locale = locale
    var plain = text
    for symbol in [names.amSymbol, names.pmSymbol] where !(symbol ?? "").isEmpty {
      plain = plain.replacingOccurrences(of: symbol!, with: "")
    }
    return plain.trimmingCharacters(in: .whitespaces)
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
  /// oldest peak's first, so a newer one gives way). Beside its top, right or left, or just above it, where that's
  /// clear of the labels placed, their arrows and every peak's top (the graph's lines may go under it). Else the best
  /// spot nearby: touching its top (within `near` of it, `gap` × 2.5, and clearly nearer its own top than any other, by
  /// `gap` × 2), with no arrow, which reads as the peak's; or far enough for an arrow to show its line as well as its
  /// head (`gap` × 5 at least), the arrow short and angled or upright (a level one, sideways, counts four times as
  /// long, a shallow one half as long again; below the top a quarter longer than above), passing behind no label.
  /// Nothing in between: an arrow too short to see is only its head. Else beside it all the same. Close, over the
  /// graph, beats clear and far.
  public static func place(
    _ sizes: [CGSize], at tops: [CGPoint], order: [Int]? = nil, within bounds: CGRect, gap: CGFloat
  ) -> [Place] {
    var places = sizes.map { Place(rect: CGRect(origin: .zero, size: $0), away: false) }
    var taken: [CGRect] = []
    var arrows: [(from: CGPoint, to: CGPoint)] = []
    let (near, shortestArrow) = (gap * 2.5, gap * 5)
    func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
      let (from, _) = arrow(from: rect, to: point)
      return hypot(point.x - from.x, point.y - from.y)
    }
    for i in order ?? Array(sizes.indices) where i < sizes.count && i < tops.count {
      let (size, top) = (sizes[i], tops[i])
      func fits(_ rect: CGRect) -> Bool {
        bounds.contains(rect) && !taken.contains { $0.intersects(rect) }
          && !tops.contains { rect.insetBy(dx: -3, dy: -3).contains($0) }
          && !arrows.contains { crosses($0.from, $0.to, rect.insetBy(dx: -1, dy: -1)) }
      }
      let beside = [
        CGRect(x: top.x + gap, y: top.y - size.height / 2, width: size.width, height: size.height),
        CGRect(x: top.x - gap - size.width, y: top.y - size.height / 2, width: size.width, height: size.height),
        CGRect(x: top.x - size.width / 2, y: top.y - gap - size.height, width: size.width, height: size.height),
      ]
      var place = beside.first(where: fits).map { Place(rect: $0, away: false) }
      if place == nil {
        var best: (cost: CGFloat, place: Place)?
        let (stepX, stepY) = (max(size.width / 8, 2), max(size.height / 6, 2))
        for row in -36...36 {
          for column in -36...36 {
            let center = CGPoint(x: top.x + CGFloat(column) * stepX, y: top.y + CGFloat(row) * stepY)
            let rect = inside(
              CGRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
              bounds)
            let length = distance(rect, top)
            // Touching its own top, the nearest to it: the peak's, no arrow. Too far to touch, too near for an arrow:
            // neither.
            let touching =
              length <= near && !tops.indices.contains { $0 != i && distance(rect, tops[$0]) <= length + 2 * gap }
            guard touching || length >= shortestArrow else { continue }
            let (from, to) = arrow(from: rect, to: top)
            let steep = abs(to.y - from.y) / max(length, 1)  // 0 level, 1 upright
            var cost =
              touching ? length : length * (steep < 0.42 ? 4 : steep < 0.7 ? 1.5 : 1) * (rect.minY > top.y ? 1.25 : 1)
            cost += 0.001 * CGFloat(abs(row) + abs(column))  // equal costs: the nearer spot
            guard cost < best?.cost ?? .infinity, fits(rect),
              touching || !taken.contains(where: { crosses(from, to, $0.insetBy(dx: 0.5, dy: 0.5)) })
            else { continue }
            best = (cost, Place(rect: rect, away: !touching))
          }
        }
        place = best?.place
      }
      let chosen = place ?? Place(rect: inside(beside[0], bounds), away: false)
      places[i] = chosen
      taken.append(chosen.rect)
      if chosen.away { arrows.append(arrow(from: chosen.rect, to: top)) }
    }
    return places
  }

  /// Whether the line from `a` to `b` passes through `rect` (a stretch of it inside, not a touch of an edge).
  static func crosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
    var (low, high): (CGFloat, CGFloat) = (0, 1)
    let (dx, dy) = (b.x - a.x, b.y - a.y)
    for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
      if p == 0 {
        if q <= 0 { return false }
        continue
      }
      let t = q / p
      if p < 0 { low = max(low, t) } else { high = min(high, t) }
      if low >= high { return false }
    }
    return true
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
    switch look.readouts {
    case .box, .numbers:
      for peak in state.peaks {
        let top = center(peak.column, peak.row)
        let number = "\(peak.number)"
        let box = (
          x: top.x + 3 * scale, y: top.y - lineHeight / 2, width: measure(number) + 4 * scale, height: lineHeight
        )
        fill(box, color, into: &pixels)
        write(number, x: box.x + 2 * scale, y: box.y, ink: Self.black, over: color, into: &pixels)
      }
      if look.readouts == .box { drawReadouts(state, into: &pixels) }
    case .labels:
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
    drawBox(lines, x: x, y: y, width: box.width, padding: padding, edge: color, into: &pixels)
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
      drawBox(
        lines, x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), padding: padding,
        edge: look.labelColor.pixel, centred: true, into: &pixels)
    }
  }

  /// A line in the labels' colour from a label to its peak's top, its head there.
  private func drawArrow(_ arrow: (from: CGPoint, to: CGPoint), into pixels: inout [UInt32]) {
    let (from, to) = arrow
    let length = hypot(to.x - from.x, to.y - from.y)
    guard length > 1 else { return }
    let (ux, uy) = ((to.x - from.x) / length, (to.y - from.y) / length)
    let head = CGFloat(5 * scale)
    let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
    var mask = [Bool](repeating: false, count: width * height)
    stroke(from: (Int(from.x), Int(from.y)), to: (Int(base.x), Int(base.y)), thickness: scale, into: &mask)
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
    let ink = look.labelColor.pixel
    for i in pixels.indices where mask[i] { pixels[i] = ink }
  }

  /// White words on black in a box edged in `edge` (the hold's colour for its box, the labels' for a label), each line
  /// `centred` (a label's) or from the left.
  private func drawBox(
    _ lines: [String], x: Int, y: Int, width boxWidth: Int, padding: Int, edge: UInt32, centred: Bool = false,
    into pixels: inout [UInt32]
  ) {
    let boxHeight = lines.count * lineHeight + 2 * padding
    fill((x, y, boxWidth, boxHeight), edge, into: &pixels)
    fill((x + 1, y + 1, boxWidth - 2, boxHeight - 2), Self.black, into: &pixels)
    for (i, line) in lines.enumerated() {
      let left = centred ? x + (boxWidth - measure(line)) / 2 : x + padding
      write(line, x: left, y: y + padding + i * lineHeight, ink: Self.white, over: Self.black, into: &pixels)
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
