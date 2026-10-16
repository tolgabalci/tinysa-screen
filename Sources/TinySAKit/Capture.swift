import Foundation

/// The reply to `capture` (the screen raw: RGB565, two bytes a pixel, high byte first, row by row) and to
/// `capture rle` on firmware v1.4-252 and later, the screen packed (the NanoVNA-D RLE8 format): an 8-byte header ("BM",
/// the width and height, 8 bits a pixel, compression 1), the palette's size in bytes and its RGB565 colours, then each
/// row as palette indices packed with PackBits, after its packed size. Older firmware, or a screen of more than 256
/// colours, answers `capture rle` with the raw screen.
public enum Capture {
  /// The packed format's header for a screen of this size.
  public static func header(for size: ScreenSize) -> [UInt8] {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    return le16(0x4D42) + le16(size.width) + le16(size.height) + [8, 1]
  }

  /// How many bytes a capture reply has, once its start says: nil until then. Packed when it starts with the header,
  /// else raw.
  public static func length<Bytes: RandomAccessCollection>(of data: Bytes, size: ScreenSize) -> Int?
  where Bytes.Element == UInt8, Bytes.Index == Int {
    let header = header(for: size)
    guard data.count >= header.count else { return nil }
    let s = data.startIndex
    guard data[s..<(s + header.count)].elementsEqual(header) else { return size.width * size.height * 2 }
    func le16(_ at: Int) -> Int { Int(data[s + at]) | Int(data[s + at + 1]) << 8 }
    var at = header.count + 2
    guard data.count >= at else { return nil }
    at += le16(at - 2)
    for _ in 0..<size.height {
      guard data.count >= at + 2 else { return nil }
      at += 2 + le16(at)
    }
    return at
  }

  public enum Failure: Error, Equatable {
    case tooShort
    case badRow(Int)
    case badIndex(Int)
  }

  /// Puts a capture reply (packed or raw) on the framebuffer.
  public static func apply(_ data: Data, to screen: Framebuffer) throws {
    let bytes = [UInt8](data)
    let size = screen.size
    let header = header(for: size)
    guard bytes.count >= header.count, bytes[0..<header.count].elementsEqual(header) else {
      guard bytes.count >= size.width * size.height * 2 else { throw Failure.tooShort }
      screen.bulk(x: 0, y: 0, width: size.width, height: size.height, pixels: bytes)
      return
    }
    func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    var at = header.count + 2
    guard bytes.count >= at else { throw Failure.tooShort }
    let colors = le16(at - 2) / 2
    guard bytes.count >= at + colors * 2 else { throw Failure.tooShort }
    let palette = (0..<colors).map { Framebuffer.rgba(Framebuffer.color(bytes[at + 2 * $0], bytes[at + 2 * $0 + 1])) }
    at += colors * 2
    for y in 0..<size.height {
      guard bytes.count >= at + 2 else { throw Failure.tooShort }
      let packed = le16(at)
      guard bytes.count >= at + 2 + packed else { throw Failure.tooShort }
      guard let row = unpackBits(bytes[(at + 2)..<(at + 2 + packed)], count: size.width) else {
        throw Failure.badRow(y)
      }
      if let index = row.first(where: { Int($0) >= colors }) { throw Failure.badIndex(Int(index)) }
      screen.indexedRow(y, indices: row, palette: palette)
      at += 2 + packed
    }
  }

  /// PackBits: a count byte n, then n + 1 bytes as they are (n < 128), or the next byte 257 − n times (n > 128); 128
  /// is nothing. Nil unless it comes to exactly `count` bytes.
  public static func unpackBits(_ packed: ArraySlice<UInt8>, count: Int) -> [UInt8]? {
    var out = [UInt8]()
    out.reserveCapacity(count)
    var i = packed.startIndex
    while i < packed.endIndex {
      let n = Int(packed[i])
      if n < 128 {
        let end = i + 2 + n
        guard end <= packed.endIndex else { return nil }
        out.append(contentsOf: packed[(i + 1)..<end])
        i = end
      } else if n > 128 {
        guard i + 1 < packed.endIndex else { return nil }
        out.append(contentsOf: repeatElement(packed[i + 1], count: 257 - n))
        i += 2
      } else {
        i += 1
      }
      if out.count > count { return nil }
    }
    return out.count == count ? out : nil
  }
}
