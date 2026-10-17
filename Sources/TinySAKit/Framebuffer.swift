import CoreGraphics
import Foundation

/// The size of a tinySA's screen in pixels: 480 × 320 on the tinySA Ultra models, 320 × 240 on the original tinySA.
public struct ScreenSize: Equatable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  public static let ultra = ScreenSize(width: 480, height: 320)
  public static let basic = ScreenSize(width: 320, height: 240)

  /// The screen of the model a `version` reply names: "tinySA4_v1.4-252…" is an Ultra, "tinySA_v1.4…" the original.
  public static func of(version: String) -> ScreenSize {
    version.lowercased().hasPrefix("tinysa4") ? .ultra : .basic
  }

  /// A NanoVNA's screen, by its USB product name: 480 × 320 on the -H4, 320 × 240 on the others.
  public static func of(nanoVNA product: String) -> ScreenSize {
    product.lowercased().hasSuffix("h4") ? .ultra : .basic
  }
}

/// A copy of the analyzer's screen on the Mac. The tinySA draws in RGB565, two bytes a pixel sent high byte first;
/// regions of it (`fill`, `bulk`, a whole capture) are written here as they arrive, and `image()` makes a picture of
/// the whole.
public final class Framebuffer {
  public let size: ScreenSize
  /// RGBA, 8 bits a channel, row by row from the top left.
  private var pixels: [UInt32]

  public init(size: ScreenSize) {
    self.size = size
    pixels = Array(repeating: Self.opaqueBlack, count: size.width * size.height)
  }

  static let opaqueBlack: UInt32 = Framebuffer.rgba(0)

  /// Every RGB565 colour as RGBA in memory order (R, G, B, A bytes), indexed by the colour as it is sent: high byte
  /// first, so the index is `high << 8 | low`.
  private static let table: [UInt32] = (0..<65536).map { rgba(UInt16($0)) }

  static func rgba(_ rgb565: UInt16) -> UInt32 {
    let r = UInt32(rgb565 >> 11 & 0x1F) * 255 / 31
    let g = UInt32(rgb565 >> 5 & 0x3F) * 255 / 63
    let b = UInt32(rgb565 & 0x1F) * 255 / 31
    return (r | g << 8 | b << 16 | 0xFF00_0000).littleEndian
  }

  /// The RGB565 colour of two bytes as the tinySA sends them (high byte first).
  @inline(__always) static func color(_ high: UInt8, _ low: UInt8) -> UInt16 { UInt16(high) << 8 | UInt16(low) }

  /// Whether a region lies wholly on the screen.
  public func contains(x: Int, y: Int, width: Int, height: Int) -> Bool {
    x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= size.width && y + height <= size.height
  }

  /// A region in one colour (the stream's `fill`).
  public func fill(x: Int, y: Int, width: Int, height: Int, color: UInt16) {
    guard contains(x: x, y: y, width: width, height: height) else { return }
    let value = Self.table[Int(color)]
    for row in y..<(y + height) {
      let start = row * size.width + x
      pixels.replaceSubrange(start..<(start + width), with: repeatElement(value, count: width))
    }
  }

  /// A region from RGB565 pixels, two bytes each, high byte first, row by row (the stream's `bulk`, a raw capture).
  public func bulk<Bytes: RandomAccessCollection>(x: Int, y: Int, width: Int, height: Int, pixels source: Bytes)
  where Bytes.Element == UInt8, Bytes.Index == Int {
    guard contains(x: x, y: y, width: width, height: height), source.count >= width * height * 2 else { return }
    var i = source.startIndex
    pixels.withUnsafeMutableBufferPointer { out in
      for row in y..<(y + height) {
        var o = row * size.width + x
        for _ in 0..<width {
          out[o] = Self.table[Int(Self.color(source[i], source[i + 1]))]
          o += 1
          i += 2
        }
      }
    }
  }

  /// A row of palette indices (`capture rle`), starting at the left edge.
  func indexedRow(_ y: Int, indices: [UInt8], palette: [UInt32]) {
    guard y >= 0, y < size.height, indices.count == size.width else { return }
    pixels.withUnsafeMutableBufferPointer { out in
      var o = y * size.width
      for index in indices {
        out[o] = Int(index) < palette.count ? palette[Int(index)] : Self.opaqueBlack
        o += 1
      }
    }
  }

  /// The colour of one pixel as RGBA, for tests.
  public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let value = UInt32(littleEndian: pixels[y * size.width + x])
    return (UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF))
  }

  /// The screen as it is now.
  public func snapshot() -> Snapshot { Snapshot(width: size.width, height: size.height, pixels: pixels) }

  /// An image of the screen as it is now.
  public func image() -> CGImage? { snapshot().image() }
}
