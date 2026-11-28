import CoreGraphics
import CoreText
import Foundation

/// The strip under the screen in a GIF: at its bottom right the date and time of each moment, in the Mac's own date and
/// time formats, the time to the second so it ticks as the GIF plays; at its bottom left how far into the recording the
/// moment is, of how long it is ("0:10 / 2:30"), in a bar that fills as the GIF plays. White on black like the
/// analyzer's own text, smoothed in a few levels; pink through a second no picture came in, and "End of recording" in
/// red in the middle through the pause at the end. Its colours are few (the bar's square, the text's levels over what
/// it's on), so they fit the GIF's 256 with the screen's.
struct CaptionStrip {
  /// Shades of text over what it's on, from none to all.
  static let levels = 8

  static let black = Snapshot.pixel(r: 0, g: 0, b: 0)
  /// The bar: the part to come, and the part played.
  static let track = Snapshot.pixel(r: 58, g: 58, b: 62)
  static let filled = Snapshot.pixel(r: 32, g: 102, b: 204)

  /// The inks: white, the pink of a second without a picture, the red of the end.
  enum Ink: Int, CaseIterable {
    case white, pink, red

    var color: UInt32 {
      switch self {
      case .white: return Snapshot.pixel(r: 255, g: 255, b: 255)
      case .pink: return Snapshot.pixel(r: 255, g: 150, b: 165)
      case .red: return Snapshot.pixel(r: 255, g: 59, b: 48)
      }
    }
  }

  /// What the strip says, where, in which ink, and how much of the bar is filled.
  struct Words: Hashable {
    var left = ""
    var right = ""
    var center = ""
    var stale = false
    /// Pixels of the bar filled; nil without the bar.
    var filled: Int?
  }

  let width: Int
  let height: Int
  private let scale: Int
  private let font: CTFont
  private let date: DateFormatter?
  private let time: DateFormatter?
  private let showsElapsed: Bool
  /// The bar's place: from the left margin, as wide as leaves room for "End of recording" in the middle.
  private let bar: (x: Int, y: Int, width: Int, height: Int)?
  /// The strip last drawn: moments within a second say the same.
  private var last: (words: Words, pixels: [UInt32])?

  static let ending = "End of recording"

  /// Nil when the strip has nothing to say.
  init?(width: Int, scale: Int, options: GIFOptions) {
    guard options.hasCaption else { return nil }
    self.width = width
    self.scale = scale
    height = 16 * scale
    func formatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = options.locale
      formatter.timeZone = options.timeZone
      formatter.dateStyle = date
      formatter.timeStyle = time
      return formatter
    }
    date = options.showsDate ? formatter(date: .medium, time: .none) : nil
    time = options.showsTime ? formatter(date: .none, time: .medium) : nil
    showsElapsed = options.showsElapsed
    // The system font with digits of one width, so the time doesn't shift as it ticks.
    let base = CTFontCreateUIFontForLanguage(.system, CGFloat(11 * scale), nil)!
    let descriptor = CTFontDescriptorCreateCopyWithFeature(
      CTFontCopyFontDescriptor(base), kNumberSpacingType as CFNumber, kMonospacedNumbersSelector as CFNumber)
    font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(11 * scale), nil)
    if options.showsProgress {
      let margin = 6 * scale
      let ending = Int(Self.measure(Self.ending, font).rounded(.up))
      let room = (width - ending) / 2 - margin - 4 * scale
      let barWidth = max(min(width * 38 / 100, room), 24 * scale)
      bar = (margin, 2 * scale, barWidth, 12 * scale)
    } else {
      bar = nil
    }
  }

  /// The date and time at a moment, as the strip's right says it.
  func text(at moment: Date) -> String {
    [date?.string(from: moment), time?.string(from: moment)].compactMap { $0 }.joined(separator: "   ")
  }

  /// What the strip says for a caption: the bar filled as far as the count of seconds has gone.
  func words(_ caption: Caption) -> Words {
    var words = Words(
      left: showsElapsed ? "\(Self.duration(caption.elapsed)) / \(Self.duration(caption.total))" : "",
      right: text(at: caption.clock), center: caption.ended ? Self.ending : "", stale: caption.stale)
    if let bar {
      let played = caption.total > 0 ? min(max(Double(caption.elapsed) / Double(caption.total), 0), 1) : 1
      words.filled = Int((played * Double(bar.width)).rounded())
    }
    return words
  }

  /// "0:10", "2:30", "−0:20" (a preview before the GIF's start).
  static func duration(_ seconds: Int) -> String {
    let whole = abs(seconds)
    return (seconds < 0 ? "\u{2212}" : "") + String(format: "%d:%02d", whole / 60, whole % 60)
  }

  /// The strip saying `words`: its colour at each pixel, row by row from the top left.
  mutating func pixels(for words: Words) -> [UInt32] {
    if let last, last.words == words { return last.pixels }
    var pixels = [UInt32](repeating: Self.black, count: width * height)
    // The bar: square but for its corner pixels, the part played from the left.
    if let bar, let filled = words.filled {
      for y in bar.y..<(bar.y + bar.height) {
        for x in bar.x..<(bar.x + bar.width) {
          let top = y == bar.y || y == bar.y + bar.height - 1
          if top && (x == bar.x || x == bar.x + bar.width - 1) { continue }
          pixels[y * width + x] = x - bar.x < filled ? Self.filled : Self.track
        }
      }
    }
    let margin = CGFloat(6 * scale)
    let ink = words.stale ? Ink.pink : .white
    let left: (CGFloat) -> CGFloat =
      bar.map { bar in { textWidth in CGFloat(bar.x) + (CGFloat(bar.width) - textWidth) / 2 } } ?? { _ in margin }
    let parts: [(String, Ink, (CGFloat) -> CGFloat)] = [
      (words.left, ink, left),
      (words.right, ink, { [width] textWidth in CGFloat(width) - margin - textWidth }),
      (words.center, .red, { [width] textWidth in (CGFloat(width) - textWidth) / 2 }),
    ]
    let top = Self.levels - 1
    for (text, partInk, x) in parts where !text.isEmpty {
      let coverage = draw(text, at: x)
      for i in coverage.indices where coverage[i] > 0 {
        let level = (Int(coverage[i]) * top + 127) / 255
        if level > 0 { pixels[i] = Self.blend(pixels[i], partInk.color, level) }
      }
    }
    last = (words, pixels)
    return pixels
  }

  /// `ink` over `under`, `level` levels of the way.
  static func blend(_ under: UInt32, _ ink: UInt32, _ level: Int) -> UInt32 {
    let top = levels - 1
    let (r0, g0, b0) = Snapshot.rgb(under)
    let (r1, g1, b1) = Snapshot.rgb(ink)
    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Int(a) * (top - level) + Int(b) * level + top / 2) / top) }
    return Snapshot.pixel(r: mix(r0, r1), g: mix(g0, g1), b: mix(b0, b1))
  }

  private static func line(_ text: String, _ font: CTFont) -> CTLine {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
  }

  private static func measure(_ text: String, _ font: CTFont) -> CGFloat {
    CTLineGetTypographicBounds(line(text, font), nil, nil, nil)
  }

  /// `text` drawn on a strip of its own, from where `x` (given its width) puts it: how much of each pixel it covers.
  private func draw(_ text: String, at x: (CGFloat) -> CGFloat) -> [UInt8] {
    var coverage = [UInt8](repeating: 0, count: width * height)
    coverage.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return }
      context.setShouldAntialias(true)
      context.setShouldSmoothFonts(false)
      context.setFillColor(gray: 1, alpha: 1)
      let line = Self.line(text, font)
      let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
      // Centred on the height of the capitals and digits, which is what the strip shows.
      let baseline = ((CGFloat(height) - CTFontGetCapHeight(font)) / 2).rounded()
      context.textPosition = CGPoint(x: x(textWidth).rounded(), y: baseline)
      CTLineDraw(line, context)
    }
    return coverage
  }
}
