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
/// tinySA's screen has fewer than the 256 a GIF holds), so nothing is dithered or blurred. Only what changed since the
/// frame before is stored, the smallest rectangle around it, and in it a pixel that didn't change is either transparent
/// or its own colour, whichever compresses better; a screen that keeps still costs nothing. The time in the strip
/// ticks every second, so it runs on while the screen keeps still. Delays are the real time between frames, so the GIF
/// plays as it happened.
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

      var box: Box?
      if let shown {
        box = changedBox(shown, pixels, width: width, height: height)?.scaled(scale)
      } else {
        box = Box(x0: 0, y0: 0, x1: canvasWidth, y1: screenHeight)
      }
      if let levels {
        let changed = shownCaption.map { changedBox($0, levels, width: canvasWidth, height: levels.count / canvasWidth) }
          ?? Box(x0: 0, y0: 0, x1: canvasWidth, y1: levels.count / canvasWidth)
        if let changed { box = box.union(changed.offset(y: screenHeight)) }
      }
      guard let box else { continue }  // nothing changed: the frame before stays up longer

      // Each pixel's own colour, and whether it changed.
      var own = [UInt8](repeating: 0, count: box.width * box.height)
      var changed = [Bool](repeating: true, count: own.count)
      var i = 0
      for y in box.y0..<box.y1 {
        if y < screenHeight {
          let row = (y / scale) * width
          for x in box.x0..<box.x1 {
            let at = row + x / scale
            own[i] = palette.index(pixels[at])
            if let shown { changed[i] = shown[at] != pixels[at] }
            i += 1
          }
        } else if let levels {
          let row = (y - screenHeight) * canvasWidth
          for x in box.x0..<box.x1 {
            own[i] = palette.index(CaptionStrip.colors[Int(levels[row + x])])
            if let shownCaption { changed[i] = shownCaption[row + x] != levels[row + x] }
            i += 1
          }
        }
      }
      images.append(encode(own, changed: changed, box: box, time: event.time, first: shown == nil, lzw: &lzw))
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

  struct Box: Equatable {
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    func scaled(_ scale: Int) -> Box { Box(x0: x0 * scale, y0: y0 * scale, x1: x1 * scale, y1: y1 * scale) }
    func offset(y: Int) -> Box { Box(x0: x0, y0: y0 + y, x1: x1, y1: y1 + y) }
  }

  /// The smallest rectangle around the pixels that differ, or nil when none do.
  static func changedBox<Pixel: Equatable>(_ old: [Pixel], _ new: [Pixel], width: Int, height: Int) -> Box? {
    var minY = -1
    var maxY = -1
    var minX = width
    var maxX = -1
    old.withUnsafeBufferPointer { old in
      new.withUnsafeBufferPointer { new in
        for y in 0..<height {
          let row = y * width
          guard memcmp(old.baseAddress! + row, new.baseAddress! + row, width * MemoryLayout<Pixel>.stride) != 0 else {
            continue
          }
          if minY < 0 { minY = y }
          maxY = y
          var x = 0
          while x < minX, old[row + x] == new[row + x] { x += 1 }
          minX = min(minX, x)
          x = width - 1
          while x > maxX, old[row + x] == new[row + x] { x -= 1 }
          maxX = max(maxX, x)
        }
      }
    }
    return minY < 0 ? nil : Box(x0: minX, y0: minY, x1: maxX + 1, y1: maxY + 1)
  }

  // MARK: Encoding

  /// An image of the GIF: where it goes, its transparent index, and its compressed pixels.
  struct Image {
    var box: Box
    var transparent: Int?
    var codeSize: Int
    var data: [UInt8]
    var time: TimeInterval
  }

  /// Ways to store a changed rectangle: every pixel its own colour; unchanged pixels transparent; or each unchanged
  /// pixel whichever of the two continues the run. The smallest of those tried is kept.
  enum Way: CaseIterable { case opaque, transparent, either }
  /// The ways tried (opaque and either do best together, measured on real frames); tests try each alone.
  static var ways: [Way] = [.opaque, .either]

  /// The image of a changed rectangle, stored the way that comes out smallest.
  static func encode(_ own: [UInt8], changed: [Bool], box: Box, time: TimeInterval, first: Bool, lzw: inout LZWEncoder)
    -> Image
  {
    var largest = 0
    var used = [Bool](repeating: false, count: 256)
    for i in own.indices {
      largest = max(largest, Int(own[i]))
      if changed[i] { used[Int(own[i])] = true }
    }
    var best: Image?
    func keep(_ image: Image) {
      if best == nil || image.data.count < best!.data.count { best = image }
    }
    let opaqueSize = LZWEncoder.codeSize(for: largest + 1)
    // The transparent index: any index no changed pixel needs (a pixel that didn't change may have it: it shows the
    // same colour either way).
    let transparent = first ? nil : used.firstIndex(of: false)
    for way in ways {
      switch way {
      case .opaque:
        keep(Image(box: box, transparent: nil, codeSize: opaqueSize, data: lzw.encode(own, codeSize: opaqueSize), time: time))
      case .transparent, .either:
        guard let transparent else { continue }
        var symbols = own
        for i in own.indices where !changed[i] { symbols[i] = UInt8(transparent) }
        let size = LZWEncoder.codeSize(for: max(largest, transparent) + 1)
        let data = lzw.encode(symbols, alternates: way == .either ? own : nil, codeSize: size)
        keep(Image(box: box, transparent: transparent, codeSize: size, data: data, time: time))
      }
    }
    if let best { return best }
    return Image(box: box, transparent: nil, codeSize: opaqueSize, data: lzw.encode(own, codeSize: opaqueSize), time: time)
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
    let largest = max(palette.count - 1, images.compactMap(\.transparent).max() ?? 0, 1)
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
      // Graphic control: kept under the next image (disposal 1), the delay, the transparent index.
      out += [0x21, 0xF9, 0x04, 0x04 | (image.transparent == nil ? 0 : 1)]
      le16(delay)
      out += [UInt8(image.transparent ?? 0), 0]
      out.append(0x2C)
      le16(image.box.x0)
      le16(image.box.y0)
      le16(image.box.width)
      le16(image.box.height)
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

extension Optional where Wrapped == GIF.Box {
  func union(_ other: GIF.Box) -> GIF.Box {
    guard let self else { return other }
    return GIF.Box(
      x0: min(self.x0, other.x0), y0: min(self.y0, other.y0), x1: max(self.x1, other.x1), y1: max(self.y1, other.y1))
  }
}
