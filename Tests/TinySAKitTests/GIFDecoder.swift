import Foundation

@testable import TinySAKit

/// A plain GIF decoder for the tests, written from the GIF89a specification apart from the encoder: every image of a
/// file, composited as a viewer shows it (each kept under the next), and the parts of the file the tests check.
struct DecodedGIF {
  struct Image {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var delay: Int
    var transparent: Int?
    var disposal: Int
    var codeSize: Int
    /// The canvas after this image, as RGB triples packed in a UInt32 (r | g << 8 | b << 16).
    var canvas: [UInt32]
  }

  var width = 0
  var height = 0
  var palette: [UInt32] = []
  var loops: Int?
  var comment: String?
  var images: [Image] = []

  enum Failure: Error { case bad(String) }

  init(_ data: Data) throws {
    let b = [UInt8](data)
    var at = 0
    func byte() throws -> Int {
      guard at < b.count else { throw Failure.bad("ends early") }
      defer { at += 1 }
      return Int(b[at])
    }
    func le16() throws -> Int { try byte() | (try byte()) << 8 }
    func subBlocks() throws -> [UInt8] {
      var out: [UInt8] = []
      while true {
        let n = try byte()
        if n == 0 { return out }
        guard at + n <= b.count else { throw Failure.bad("block ends early") }
        out += b[at..<(at + n)]
        at += n
      }
    }
    func table(_ count: Int) throws -> [UInt32] {
      try (0..<count).map { _ in UInt32(try byte()) | UInt32(try byte()) << 8 | UInt32(try byte()) << 16 }
    }
    guard b.count >= 13, String(decoding: b[0..<6], as: UTF8.self) == "GIF89a" else { throw Failure.bad("header") }
    at = 6
    width = try le16()
    height = try le16()
    let packed = try byte()
    _ = try byte()
    _ = try byte()
    if packed & 0x80 != 0 { palette = try table(1 << ((packed & 7) + 1)) }
    var canvas = [UInt32](repeating: 0, count: width * height)
    var delay = 0
    var transparent: Int?
    var disposal = 0
    while true {
      let kind = try byte()
      switch kind {
      case 0x21:
        let label = try byte()
        if label == 0xF9 {
          let body = try subBlocks()
          guard body.count == 4 else { throw Failure.bad("graphic control") }
          disposal = Int(body[0]) >> 2 & 7
          transparent = body[0] & 1 != 0 ? Int(body[3]) : nil
          delay = Int(body[1]) | Int(body[2]) << 8
        } else if label == 0xFF {
          let body = try subBlocks()
          if body.count >= 14, String(decoding: body[0..<11], as: UTF8.self) == "NETSCAPE2.0" {
            loops = Int(body[12]) | Int(body[13]) << 8
          }
        } else if label == 0xFE {
          comment = String(decoding: try subBlocks(), as: UTF8.self)
        } else {
          _ = try subBlocks()
        }
      case 0x2C:
        let x = try le16()
        let y = try le16()
        let w = try le16()
        let h = try le16()
        let flags = try byte()
        guard flags & 0x40 == 0 else { throw Failure.bad("interlaced") }
        let colors = flags & 0x80 != 0 ? try table(1 << ((flags & 7) + 1)) : palette
        let codeSize = try byte()
        let indices = try Self.lzwDecode(subBlocks(), codeSize: codeSize, count: w * h)
        guard x + w <= width, y + h <= height else { throw Failure.bad("image off the canvas") }
        for row in 0..<h {
          for column in 0..<w {
            let index = Int(indices[row * w + column])
            if index == transparent { continue }
            guard index < colors.count else { throw Failure.bad("index \(index) past the colour table") }
            canvas[(y + row) * width + x + column] = colors[index]
          }
        }
        images.append(
          Image(
            x: x, y: y, width: w, height: h, delay: delay, transparent: transparent, disposal: disposal,
            codeSize: codeSize, canvas: canvas))
        transparent = nil
        delay = 0
        disposal = 0
      case 0x3B:
        return
      default:
        throw Failure.bad("block \(kind)")
      }
    }
  }

  /// GIF's LZW, decoded the way the specification describes it.
  static func lzwDecode(_ data: [UInt8], codeSize: Int, count: Int) throws -> [UInt8] {
    guard (2...8).contains(codeSize) else { throw Failure.bad("code size \(codeSize)") }
    let clear = 1 << codeSize
    let end = clear + 1
    var width = codeSize + 1
    var table: [[UInt8]] = []
    func reset() {
      table = (0..<clear).map { [UInt8($0)] } + [[], []]
      width = codeSize + 1
    }
    reset()
    var out: [UInt8] = []
    var bitAt = 0
    var previous: [UInt8]?
    func read() -> Int? {
      guard bitAt + width <= data.count * 8 else { return nil }
      var code = 0
      for i in 0..<width where data[(bitAt + i) / 8] >> ((bitAt + i) % 8) & 1 != 0 { code |= 1 << i }
      bitAt += width
      return code
    }
    var sawEnd = false
    while let code = read() {
      if code == clear {
        reset()
        previous = nil
        continue
      }
      if code == end {
        sawEnd = true
        break
      }
      let entry: [UInt8]
      if code < table.count, !table[code].isEmpty || code < clear {
        entry = table[code]
      } else if code == table.count, let previous {
        entry = previous + [previous[0]]
      } else {
        throw Failure.bad("code \(code) not in the table (\(table.count))")
      }
      out += entry
      if let previous, table.count < 4096 {
        table.append(previous + [entry[0]])
        if table.count == 1 << width, width < 12 { width += 1 }
      }
      previous = entry
    }
    guard sawEnd else { throw Failure.bad("no end code") }
    guard out.count == count else { throw Failure.bad("\(out.count) pixels, not \(count)") }
    return out
  }
}
