import ImageIO
import XCTest

@testable import TinySAKit

final class GIFTests: XCTestCase {
  static let black = Snapshot.pixel(r: 0, g: 0, b: 0)
  static let white = Snapshot.pixel(r: 255, g: 255, b: 255)
  static let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
  static let start = Date(timeIntervalSinceReferenceDate: 800_000_000.4)

  /// A screen with a grid line and a yellow block at `x`.
  static func screen(blockAt x: Int, width: Int = 480, height: Int = 320) -> Snapshot {
    var screen = Snapshot(width: width, height: height, pixels: Array(repeating: black, count: width * height))
    for column in 0..<width { screen.pixels[100 * width + column] = white }
    for row in 200..<210 {
      for column in x..<(x + 20) { screen.pixels[row * width + column] = yellow }
    }
    return screen
  }

  /// A clip of `moments`, pictures coming every half second besides (a live analyzer, its screen still or not).
  static func clip(_ moments: [(TimeInterval, Snapshot)], end: TimeInterval, live: Bool = true) -> Clip {
    let frames = moments.map { RecordedFrame($0.1, at: start.addingTimeInterval($0.0)) }
    let arrivals = live ? stride(from: 0, through: end, by: 0.5).map { start.addingTimeInterval($0) } : nil
    return Clip(frames: frames, from: start, to: start.addingTimeInterval(end), arrivals: arrivals)!
  }

  /// A GIF no longer wanted (the editor's size, its handles moved on) stops being made.
  func testStopsWhenTold() {
    let clip = Self.clip([(0, Self.screen(blockAt: 10)), (1, Self.screen(blockAt: 50))], end: 2)
    XCTAssertNil(GIF.make(clip, stop: { true }))
    XCTAssertNotNil(GIF.make(clip, stop: { false }))
  }

  /// Each image of the GIF shows the screen of its moment exactly, kept under the next, from the first tenth of a
  /// second on the clock after it came; only the rows that changed are stored, across the whole width, with no
  /// transparent colour.
  func testFramesComeOutExactly() throws {
    let screens = [Self.screen(blockAt: 10), Self.screen(blockAt: 50), Self.screen(blockAt: 300)]
    let clip = Self.clip([(0, screens[0]), (0.77, screens[1]), (1.54, screens[2])], end: 2.31)
    let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(showsDate: false, showsTime: false)))
    let decoded = try DecodedGIF(gif.data)
    XCTAssertEqual(decoded.width, 480)
    XCTAssertEqual(decoded.height, 320)
    XCTAssertEqual(decoded.loops, 0, "loops forever")
    XCTAssertEqual(decoded.images.count, 3)
    // The clip starts .4 s past a second: frames that came at .17 and .94 show from .2 and 1.0, 0.8 and 1.6 s in.
    XCTAssertEqual(decoded.images.map(\.delay), [80, 80, 71])
    for (image, screen) in zip(decoded.images, screens) {
      XCTAssertEqual(image.canvas, screen.pixels.map(Self.rgb), "screen at image \(image)")
      XCTAssertEqual(image.disposal, 1)
      XCTAssertNil(image.transparent)
      XCTAssertEqual([image.x, image.width], [0, 480])
    }
    // The second image covers the rows the block left and moved to.
    let second = decoded.images[1]
    XCTAssertEqual([second.y, second.height], [200, 10])
    XCTAssertLessThan(gif.data.count, 3000)
  }

  /// A site that shrinks a GIF image by image, fitting each to the width it wants (groups.io does, as ImageMagick does
  /// resizing to a width without -coalesce), still shows the screen: every image is as wide as the GIF, so all are
  /// scaled alike, and none has a transparent pixel for the screen before to show through. An image narrower than the
  /// GIF would come out larger than the rest and out of place.
  func testShrinkingImageByImageShowsTheScreen() throws {
    let screens = [Self.screen(blockAt: 10), Self.screen(blockAt: 50), Self.screen(blockAt: 300)]
    let clip = Self.clip([(0, screens[0]), (0.77, screens[1]), (1.54, screens[2])], end: 2.31)
    let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(scale: 2, showsDate: false, showsTime: false)))
    let decoded = try DecodedGIF(gif.data)
    XCTAssertEqual(decoded.images.count, 3)
    // Each image fitted to 480 across, nearest pixel, at the place its own scale puts it; off the canvas is cut.
    var canvas = [UInt32](repeating: 0, count: 480 * 320)
    for (image, screen) in zip(decoded.images, screens) {
      let scale = 480.0 / Double(image.width)
      let left = Int((Double(image.x) * scale).rounded())
      let top = Int((Double(image.y) * scale).rounded())
      for y in 0..<Int((Double(image.height) * scale).rounded()) where top + y < 320 {
        for x in 0..<480 where left + x < 480 {
          let column = min(Int(Double(x) / scale), image.width - 1)
          let row = min(Int(Double(y) / scale), image.height - 1)
          if let pixel = image.pixels[row * image.width + column] { canvas[(top + y) * 480 + left + x] = pixel }
        }
      }
      XCTAssertEqual(canvas, screen.pixels.map(Self.rgb), "screen at image \(image.y)")
    }
  }

  /// At twice the size every pixel is a 2 × 2 square.
  func testDoubleSize() throws {
    let screens = [Self.screen(blockAt: 10), Self.screen(blockAt: 40)]
    let clip = Self.clip([(0, screens[0]), (1, screens[1])], end: 2)
    let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(scale: 2, showsDate: false, showsTime: false)))
    let decoded = try DecodedGIF(gif.data)
    XCTAssertEqual([decoded.width, decoded.height], [960, 640])
    let last = try XCTUnwrap(decoded.images.last).canvas
    for (x, y) in [(0, 0), (45, 205), (100, 100), (479, 319), (29, 200), (30, 200), (59, 209), (60, 209)] {
      let expected = Self.rgb(screens[1].pixels[y * 480 + x])
      for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        XCTAssertEqual(last[(2 * y + dy) * 960 + 2 * x + dx], expected, "pixel \(x), \(y)")
      }
    }
  }

  /// With the time on, a strip under the screen says it, and a still screen still gets an image every second as the
  /// time ticks over; the screen above stays exact.
  func testTimeTicksUnderTheScreen() throws {
    let screen = Self.screen(blockAt: 10)
    let clip = Self.clip([(0, screen)], end: 3.0)  // pictures every half second, the same each time
    var options = GIFOptions(showsDate: true, showsTime: true)
    options.locale = Locale(identifier: "en_US")
    options.timeZone = TimeZone(identifier: "UTC")!
    let gif = try XCTUnwrap(GIF.make(clip, options: options))
    let decoded = try DecodedGIF(gif.data)
    XCTAssertEqual([decoded.width, decoded.height], [480, 336])
    // Start at .4 s past a second: ticks at .6, 1.6 and 2.6 s in.
    XCTAssertEqual(decoded.images.count, 4)
    XCTAssertEqual(decoded.images.map(\.delay), [60, 100, 100, 40])
    for image in decoded.images {
      XCTAssertEqual(Array(image.canvas[0..<(480 * 320)]), screen.pixels.map(Self.rgb))
      // Text at the bottom right of the strip, nothing at its left.
      let strip = image.canvas[(480 * 320)...]
      let lit = strip.indices.filter { strip[$0] != 0 }.map { ($0 - 480 * 320) % 480 }
      XCTAssertGreaterThan(lit.count, 100)
      XCTAssertGreaterThan(lit.min() ?? 0, 240)
      XCTAssertLessThan(lit.max() ?? 480, 480 - 4)
    }
    // After the first, each image is only the rows of the strip that changed, across the whole width.
    for image in decoded.images.dropFirst() {
      XCTAssertGreaterThanOrEqual(image.y, 320)
      XCTAssertLessThan(image.height, 16)
      XCTAssertEqual([image.x, image.width], [0, 480])
    }
  }

  /// The date and time read as the Mac shows them; the count of seconds as minutes and seconds.
  func testCaptionText() {
    func strip(_ options: GIFOptions) -> CaptionStrip? { CaptionStrip(width: 480, scale: 1, options: options) }
    let moment = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 04:00:00 UTC
    let us = strip(
      GIFOptions(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Los_Angeles")!))
    XCTAssertEqual(us?.text(at: moment).replacingOccurrences(of: "\u{202F}", with: " "), "Oct 2, 2026   9:00:00 PM")
    let uk = strip(
      GIFOptions(showsDate: false, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
    XCTAssertEqual(uk?.text(at: moment), "04:00:00")
    let count = strip(GIFOptions(showsDate: false, showsTime: false, showsElapsed: true))
    let words = count?.words(Caption(clock: moment, elapsed: 70, total: 150, ended: true))
    XCTAssertEqual(words?.left, "1:10 / 2:30")
    XCTAssertEqual(words?.right, "")
    XCTAssertEqual(words?.center, "End of recording")
    XCTAssertEqual(CaptionStrip.duration(-20), "\u{2212}0:20")
    XCTAssertNil(strip(GIFOptions(showsDate: false, showsTime: false)))
  }

  /// Moments a tenth of a second of playing apart, on tenths of the clock: each the frame on the screen then, and the
  /// clock's seconds on a moment.
  func testTimelineIsOnTenthsOfTheClock() {
    let screens = (0..<3).map { Self.screen(blockAt: 10 + 30 * $0) }
    let frames = [
      RecordedFrame(screens[0], at: Self.start.addingTimeInterval(-5)),
      RecordedFrame(screens[1], at: Self.start.addingTimeInterval(0.59)),
      RecordedFrame(screens[2], at: Self.start.addingTimeInterval(1.2)),
    ]
    let clip = Clip(frames: frames, from: Self.start, to: Self.start.addingTimeInterval(2))!
    let events = GIF.timeline(clip, frames: clip.frames, options: GIFOptions())
    let times = events.map { ($0.time * 100).rounded() / 100 }
    // From .4 s past a second: .5 s (a tenth on), then each tenth to the last half a tenth or more before the end.
    XCTAssertEqual(times.first, 0)
    XCTAssertEqual(times[1], 0.1)
    XCTAssertEqual(times.last, 1.9)
    XCTAssertEqual(events.count, 20)
    // The frame that came .99 s on the clock shows from 1.0; the one at 1.6, from 1.6.
    XCTAssertEqual(events.first { $0.frame == 2 - 1 }.map { ($0.time * 100).rounded() / 100 }, 0.6)
    XCTAssertEqual(events.first { $0.frame == 2 }.map { ($0.time * 100).rounded() / 100 }, 1.2)
    XCTAssertEqual(events[6].caption.clock, Self.start.addingTimeInterval(0.6))
  }

  /// The count of seconds ticks with the clock's seconds, and says how long the GIF is; seconds no picture came in are
  /// stale; the end is the end.
  func testCaptionsCountWithTheClock() {
    let frames = [RecordedFrame(Self.screen(blockAt: 10), at: Self.start)]
    let arrivals = [0, 0.5, 1, 4.2].map { Self.start.addingTimeInterval($0) }
    let clip = Clip(frames: frames, from: Self.start, to: Self.start.addingTimeInterval(9.8), arrivals: arrivals)!
    func caption(_ seconds: TimeInterval) -> Caption { clip.caption(at: Self.start.addingTimeInterval(seconds)) }
    // Start at .4 s past a second, end at 10.2: ten whole seconds of the clock.
    XCTAssertEqual(caption(0).total, 10)
    XCTAssertEqual([0, 0.5, 0.6, 1.59, 1.6, 9.8].map { caption($0).elapsed }, [0, 0, 1, 1, 2, 10])
    XCTAssertEqual(caption(-3).elapsed, -3, "before the GIF, in the editor")
    // Pictures came at 0, 0.5, 1 and 4.2 s: none in the second up to 2.5 s, nor 4.1; one at 4.2.
    XCTAssertEqual([0.2, 1.9, 2.0, 2.5, 4.1, 4.2, 5.1, 5.2].map { caption($0).stale },
      [false, false, true, true, true, false, false, true])
    XCTAssertTrue(clip.caption(at: clip.end, ended: true).ended)
  }

  /// Faster, it plays in a tenth of the time with up to ten frames a second; fewer frames a second make fewer images.
  func testPlaysFasterWithFewerFrames() throws {
    let moments = (0..<40).map { (Double($0) * 0.5, Self.screen(blockAt: 10 + 10 * $0)) }
    let clip = Self.clip(moments, end: 20)
    func decoded(_ options: GIFOptions) throws -> DecodedGIF {
      try DecodedGIF(try XCTUnwrap(GIF.make(clip, options: options)).data)
    }
    let real = try decoded(GIFOptions(showsDate: false, showsTime: false))
    XCTAssertEqual(real.images.reduce(0) { $0 + $1.delay }, 2000)
    XCTAssertEqual(real.images.count, 40)
    let fast = try decoded(GIFOptions(showsDate: false, showsTime: false, speed: 10))
    XCTAssertEqual(fast.images.reduce(0) { $0 + $1.delay }, 200, "20 s at 10 times plays in 2")
    XCTAssertEqual(fast.images.count, 20, "a tenth of a second of playing each: one frame of each two")
    XCTAssertTrue(fast.images.allSatisfy { $0.delay >= 5 }, "none shorter than half a tenth of a second")
    let sparse = try decoded(GIFOptions(showsDate: false, showsTime: false, speed: 10, framesPerSecond: 2))
    XCTAssertEqual(sparse.images.reduce(0) { $0 + $1.delay }, 200)
    XCTAssertEqual(sparse.images.count, 4, "two frames a second of playing")
    // Each image is the screen as it was at its moment, on whole 5 s of the clock: the second at 5.0 s, 4.6 s in.
    XCTAssertEqual(sparse.images[1].canvas, Self.screen(blockAt: 10 + 10 * 9).pixels.map(Self.rgb))
  }

  /// A pause at the end holds the last frame, with "End of recording" in red in the middle of the strip when it's
  /// longer than a second; without looping the GIF plays once.
  func testPausesAtTheEndAndPlaysOnce() throws {
    let clip = Self.clip([(0, Self.screen(blockAt: 10)), (1, Self.screen(blockAt: 60))], end: 2)
    var options = GIFOptions(showsDate: false, showsTime: true, pauseAtEnd: 5)
    options.timeZone = TimeZone(identifier: "UTC")!
    let paused = try DecodedGIF(try XCTUnwrap(GIF.make(clip, options: options)).data)
    let last = try XCTUnwrap(paused.images.last)
    XCTAssertEqual(last.delay, 500)
    XCTAssertEqual(paused.images.reduce(0) { $0 + $1.delay }, 700)
    XCTAssertEqual(paused.loops, 0, "loops forever")
    func red(_ canvas: [UInt32]) -> Int {
      canvas[(480 * 320)...].filter { pixel in
        let (r, g) = (pixel & 0xFF, pixel >> 8 & 0xFF)
        return r > 150 && g < 100
      }.count
    }
    XCTAssertGreaterThan(red(last.canvas), 50)
    XCTAssertEqual(red(paused.images[paused.images.count - 2].canvas), 0, "red only at the end")
    options.pauseAtEnd = 1
    options.loops = false
    let held = try DecodedGIF(try XCTUnwrap(GIF.make(clip, options: options)).data)
    XCTAssertEqual(held.images.reduce(0) { $0 + $1.delay }, 300)
    XCTAssertEqual(held.images.last?.delay, 140, "the last image (from 1.6 s, the clock's last second) and the pause")
    XCTAssertEqual(red(try XCTUnwrap(held.images.last).canvas), 0, "a second's pause: no words")
    XCTAssertNil(held.loops, "plays once")
  }

  /// Through a second no picture came in, the strip's words are pink; white again once one comes.
  func testSecondsWithoutAPictureArePink() throws {
    let screen = Self.screen(blockAt: 10)
    let frames = [RecordedFrame(screen, at: Self.start)]
    let arrivals = [0, 3.5].map { Self.start.addingTimeInterval($0) }
    let clip = Clip(frames: frames, from: Self.start, to: Self.start.addingTimeInterval(5), arrivals: arrivals)!
    var options = GIFOptions(showsDate: false, showsTime: true)
    options.timeZone = TimeZone(identifier: "UTC")!
    let gif = try DecodedGIF(try XCTUnwrap(GIF.make(clip, options: options)).data)
    var time = 0
    var pink: [(Int, Bool)] = []
    for image in gif.images {
      let strip = image.canvas[(480 * 320)...]
      let brightest = try XCTUnwrap(strip.max { ($0 >> 8 & 0xFF) < ($1 >> 8 & 0xFF) })
      // White text is as green as red; pink less.
      pink.append((time, (brightest >> 8 & 0xFF) < 200))
      time += image.delay
    }
    // White to 1 s in, pink from then to 3.5 s, when a picture came, white to 4.5 s, pink after.
    for (time, isPink) in pink {
      let expected = (100..<350).contains(time) || time >= 450
      XCTAssertEqual(isPink, expected, "at \(time) cs")
    }
    XCTAssertTrue(pink.contains { $0.1 })
  }

  /// Apple's own decoder (the one Safari and Preview use) shows the same frames, for the same time.
  func testImageIODecodesTheSameFrames() throws {
    var screens: [Snapshot] = []
    var moments: [(TimeInterval, Snapshot)] = []
    for k in 0..<12 {
      var screen = Self.screen(blockAt: 10 + 37 * k)
      // A noisy band, like a waterfall, that moves down a row each time.
      for row in 250..<300 {
        for column in 0..<480 {
          let value = UInt8(truncatingIfNeeded: (row - k) &* 31 &+ column &* 17 &+ (column * row) % 7)
          screen.pixels[row * 480 + column] = Snapshot.pixel(r: value & 0xE0, g: 0, b: 255 - value & 0xE0)
        }
      }
      screens.append(screen)
      moments.append((0.77 * Double(k), screen))
    }
    let clip = Self.clip(moments, end: 0.77 * 12)
    let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(showsDate: false, showsTime: false)))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(gif.data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 12)
    var total = 0.0
    for k in 0..<12 {
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, k, nil))
      let decoded = try XCTUnwrap(Snapshot(image))
      XCTAssertEqual(decoded.pixels.map(Self.rgb), screens[k].pixels.map(Self.rgb), "frame \(k)")
      let properties = CGImageSourceCopyPropertiesAtIndex(source, k, nil) as? [CFString: Any]
      let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      total += gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
    }
    XCTAssertEqual(total, 0.77 * 12, accuracy: 0.011)
  }

  /// Captures decoded from the analyzer and the live screen drawn over them make a GIF whose last image is that screen.
  func testRecordedStreamMakesAGIF() throws {
    let screen = Framebuffer(size: .ultra)
    try Capture.apply(Fixture.data("capture-rle.bin"), to: screen)
    var frames = [RecordedFrame(screen.snapshot(), at: Self.start)]
    var stream = ScreenStream(size: .ultra)
    var regions = 0
    stream.feed(try Fixture.data("stream.bin.deflate")) { event in
      screen.apply(event)
      regions += 1
      if regions % 100 == 0 { frames.append(RecordedFrame(screen.snapshot(), at: Self.start.addingTimeInterval(Double(regions) / 130))) }
    }
    let end = Self.start.addingTimeInterval(Double(regions) / 130 + 0.5)
    frames.append(RecordedFrame(screen.snapshot(), at: end.addingTimeInterval(-0.4)))
    let clip = try XCTUnwrap(Clip(frames: frames, from: Self.start, to: end))
    let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(showsDate: false, showsTime: false)))
    let decoded = try DecodedGIF(gif.data)
    XCTAssertEqual(decoded.images.last?.canvas, screen.snapshot().pixels.map(Self.rgb))
  }

  static func rgb(_ pixel: UInt32) -> UInt32 {
    let (r, g, b) = Snapshot.rgb(pixel)
    return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16
  }
}
