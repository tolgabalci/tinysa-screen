import CoreGraphics
import CoreText
import Foundation

/// The strip under the screen in a GIF with the date and time of each moment, at its bottom right, in the Mac's own
/// date and time formats; the time to the second, so it ticks as the GIF plays. White on black like the analyzer's own
/// text, smoothed in a few levels of grey.
struct CaptionStrip {
  /// Shades of grey from the background (0) to the text (levels − 1).
  static let levels = 8
  static let ink = Snapshot.pixel(r: 255, g: 255, b: 255)

  let width: Int
  let height: Int
  private let scale: Int
  private let font: CTFont
  private let date: DateFormatter?
  private let time: DateFormatter?
  private var rendered: [String: [UInt8]] = [:]

  /// The colour of each level, from the background to the text.
  static let colors: [UInt32] = (0..<levels).map { level in
    let (r, g, b) = Snapshot.rgb(ink)
    func shade(_ value: UInt8) -> UInt8 { UInt8((Int(value) * level + (levels - 1) / 2) / (levels - 1)) }
    return Snapshot.pixel(r: shade(r), g: shade(g), b: shade(b))
  }

  /// Nil when neither the date nor the time is wanted.
  init?(width: Int, scale: Int, showsDate: Bool, showsTime: Bool, locale: Locale, timeZone: TimeZone) {
    guard showsDate || showsTime else { return nil }
    self.width = width
    self.scale = scale
    height = 16 * scale
    func formatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.timeZone = timeZone
      formatter.dateStyle = date
      formatter.timeStyle = time
      return formatter
    }
    self.date = showsDate ? formatter(date: .medium, time: .none) : nil
    self.time = showsTime ? formatter(date: .none, time: .medium) : nil
    // The system font with digits of one width, so the time doesn't shift as it ticks.
    let base = CTFontCreateUIFontForLanguage(.system, CGFloat(11 * scale), nil)!
    let descriptor = CTFontDescriptorCreateCopyWithFeature(
      CTFontCopyFontDescriptor(base), kNumberSpacingType as CFNumber, kMonospacedNumbersSelector as CFNumber)
    font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(11 * scale), nil)
  }

  /// What the strip says at a moment.
  func text(at moment: Date) -> String {
    [date?.string(from: moment), time?.string(from: moment)].compactMap { $0 }.joined(separator: "   ")
  }

  /// The strip with `text` at its right: a level of grey for each pixel, row by row from the top left.
  mutating func levels(for text: String) -> [UInt8] {
    if let known = rendered[text] { return known }
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
      let margin = CGFloat(6 * scale)
      // Centred on the height of the capitals and digits, which is what the strip shows.
      let baseline = ((CGFloat(height) - CTFontGetCapHeight(font)) / 2).rounded()
      context.textPosition = CGPoint(x: (CGFloat(width) - margin - textWidth).rounded(), y: baseline)
      CTLineDraw(line, context)
    }
    let top = Self.levels - 1
    let levels = coverage.map { UInt8((Int($0) * top + 127) / 255) }
    rendered[text] = levels
    return levels
  }
}
