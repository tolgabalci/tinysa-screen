import Foundation

/// How a GIF is made from a clip.
public struct GIFOptions: Equatable, Sendable {
  /// GIF pixels to each pixel of the screen, across and down: 1, or 2 for twice the size with the pixels kept sharp.
  public var scale: Int
  /// A strip under the screen with the date, the time, or both, at its bottom right.
  public var showsDate: Bool
  public var showsTime: Bool
  /// The formats of the date and time: the Mac's own, by default.
  public var locale: Locale
  public var timeZone: TimeZone
  /// Words kept in the file, not shown: where the picture came from, say.
  public var comment: String?

  public init(
    scale: Int = 1, showsDate: Bool = true, showsTime: Bool = true, locale: Locale = .current,
    timeZone: TimeZone = .current, comment: String? = nil
  ) {
    self.scale = scale
    self.showsDate = showsDate
    self.showsTime = showsTime
    self.locale = locale
    self.timeZone = timeZone
    self.comment = comment
  }
}

/// A GIF made, and what it holds.
public struct GIFResult: Sendable {
  public let data: Data
  public let width: Int
  public let height: Int
  /// Images in the file: a frame of the screen, or the time ticking on.
  public let images: Int
  public let duration: TimeInterval
}

/// Animated GIFs of the screen, small without losing a pixel. Every frame is the screen exactly, in its own colours (a
/// tinySA's screen has fewer than the 256 a GIF holds), so nothing is dithered or blurred. Only the rows that changed
/// since the frame before are stored, across the whole width, every pixel in its own colour; a screen that keeps still
/// costs nothing. Images as wide as the GIF, without transparent pixels, are what a site that shrinks a GIF image by
/// image still shows rightly: groups.io fits each image to its width, so an image narrower than the GIF came out larger
/// than the rest and out of place, and the old screen showing through its transparent pixels piled up frame after
/// frame. (The smallest rectangle around each change, unchanged pixels transparent, made files a fifth to a half
/// smaller.) The time in the strip ticks every second, so it runs on while the screen keeps still. Delays are the real
/// time between frames, so the GIF plays as it happened.
public enum GIF {
  /// Frames closer than this are shown together: browsers slow down frames shorter than 20 ms.
  static let together: TimeInterval = 0.03

  public static func make(_ clip: Clip, options: GIFOptions = GIFOptions(), progress: (Double) -> Void = { _ in })
    -> GIFResult?
  {
    guard let last = clip.frames.last else { return nil }
    let frames = clip.frames.filter { $0.width == last.width && $0.height == last.height }
    let (width, height) = (last.width, last.height)
    let scale = min(max(options.scale, 1), 4)
    var caption = CaptionStrip(
      width: width * scale, scale: scale, showsDate: options.showsDate, showsTime: options.showsTime,
      locale: options.locale, timeZone: options.timeZone)
    let screenHeight = height * scale
    let canvasWidth = width * scale
    let canvasHeight = screenHeight + (caption?.height ?? 0)
    let events = timeline(frames, start: clip.start, end: clip.end, ticks: options.showsTime && caption != nil)
    guard !events.isEmpty else { return nil }

    var palette = Palette()
    var images: [Image] = []
    var lzw = LZWEncoder()
    var shown: [UInt32]?
    var shownFrame = -1
    var shownCaption: [UInt8]?
    for (k, event) in events.enumerated() {
      progress(Double(k) / Double(events.count))
      var pixels = shown
      if event.frame != shownFrame, let snapshot = frames[event.frame].snapshot() { pixels = snapshot.pixels }
      guard let pixels else { continue }
      var levels: [UInt8]?
      if let text = caption?.text(at: event.clock) { levels = caption?.levels(for: text) }

      // The rows that changed: the screen's, at the GIF's size, and the strip's under it.
      var rows: Range<Int>?
      if let shown {
        rows = changedRows(shown, pixels, width: width, height: height)
          .map { $0.lowerBound * scale..<$0.upperBound * scale }
      } else {
        rows = 0..<screenHeight
      }
      if let levels {
        let stripHeight = levels.count / canvasWidth
        let changed =
          shownCaption.map { changedRows($0, levels, width: canvasWidth, height: stripHeight) } ?? 0..<stripHeight
        if let changed { rows = rows.spanning(changed.lowerBound + screenHeight..<changed.upperBound + screenHeight) }
      }
      guard let rows else { continue }  // nothing changed: the frame before stays up longer

      // Each pixel's own colour, across the whole width.
      var own = [UInt8](repeating: 0, count: canvasWidth * rows.count)
      var i = 0
      for y in rows {
        if y < screenHeight {
          let row = (y / scale) * width
          for x in 0..<canvasWidth {
            own[i] = palette.index(pixels[row + x / scale])
            i += 1
          }
        } else if let levels {
          let row = (y - screenHeight) * canvasWidth
          for x in 0..<canvasWidth {
            own[i] = palette.index(CaptionStrip.colors[Int(levels[row + x])])
            i += 1
          }
        }
      }
      images.append(encode(own, rows: rows, time: event.time, lzw: &lzw))
      shown = pixels
      shownFrame = event.frame
      shownCaption = levels
    }
    progress(1)
    let duration = clip.end.timeIntervalSince(clip.start)
    let data = file(
      images, palette: palette.colors, width: canvasWidth, height: canvasHeight, duration: duration,
      comment: options.comment)
    return GIFResult(data: data, width: canvasWidth, height: canvasHeight, images: images.count, duration: duration)
  }

  /// A frame as the GIF shows it, the strip under it saying `moment`: for a preview.
  public static func still(_ screen: Snapshot, at moment: Date, options: GIFOptions) -> Snapshot {
    let scale = min(max(options.scale, 1), 4)
    let width = screen.width * scale
    var strip = CaptionStrip(
      width: width, scale: scale, showsDate: options.showsDate, showsTime: options.showsTime,
      locale: options.locale, timeZone: options.timeZone)
    let screenHeight = screen.height * scale
    var pixels = [UInt32](repeating: 0, count: width * (screenHeight + (strip?.height ?? 0)))
    for y in 0..<screenHeight {
      let row = (y / scale) * screen.width
      for x in 0..<width { pixels[y * width + x] = screen.pixels[row + x / scale] }
    }
    if let text = strip?.text(at: moment), let levels = strip?.levels(for: text) {
      for (i, level) in levels.enumerated() { pixels[screenHeight * width + i] = CaptionStrip.colors[Int(level)] }
    }
    return Snapshot(width: width, height: pixels.count / width, pixels: pixels)
  }

  // MARK: The moments the GIF shows

  /// A moment of the GIF: seconds from its start, the frame on the screen, and the clock to show.
  struct Event: Equatable {
    var time: TimeInterval
    var frame: Int
    var clock: Date
  }

  /// The moments to show: the screen at the start, each frame after it, and each second the clock ticks over; moments
  /// closer than `together` are shown as one.
  static func timeline(_ frames: [RecordedFrame], start: Date, end: Date, ticks: Bool) -> [Event] {
    guard !frames.isEmpty else { return [] }
    let first = frames.lastIndex { $0.time <= start } ?? 0
    var moments = [Event(time: 0, frame: first, clock: start)]
    for i in (first + 1)..<frames.count where frames[i].time > start && frames[i].time <= end {
      moments.append(Event(time: frames[i].time.timeIntervalSince(start), frame: i, clock: frames[i].time))
    }
    if ticks {
      var second = start.timeIntervalSinceReferenceDate.rounded(.down) + 1
      while second <= end.timeIntervalSinceReferenceDate {
        let clock = Date(timeIntervalSinceReferenceDate: second)
        moments.append(Event(time: clock.timeIntervalSince(start), frame: -1, clock: clock))
        second += 1
      }
    }
    moments.sort { $0.time < $1.time }
    var events: [Event] = []
    for moment in moments {
      if var previous = events.last, moment.time - previous.time < together {
        if moment.frame >= 0 { previous.frame = moment.frame }
        previous.clock = max(previous.clock, moment.clock)
        events[events.count - 1] = previous
      } else {
        events.append(Event(time: moment.time, frame: moment.frame >= 0 ? moment.frame : events.last?.frame ?? first, clock: moment.clock))
      }
    }
    return events
  }

  // MARK: What changed

  /// The rows from the first where the pixels differ to the last, or nil when none do.
  static func changedRows<Pixel: Equatable>(_ old: [Pixel], _ new: [Pixel], width: Int, height: Int) -> Range<Int>? {
    var first = -1
    var last = -1
    old.withUnsafeBufferPointer { old in
      new.withUnsafeBufferPointer { new in
        for y in 0..<height {
          let row = y * width
          guard memcmp(old.baseAddress! + row, new.baseAddress! + row, width * MemoryLayout<Pixel>.stride) != 0 else {
            continue
          }
          if first < 0 { first = y }
          last = y
        }
      }
    }
    return first < 0 ? nil : first..<(last + 1)
  }

  // MARK: Encoding

  /// An image of the GIF: the rows it covers, across the whole width, and its compressed pixels.
  struct Image {
    var rows: Range<Int>
    var codeSize: Int
    var data: [UInt8]
    var time: TimeInterval
  }

  /// The image of the rows that changed, its codes just wide enough for the colours in it.
  static func encode(_ own: [UInt8], rows: Range<Int>, time: TimeInterval, lzw: inout LZWEncoder) -> Image {
    let codeSize = LZWEncoder.codeSize(for: Int(own.max() ?? 0) + 1)
    return Image(rows: rows, codeSize: codeSize, data: lzw.encode(own, codeSize: codeSize), time: time)
  }

  /// The whole file: header, colours, the loop, a comment, the images with their delays.
  static func file(
    _ images: [Image], palette: [UInt32], width: Int, height: Int, duration: TimeInterval, comment: String?
  ) -> Data {
    var out: [UInt8] = []
    func le16(_ value: Int) { out += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    func blocks(_ bytes: [UInt8]) {
      var at = 0
      while at < bytes.count {
        let n = min(255, bytes.count - at)
        out.append(UInt8(n))
        out += bytes[at..<(at + n)]
        at += n
      }
      out.append(0)
    }
    let largest = max(palette.count - 1, 1)
    var tableBits = 1
    while 1 << tableBits <= largest { tableBits += 1 }

    out += Array("GIF89a".utf8)
    le16(width)
    le16(height)
    out += [0x80 | 0x70 | UInt8(tableBits - 1), 0, 0]  // a global colour table, 8 bits a colour
    for i in 0..<(1 << tableBits) {
      let (r, g, b) = i < palette.count ? Snapshot.rgb(palette[i]) : (0, 0, 0)
      out += [r, g, b]
    }
    out += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]  // loop forever
    if let comment, !comment.isEmpty {
      out += [0x21, 0xFE]
      blocks(Array(comment.utf8))
    }
    func centiseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 100).rounded()) }
    for (k, image) in images.enumerated() {
      let next = k + 1 < images.count ? images[k + 1].time : duration
      let delay = min(max(centiseconds(next) - centiseconds(image.time), 2), 65535)
      // Graphic control: kept under the next image (disposal 1), the delay, no transparent colour.
      out += [0x21, 0xF9, 0x04, 0x04]
      le16(delay)
      out += [0, 0]
      out.append(0x2C)
      le16(0)
      le16(image.rows.lowerBound)
      le16(width)
      le16(image.rows.count)
      out.append(0)
      out.append(UInt8(image.codeSize))
      blocks(image.data)
    }
    out.append(0x3B)
    return Data(out)
  }
}

/// The GIF's colours, in the order they first appear. A GIF holds 256; a colour beyond those (which a tinySA's screen
/// never has) takes the nearest one.
struct Palette {
  private(set) var colors: [UInt32] = []
  private var indices: [UInt32: UInt8] = [:]
  private var lastColor: UInt32?
  private var lastIndex: UInt8 = 0

  mutating func index(_ color: UInt32) -> UInt8 {
    if color == lastColor { return lastIndex }
    let index: UInt8
    if let known = indices[color] {
      index = known
    } else if colors.count < 256 {
      index = UInt8(colors.count)
      colors.append(color)
      indices[color] = index
    } else {
      index = nearest(color)
      indices[color] = index
    }
    lastColor = color
    lastIndex = index
    return index
  }

  private func nearest(_ color: UInt32) -> UInt8 {
    let (r, g, b) = Snapshot.rgb(color)
    var best = 0
    var bestDistance = Int.max
    for (i, other) in colors.enumerated() {
      let (r2, g2, b2) = Snapshot.rgb(other)
      let distance = (Int(r) - Int(r2)) * (Int(r) - Int(r2)) + (Int(g) - Int(g2)) * (Int(g) - Int(g2))
        + (Int(b) - Int(b2)) * (Int(b) - Int(b2))
      if distance < bestDistance {
        best = i
        bestDistance = distance
      }
    }
    return UInt8(best)
  }
}

extension Optional where Wrapped == Range<Int> {
  /// The rows from the first of both to the last of both.
  func spanning(_ other: Range<Int>) -> Range<Int> {
    guard let self else { return other }
    return min(self.lowerBound, other.lowerBound)..<max(self.upperBound, other.upperBound)
  }
}
