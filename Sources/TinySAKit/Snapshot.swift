import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture of a screen as RGBA pixels: 8 bits a channel, in memory order red, green, blue, alpha, row by row from the
/// top left.
public struct Snapshot: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public var pixels: [UInt32]

  public init(width: Int, height: Int, pixels: [UInt32]) {
    precondition(pixels.count == width * height)
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  /// The pixels of an image (a feeding program's picture), opaque.
  public init?(_ image: CGImage) {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt32](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    let opaque = UInt32(0xFF00_0000).littleEndian
    for i in pixels.indices { pixels[i] |= opaque }
    self.init(width: width, height: height, pixels: pixels)
  }

  /// The red, green and blue of a pixel.
  public func rgb(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) { Self.rgb(pixels[y * width + x]) }

  static func rgb(_ pixel: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
    let value = UInt32(littleEndian: pixel)
    return (UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF))
  }

  static func pixel(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
    (UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000).littleEndian
  }

  public func image() -> CGImage? {
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// The picture as a PNG file's bytes.
  public func png() -> Data? {
    guard let image = image() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}
