import Foundation

/// The live screen a tinySA sends after `refresh on` (its "remote desktop", as tinySA-App uses it): every region it
/// draws, as it draws it, mixed with the echoes and replies of commands. A region is a 14-byte header ("fill\r\n" or
/// "bulk\r\n", then x, y, width and height as little-endian 16-bit numbers), its pixels (one RGB565 colour for `fill`,
/// width × height of them for `bulk`, high byte first) and the prompt "ch> ".
///
/// `feed` takes the bytes as they come, in pieces of any size, and hands out each region and each run of text between
/// them. A header that doesn't fit the screen, or a region not followed by the prompt (a command's echo can land inside
/// one), is skipped: the analyzer redraws that part of its screen soon enough.
public struct ScreenStream {
  public enum Event: Equatable {
    case fill(x: Int, y: Int, width: Int, height: Int, color: UInt16)
    case bulk(x: Int, y: Int, width: Int, height: Int, pixels: ArraySlice<UInt8>)
    /// Echoes, replies and prompts between regions.
    case text(String)
  }

  public let size: ScreenSize
  /// Bytes dropped to find the next region again (a damaged one, or a stray header).
  public private(set) var skipped = 0
  private var buffer: [UInt8] = []
  private var start = 0
  /// After a damaged region: what follows up to the next region is the rest of it, dropped rather than taken for text.
  private var resynchronizing = false

  static let fill = Array("fill\r\n".utf8)
  static let bulk = Array("bulk\r\n".utf8)
  static let prompt = Array("ch> ".utf8)
  static let headerLength = 14

  public init(size: ScreenSize) {
    self.size = size
  }

  public mutating func feed<Bytes: Sequence>(_ bytes: Bytes, _ handle: (Event) -> Void) where Bytes.Element == UInt8 {
    buffer.append(contentsOf: bytes)
    while let event = next() { handle(event) }
    if start > 1 << 16 || start == buffer.count {
      buffer.removeFirst(start)
      start = 0
    }
  }

  /// The next region or text, or nil until more bytes come.
  private mutating func next() -> Event? {
    while start < buffer.count {
      guard let header = findHeader(from: start) else {
        // No region starts here yet: the text so far, keeping a tail that may be the start of a header.
        let end = buffer.count - headerPrefixTail()
        guard end > start else { return nil }
        if resynchronizing {
          skipped += end - start
          start = end
          return nil
        }
        return text(upTo: end)
      }
      if header > start {
        if resynchronizing {
          skipped += header - start
          start = header
          continue
        }
        return text(upTo: header)
      }
      guard buffer.count - start >= Self.headerLength else { return nil }
      let isFill = buffer[start] == UInt8(ascii: "f")
      let (x, y, width, height) = (int16(at: start + 6), int16(at: start + 8), int16(at: start + 10), int16(at: start + 12))
      guard x >= 0, y >= 0, width > 0, height > 0, x + width <= size.width, y + height <= size.height else {
        skip()
        continue
      }
      let end = start + Self.headerLength + (isFill ? 2 : width * height * 2)
      guard buffer.count >= end + Self.prompt.count else { return nil }
      guard buffer[end..<(end + Self.prompt.count)].elementsEqual(Self.prompt) else {
        skip()
        continue
      }
      let body = buffer[(start + Self.headerLength)..<end]
      start = end + Self.prompt.count
      resynchronizing = false
      if isFill {
        let color = Framebuffer.color(body[body.startIndex], body[body.startIndex + 1])
        return .fill(x: x, y: y, width: width, height: height, color: color)
      }
      return .bulk(x: x, y: y, width: width, height: height, pixels: body)
    }
    return nil
  }

  private func int16(at i: Int) -> Int {
    Int(Int16(bitPattern: UInt16(buffer[i]) | UInt16(buffer[i + 1]) << 8))
  }

  /// Where the next "fill\r\n" or "bulk\r\n" starts, from `from` on.
  private func findHeader(from: Int) -> Int? {
    var i = from
    let last = buffer.count - Self.fill.count
    while i <= last {
      let c = buffer[i]
      if c == UInt8(ascii: "f") || c == UInt8(ascii: "b") {
        let signature = c == UInt8(ascii: "f") ? Self.fill : Self.bulk
        if buffer[i..<(i + signature.count)].elementsEqual(signature) { return i }
      }
      i += 1
    }
    return nil
  }

  private mutating func text(upTo end: Int) -> Event {
    let piece = String(decoding: buffer[start..<end], as: UTF8.self)
    start = end
    return .text(piece)
  }

  /// Past a header that turned out not to be one (or a damaged region): on to the next.
  private mutating func skip() {
    start += 1
    skipped += 1
    resynchronizing = true
  }

  /// How many bytes at the end could be the start of a header ("fill\r\n", "bulk\r\n"), to wait for the rest.
  private func headerPrefixTail() -> Int {
    for length in stride(from: min(Self.fill.count - 1, buffer.count - start), through: 1, by: -1) {
      let tail = buffer[(buffer.count - length)...]
      if Self.fill.starts(with: tail) || Self.bulk.starts(with: tail) { return length }
    }
    return 0
  }
}

extension Framebuffer {
  /// Draws a region of the live screen (text is nothing to draw).
  public func apply(_ event: ScreenStream.Event) {
    switch event {
    case let .fill(x, y, width, height, color): fill(x: x, y: y, width: width, height: height, color: color)
    case let .bulk(x, y, width, height, pixels): bulk(x: x, y: y, width: width, height: height, pixels: pixels)
    case .text: break
    }
  }
}
