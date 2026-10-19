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

  static func clip(_ moments: [(TimeInterval, Snapshot)], end: TimeInterval) -> Clip {
    let frames = moments.map { RecordedFrame($0.1, at: start.addingTimeInterval($0.0)) }
    return Clip(frames: frames, from: start, to: start.addingTimeInterval(end))!
  }

  /// Each image of the GIF shows the screen of its moment exactly, kept under the next, for the real time between
  /// them; only the rows that changed are stored, across the whole width, with no transparent colour.
  func testFramesComeOutExactly() throws {
    let screens = [Self.screen(blockAt: 10), Self.screen(blockAt: 50), Self.screen(blockAt: 300)]
    let clip = Self.clip([(0, screens[0]), (0.77, screens[1]), (1.54, screens[2])], end: 2.31)
    let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(showsDate: false, showsTime: false)))
    let decoded = try DecodedGIF(gif.data)
    XCTAssertEqual(decoded.width, 480)
    XCTAssertEqual(decoded.height, 320)
    XCTAssertEqual(decoded.loops, 0, "loops forever")
    XCTAssertEqual(decoded.images.count, 3)
    XCTAssertEqual(decoded.images.map(\.delay), [77, 77, 77])
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
    let clip = Self.clip([(0, screen)], end: 3.0)
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

  /// The date and time read as the Mac shows them.
  func testCaptionText() {
    var strip = CaptionStrip(
      width: 480, scale: 1, showsDate: true, showsTime: true, locale: Locale(identifier: "en_US"),
      timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    let moment = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 04:00:00 UTC
    XCTAssertEqual(strip?.text(at: moment).replacingOccurrences(of: "\u{202F}", with: " "), "Oct 2, 2026   9:00:00 PM")
    strip = CaptionStrip(
      width: 480, scale: 1, showsDate: false, showsTime: true, locale: Locale(identifier: "en_GB"),
      timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertEqual(strip?.text(at: moment), "04:00:00")
    XCTAssertNil(
      CaptionStrip(width: 480, scale: 1, showsDate: false, showsTime: false, locale: .current, timeZone: .current))
  }

  /// Moments closer than 30 ms are shown together, the later frame and clock winning.
  func testTimelineMergesCloseMoments() {
    let screens = (0..<3).map { Self.screen(blockAt: 10 + 30 * $0) }
    let frames = [
      RecordedFrame(screens[0], at: Self.start.addingTimeInterval(-5)),
      RecordedFrame(screens[1], at: Self.start.addingTimeInterval(0.59)),
      RecordedFrame(screens[2], at: Self.start.addingTimeInterval(1.2)),
    ]
    let events = GIF.timeline(frames, start: Self.start, end: Self.start.addingTimeInterval(2), ticks: true)
    XCTAssertEqual(events.map(\.frame), [0, 1, 2, 2])
    XCTAssertEqual(events.map { ($0.time * 100).rounded() / 100 }, [0, 0.59, 1.2, 1.6])
    // The tick at 0.6 s went with the frame at 0.59 s, and its clock with it.
    XCTAssertEqual(events[1].clock, Self.start.addingTimeInterval(0.6))
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
