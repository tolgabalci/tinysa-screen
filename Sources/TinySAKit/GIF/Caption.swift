import CoreGraphics
import CoreText
import Foundation

/// The strip under the screen in a GIF: at its bottom right the date and time of each moment, in the Mac's own date and
/// time formats, the time to the second so it ticks as the GIF plays; at its bottom left how far into the recording the
/// moment is, of how long it is ("0:10 / 2:30"). White on black like the analyzer's own text, smoothed in a few levels;
/// pink through a second no picture came in, and "End of recording" in red in the middle through the pause at the end.
struct CaptionStrip {
  /// Shades from the background (0) to the text (levels − 1), of each ink.
  static let levels = 8

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

  /// The colour of each level of each ink, from the background to the text: ink × levels + level.
  static let colors: [UInt32] = Ink.allCases.flatMap { ink in
    (0..<levels).map { level in
      let (r, g, b) = Snapshot.rgb(ink.color)
      func shade(_ value: UInt8) -> UInt8 { UInt8((Int(value) * level + (levels - 1) / 2) / (levels - 1)) }
      return Snapshot.pixel(r: shade(r), g: shade(g), b: shade(b))
    }
  }

  /// What the strip says, where, and in which ink.
  struct Words: Hashable {
    var left = ""
    var right = ""
    var center = ""
    var stale = false
  }

  let width: Int
  let height: Int
  private let scale: Int
  private let font: CTFont
  private let date: DateFormatter?
  private let time: DateFormatter?
  private let showsElapsed: Bool
  private var rendered: [Words: [UInt8]] = [:]

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
  }

  /// The date and time at a moment, as the strip's right says it.
  func text(at moment: Date) -> String {
    [date?.string(from: moment), time?.string(from: moment)].compactMap { $0 }.joined(separator: "   ")
  }

  /// What the strip says for a caption.
  func words(_ caption: Caption) -> Words {
    Words(
      left: showsElapsed ? "\(Self.duration(caption.elapsed)) / \(Self.duration(caption.total))" : "",
      right: text(at: caption.clock), center: caption.ended ? "End of recording" : "", stale: caption.stale)
  }

  /// "0:10", "2:30", "−0:20" (a preview before the GIF's start).
  static func duration(_ seconds: Int) -> String {
    let whole = abs(seconds)
    return (seconds < 0 ? "\u{2212}" : "") + String(format: "%d:%02d", whole / 60, whole % 60)
  }

  /// The strip saying `words`: a colour (ink × levels + level) for each pixel, row by row from the top left.
  mutating func levels(for words: Words) -> [UInt8] {
    if let known = rendered[words] { return known }
    let ink = words.stale ? Ink.pink : .white
    let margin = CGFloat(6 * scale)
    var coverage = [UInt8](repeating: 0, count: width * height)
    var inks = [UInt8](repeating: UInt8(ink.rawValue), count: width * height)
    let parts: [(String, Ink, (CGFloat) -> CGFloat)] = [
      (words.left, ink, { _ in margin }),
      (words.right, ink, { [width] textWidth in CGFloat(width) - margin - textWidth }),
      (words.center, .red, { [width] textWidth in (CGFloat(width) - textWidth) / 2 }),
    ]
    for (text, partInk, x) in parts where !text.isEmpty {
      let part = draw(text, at: x)
      for i in part.indices where part[i] > coverage[i] {
        coverage[i] = part[i]
        inks[i] = UInt8(partInk.rawValue)
      }
    }
    let top = Self.levels - 1
    let levels = coverage.indices.map {
      coverage[$0] == 0 ? 0 : inks[$0] * UInt8(Self.levels) + UInt8((Int(coverage[$0]) * top + 127) / 255)
    }
    rendered[words] = levels
    return levels
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
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text,
          attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
          ]))
      let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
      // Centred on the height of the capitals and digits, which is what the strip shows.
      let baseline = ((CGFloat(height) - CTFontGetCapHeight(font)) / 2).rounded()
      context.textPosition = CGPoint(x: x(textWidth).rounded(), y: baseline)
      CTLineDraw(line, context)
    }
    return coverage
  }
}
