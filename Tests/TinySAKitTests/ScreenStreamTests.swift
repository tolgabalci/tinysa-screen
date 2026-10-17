import XCTest

@testable import TinySAKit

final class ScreenStreamTests: XCTestCase {
  private func events<Chunks: Sequence>(_ chunks: Chunks) -> (regions: Int, texts: [String], skipped: Int)
  where Chunks.Element: Sequence, Chunks.Element.Element == UInt8 {
    var stream = ScreenStream(size: .ultra)
    var regions = 0
    var texts: [String] = []
    for chunk in chunks {
      stream.feed(chunk) { event in
        if case let .text(text) = event { texts.append(text) } else { regions += 1 }
      }
    }
    return (regions, texts, stream.skipped)
  }

  /// The recording parses whole: every region, and the commands' echoes between them.
  func testRecordedStreamParses() throws {
    let bytes = [UInt8](try Fixture.data("stream.bin.deflate"))
    let parsed = events([bytes])
    XCTAssertEqual(parsed.regions, 1209)
    XCTAssertEqual(parsed.skipped, 0)
    let text = parsed.texts.joined()
    XCTAssertTrue(text.contains("refresh on"))
    XCTAssertTrue(text.contains("touch 240 160"))
    XCTAssertTrue(text.contains("release 240 160"))
    XCTAssertTrue(text.contains("refresh off"))
  }

  /// Pieces of any size come out the same: USB delivers the stream in pieces that cut through regions.
  func testPiecesOfAnySizeComeOutTheSame() throws {
    let bytes = [UInt8](try Fixture.data("stream.bin.deflate"))
    var generator = SystemRandomNumberGenerator()
    var pieces: [ArraySlice<UInt8>] = []
    var at = 0
    while at < bytes.count {
      let n = Int.random(in: 1...4096, using: &generator)
      pieces.append(bytes[at..<min(at + n, bytes.count)])
      at += n
    }
    let parsed = events(pieces)
    XCTAssertEqual(parsed.regions, 1209)
    XCTAssertEqual(parsed.skipped, 0)
  }

  /// A region damaged by a command's echo landing inside it is skipped, and the next one found.
  func testDamagedRegionIsSkipped() {
    let good = Self.bulk(x: 0, y: 0, width: 2, height: 1, pixels: [0xF8, 0x00, 0x07, 0xE0])
    var damaged = good
    damaged.insert(contentsOf: Array("touch 1 2\r\n".utf8), at: 16)
    let parsed = events([damaged + good])
    XCTAssertEqual(parsed.regions, 1)
    XCTAssertGreaterThan(parsed.skipped, 0)
  }

  /// A header that doesn't fit the screen isn't a region.
  func testOffScreenHeaderIsNotARegion() {
    let parsed = events([Self.bulk(x: 470, y: 0, width: 20, height: 1, pixels: Array(repeating: 0, count: 40))])
    XCTAssertEqual(parsed.regions, 0)
  }

  /// Regions draw where they say, in their colours.
  func testRegionsDraw() {
    let screen = Framebuffer(size: .ultra)
    var stream = ScreenStream(size: .ultra)
    var fill = Array("fill\r\n".utf8) + Self.le16(10, 20, 3, 2)
    fill += [0x07, 0xE0] + Array("ch> ".utf8)  // green
    let bulk = Self.bulk(x: 100, y: 5, width: 2, height: 1, pixels: [0xF8, 0x00, 0x00, 0x1F])  // red, blue
    stream.feed(fill + bulk) { screen.apply($0) }
    XCTAssertEqual(screen.pixel(x: 12, y: 21).g, 255)
    XCTAssertEqual(screen.pixel(x: 13, y: 21).g, 0, "Outside the fill")
    XCTAssertEqual(screen.pixel(x: 100, y: 5).r, 255)
    XCTAssertEqual(screen.pixel(x: 101, y: 5).b, 255)
  }

  /// The recording drawn over the capture taken before it: the regions land on the screen.
  func testRecordingDrawsOverACapture() throws {
    let screen = Framebuffer(size: .ultra)
    try Capture.apply(Fixture.data("capture-rle.bin"), to: screen)
    var stream = ScreenStream(size: .ultra)
    var drawn = 0
    stream.feed(try Fixture.data("stream.bin.deflate")) { event in
      screen.apply(event)
      if case .bulk = event { drawn += 1 }
    }
    XCTAssertEqual(drawn, 1158)
    XCTAssertNotNil(screen.image())
  }

  static func le16(_ values: Int...) -> [UInt8] {
    values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF)] }
  }

  static func bulk(x: Int, y: Int, width: Int, height: Int, pixels: [UInt8]) -> [UInt8] {
    Array("bulk\r\n".utf8) + le16(x, y, width, height) + pixels + Array("ch> ".utf8)
  }
}

extension ScreenStreamTests {
  /// The rest of a damaged region is dropped, not taken for text; the text after the next region still comes.
  func testDamagedRegionIsNotText() {
    var damaged = Self.bulk(x: 0, y: 0, width: 4, height: 1, pixels: Array(repeating: 0x41, count: 8))
    damaged.insert(contentsOf: Array("touch 1 2\r\n".utf8), at: 18)
    let good = Self.bulk(x: 0, y: 0, width: 1, height: 1, pixels: [0, 0])
    let parsed = events([damaged + good + Array("release 1 2\r\nch> ".utf8)])
    XCTAssertEqual(parsed.regions, 1)
    XCTAssertFalse(parsed.texts.joined().contains("AAAA"), "The damaged region's pixels came out as text")
    XCTAssertTrue(parsed.texts.joined().contains("release 1 2"))
  }

  /// A text ending in "ch> " comes out whole: only a tail that could start a header waits for more.
  func testPromptIsNotHeldBack() {
    let parsed = events([Array("refresh on\r\nch> ".utf8)])
    XCTAssertEqual(parsed.texts.joined(), "refresh on\r\nch> ")
  }
}

extension ScreenStreamTests {
  /// NanoVNA-D sends its live screen the same way, but ends each region with the prompt and a new line ("ch> \r\n"):
  /// the new line is text between regions, nothing is skipped.
  func testNanoVNARegionsEndWithANewLine() {
    let region = Self.bulk(x: 10, y: 20, width: 2, height: 1, pixels: [0xF8, 0x00, 0x07, 0xE0]) + Array("\r\n".utf8)
    let fill = Array("fill\r\n".utf8) + Self.le16(0, 0, 4, 4) + [0x00, 0x1F] + Array("ch> \r\n".utf8)
    let parsed = events([region + fill + region])
    XCTAssertEqual(parsed.regions, 3)
    XCTAssertEqual(parsed.skipped, 0)
    XCTAssertEqual(parsed.texts.joined(), "\r\n\r\n\r\n")
  }
}
