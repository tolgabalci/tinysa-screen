import Foundation

/// How a GIF is made from a clip.
public struct GIFOptions: Hashable, Sendable {
  /// GIF pixels to each pixel of the screen, across and down: 1, or 2 for twice the size with the pixels kept sharp.
  public var scale: Int
  /// A strip under the screen with the date, the time, or both, at its bottom right, and with `showsElapsed`, how far
  /// into the recording each moment is, of how long it is ("0:10 / 2:30"), at its bottom left, in a bar that fills as
  /// the GIF plays with `showsProgress`. No strip without any.
  public var showsDate: Bool
  public var showsTime: Bool
  public var showsElapsed: Bool
  public var showsProgress: Bool
  /// Played in a loop, or once.
  public var loops: Bool
  /// Seconds the last frame is held at the end; longer than a second, "END OF RECORDING" shows in red in the strip.
  public var pauseAtEnd: TimeInterval
  /// Times faster than it happened it plays, 1 to 20: a minute at 10 plays in 6 seconds.
  public var speed: Double
  /// Frames a second of its playing at most, 1 to 10, for a smaller file when it plays faster; nil, every frame of the
  /// recording (up to 50 a second of playing, as many as players show).
  public var framesPerSecond: Int?
  /// The peak hold drawn over the screen as the window draws it, for a clip recorded with it on; nil, none.
  public var peaks: PeakLook?
  /// The formats of the date and time: the Mac's own, by default.
  public var locale: Locale
  public var timeZone: TimeZone
  /// Words kept in the file, not shown: where the picture came from, say.
  public var comment: String?

  public init(
    scale: Int = 1, showsDate: Bool = true, showsTime: Bool = true, showsElapsed: Bool = false,
    showsProgress: Bool = false, loops: Bool = true,
    pauseAtEnd: TimeInterval = 0, speed: Double = 1, framesPerSecond: Int? = nil, peaks: PeakLook? = nil,
    locale: Locale = .current, timeZone: TimeZone = .current, comment: String? = nil
  ) {
    self.scale = scale
    self.showsDate = showsDate
    self.showsTime = showsTime
    self.showsElapsed = showsElapsed
    self.showsProgress = showsProgress
    self.loops = loops
    self.pauseAtEnd = pauseAtEnd
    self.speed = speed
    self.framesPerSecond = framesPerSecond
    self.peaks = peaks
    self.locale = locale
    self.timeZone = timeZone
    self.comment = comment
  }

  /// The strip has something to say.
  public var hasCaption: Bool { showsDate || showsTime || showsElapsed || showsProgress }

  /// Seconds of playing between two of its moments, and the recording's seconds between them: for every frame, a tenth
  /// of a second of the recording, or a fiftieth of a second of playing when it plays faster than five times; with
  /// fewer frames a second, a frame's share of a second.
  public var step: TimeInterval {
    if let framesPerSecond { return 1 / Double(min(max(framesPerSecond, 1), 10)) }
    return max(0.1 / playingSpeed, Self.shortest)
  }
  public var stepOfRecording: TimeInterval { step * playingSpeed }
  /// The shortest an image of the GIF is: players take two hundredths of a second as they are, one as ten.
  static let shortest: TimeInterval = 0.02
  public var playingSpeed: Double { min(max(speed, 1), 20) }

  /// How long a clip plays as a GIF, the pause at the end included.
  public func playingTime(of duration: TimeInterval) -> TimeInterval {
    duration / playingSpeed + max(pauseAtEnd, 0)
  }
}

/// What the strip under a GIF's screen says at a moment: the date and time then; how far into the GIF that is, of how
/// long it is, in whole seconds of the recording, ticking with the clock; whether no picture came in the second before
/// it (or the recording's time between two moments, when that's longer); and the end.
public struct Caption: Hashable, Sendable {
  public var clock: Date
  public var elapsed: Int
  public var total: Int
  public var stale: Bool
  public var ended: Bool

  public init(clock: Date, elapsed: Int = 0, total: Int = 0, stale: Bool = false, ended: Bool = false) {
    self.clock = clock
    self.elapsed = elapsed
    self.total = total
    self.stale = stale
    self.ended = ended
  }
}

extension Clip {
  /// The strip's words at `moment` of a GIF of this clip, or of its part from `from` to `to` (the editor's): seconds
  /// counted on the clock's seconds, so the count and the clock tick together; stale when no picture came in the
  /// `window` up to it.
  public func caption(
    at moment: Date, from: Date? = nil, to: Date? = nil, window: TimeInterval = 1, ended: Bool = false
  ) -> Caption {
    func second(_ date: Date) -> Int { Int(date.timeIntervalSinceReferenceDate.rounded(.down)) }
    let start = from ?? self.start
    let total = second(to ?? end) - second(start)
    var low = 0
    var high = arrivals.count
    while low < high {
      let middle = (low + high) / 2
      if arrivals[middle] <= moment { low = middle + 1 } else { high = middle }
    }
    let stale = low == 0 || moment.timeIntervalSince(arrivals[low - 1]) >= window
    return Caption(
      clock: moment, elapsed: min(second(moment) - second(start), total), total: total, stale: stale, ended: ended)
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
/// smaller.)
///
/// It plays in real time, or as many times faster as asked: its moments are a tenth of a second of playing apart (or
/// further, with fewer frames a second), on whole multiples of that on the clock, each showing the screen as it was
/// then. So the clock and the count of seconds in the strip tick on the second, together, and no image is shorter
/// than half a tenth of a second (the first and last; the rest a tenth or more), which players differ on; a frame shows
/// up to a moment late. Seconds no picture came in tick on in pink.
public enum GIF {
  /// The GIF of a clip; nil without a frame, or once `stop` says to stop (a size no longer wanted).
  public static func make(
    _ clip: Clip, options: GIFOptions = GIFOptions(), progress: (Double) -> Void = { _ in },
    stop: () -> Bool = { false }
  ) -> GIFResult? {
    guard let last = clip.frames.last else { return nil }
    let frames = clip.frames.filter { $0.width == last.width && $0.height == last.height }
    let (width, height) = (last.width, last.height)
    let scale = min(max(options.scale, 1), 4)
    var caption = CaptionStrip(width: width * scale, scale: scale, options: options)
    let screenHeight = height * scale
    let canvasWidth = width * scale
    let canvasHeight = screenHeight + (caption?.height ?? 0)
    let events = timeline(clip, frames: frames, options: options)
    guard !events.isEmpty else { return nil }

    var palette = Palette()
    var images: [Image] = []
    var lzw = LZWEncoder()
    var shown: [UInt32]?
    var shownFrame = -1
    var shownCaption: [UInt32]?
    // The peak hold over the screen, drawn again each time it changed: its pixels, and the drawing shown last.
    let peakPicture = options.peaks.flatMap { look in
      clip.hasPeaks
        ? PeakPicture(
          width: canvasWidth, height: screenHeight, scale: scale, look: look, locale: options.locale,
          timeZone: options.timeZone) : nil
    }
    var peaks: (state: PeakHold.State?, pixels: [UInt32]?, drawing: Int) = (nil, nil, 0)
    var shownPeaks: (pixels: [UInt32]?, drawing: Int) = (nil, 0)
    for (k, event) in events.enumerated() {
      if k % 16 == 0, stop() { return nil }
      progress(Double(k) / Double(events.count))
      var pixels = shown
      if event.frame != shownFrame, let snapshot = frames[event.frame].snapshot() { pixels = snapshot.pixels }
      guard let pixels else { continue }
      var strip: [UInt32]?
      if let words = caption?.words(event.caption) { strip = caption?.pixels(for: words) }
      if let peakPicture {
        let state = clip.peaks(at: event.caption.clock)
        if state != peaks.state { peaks = (state, state.map { peakPicture.pixels(for: $0) }, peaks.drawing + 1) }
      }

      // The rows that changed: the screen's, at the GIF's size, and the strip's under it.
      var rows: Range<Int>?
      if let shown {
        rows = changedRows(shown, pixels, width: width, height: height)
          .map { $0.lowerBound * scale..<$0.upperBound * scale }
      } else {
        rows = 0..<screenHeight
      }
      if let strip {
        let stripHeight = strip.count / canvasWidth
        let changed =
          shownCaption.map { changedRows($0, strip, width: canvasWidth, height: stripHeight) } ?? 0..<stripHeight
        if let changed { rows = rows.spanning(changed.lowerBound + screenHeight..<changed.upperBound + screenHeight) }
      }
      if peaks.drawing != shownPeaks.drawing {
        let none = [UInt32](repeating: 0, count: canvasWidth * screenHeight)
        if let changed = changedRows(
          shownPeaks.pixels ?? none, peaks.pixels ?? none, width: canvasWidth, height: screenHeight)
        {
          rows = rows.spanning(changed)
        }
      }
      guard let rows else { continue }  // nothing changed: the frame before stays up longer

      // Each pixel's own colour, across the whole width.
      var own = [UInt8](repeating: 0, count: canvasWidth * rows.count)
      var i = 0
      for y in rows {
        if y < screenHeight, let over = peaks.pixels {
          let row = (y / scale) * width
          let top = y * canvasWidth
          for x in 0..<canvasWidth {
            let hold = over[top + x]
            own[i] = palette.index(hold != 0 ? hold : pixels[row + x / scale])
            i += 1
          }
        } else if y < screenHeight {
          let row = (y / scale) * width
          for x in 0..<canvasWidth {
            own[i] = palette.index(pixels[row + x / scale])
            i += 1
          }
        } else if let strip {
          let row = (y - screenHeight) * canvasWidth
          for x in 0..<canvasWidth {
            own[i] = palette.index(strip[row + x])
            i += 1
          }
        }
      }
      images.append(encode(own, rows: rows, time: event.time, lzw: &lzw))
      shown = pixels
      shownFrame = event.frame
      shownCaption = strip
      shownPeaks = (peaks.pixels, peaks.drawing)
    }
    progress(1)
    let duration = options.playingTime(of: clip.duration)
    let data = file(
      images, palette: palette.colors, width: canvasWidth, height: canvasHeight, duration: duration,
      loops: options.loops, comment: options.comment)
    return GIFResult(data: data, width: canvasWidth, height: canvasHeight, images: images.count, duration: duration)
  }

  /// A frame as the GIF shows it, the strip under it saying the date and time of `moment`.
  public static func still(_ screen: Snapshot, at moment: Date, options: GIFOptions) -> Snapshot {
    still(screen, caption: Caption(clock: moment), options: options)
  }

  /// A frame as the GIF shows it, the strip under it saying `caption`, the peak hold over it as `options.peaks` say:
  /// for a preview, or a screenshot.
  public static func still(
    _ screen: Snapshot, caption: Caption, options: GIFOptions, peaks: PeakHold.State? = nil
  ) -> Snapshot {
    let scale = min(max(options.scale, 1), 4)
    let width = screen.width * scale
    var strip = CaptionStrip(width: width, scale: scale, options: options)
    let screenHeight = screen.height * scale
    var pixels = [UInt32](repeating: 0, count: width * (screenHeight + (strip?.height ?? 0)))
    for y in 0..<screenHeight {
      let row = (y / scale) * screen.width
      for x in 0..<width { pixels[y * width + x] = screen.pixels[row + x / scale] }
    }
    if let look = options.peaks, let peaks {
      let hold = PeakPicture(
        width: width, height: screenHeight, scale: scale, look: look, locale: options.locale,
        timeZone: options.timeZone)
      for (i, pixel) in hold.pixels(for: peaks).enumerated() where pixel != 0 { pixels[i] = pixel }
    }
    if let words = strip?.words(caption), let colors = strip?.pixels(for: words) {
      for (i, color) in colors.enumerated() { pixels[screenHeight * width + i] = color }
    }
    return Snapshot(width: width, height: pixels.count / width, pixels: pixels)
  }

  // MARK: The moments the GIF shows

  /// A moment of the GIF: seconds of its playing from its start, the frame on the screen, and what the strip says.
  struct Event: Equatable {
    var time: TimeInterval
    var frame: Int
    var caption: Caption
  }

  /// The moments to show: the start, then one each `step` of playing (`stepOfRecording` of the recording) on whole
  /// multiples of that on the clock, none closer than half a step (and the shortest image) to the start or the end;
  /// each the frame on the screen then. With a pause at the end, the end once more, held for it.
  static func timeline(_ clip: Clip, frames: [RecordedFrame], options: GIFOptions) -> [Event] {
    guard !frames.isEmpty else { return [] }
    let speed = options.playingSpeed
    let real = options.stepOfRecording
    let window = max(1, real)
    let start = clip.start.timeIntervalSinceReferenceDate
    let end = clip.end.timeIntervalSinceReferenceDate
    var instants = [clip.start]
    var n = (start / real).rounded(.down) + 1
    let edge = max(real / 2, GIFOptions.shortest * speed)
    if n * real - start < edge { n += 1 }
    while n * real <= end - edge {
      instants.append(Date(timeIntervalSinceReferenceDate: n * real))
      n += 1
    }
    var events: [Event] = []
    var frame = 0
    func onScreen(_ moment: Date) -> Int {
      while frame + 1 < frames.count, frames[frame + 1].time <= moment { frame += 1 }
      return frame
    }
    for instant in instants {
      events.append(
        Event(
          time: instant.timeIntervalSince(clip.start) / speed, frame: onScreen(instant),
          caption: clip.caption(at: instant, window: window)))
    }
    if options.pauseAtEnd > 0 {
      events.append(
        Event(
          time: clip.duration / speed, frame: onScreen(clip.end),
          caption: clip.caption(at: clip.end, window: window, ended: options.pauseAtEnd > 1)))
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

  /// The whole file: header, colours, the loop (or none, to play once), a comment, the images with their delays.
  static func file(
    _ images: [Image], palette: [UInt32], width: Int, height: Int, duration: TimeInterval, loops: Bool = true,
    comment: String?
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
    if loops { out += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00] }  // forever
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
