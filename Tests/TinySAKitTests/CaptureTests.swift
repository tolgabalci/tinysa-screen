import XCTest

@testable import TinySAKit

final class CaptureTests: XCTestCase {
  func testHeaderNamesTheScreen() {
    XCTAssertEqual(Capture.header(for: .ultra), [0x42, 0x4D, 0xE0, 0x01, 0x40, 0x01, 8, 1])
  }

  func testLengthIsKnownOnceTheRowsAreIn() throws {
    let packed = [UInt8](try Fixture.data("capture-rle.bin"))
    XCTAssertNil(Capture.length(of: packed[0..<4], size: .ultra), "Too short to tell")
    XCTAssertNil(Capture.length(of: packed[0..<(packed.count / 2)], size: .ultra), "Half the rows")
    XCTAssertEqual(Capture.length(of: packed[...], size: .ultra), packed.count)
    let raw = [UInt8](try Fixture.data("capture-raw.bin.deflate"))
    XCTAssertEqual(Capture.length(of: raw[0..<8], size: .ultra), 480 * 320 * 2, "Raw: known from the start")
  }

  /// The packed capture and the raw one, of the same screen, come out the same pixel for pixel: the palette's byte
  /// order and the rows' unpacking are right.
  func testPackedAndRawCapturesAgree() throws {
    let packed = Framebuffer(size: .ultra)
    try Capture.apply(Fixture.data("capture-rle.bin"), to: packed)
    let raw = Framebuffer(size: .ultra)
    try Capture.apply(Fixture.data("capture-raw.bin.deflate"), to: raw)
    var differing = 0
    for y in 0..<320 {
      for x in 0..<480 where packed.pixel(x: x, y: y) != raw.pixel(x: x, y: y) { differing += 1 }
    }
    XCTAssertEqual(differing, 0)
    // The panel's text is green (the hand-set values, such as "Atten: 0dB") and the grid grey: not all black.
    let colors = Set((0..<480).map { x in "\(packed.pixel(x: x, y: 100))" })
    XCTAssertGreaterThan(colors.count, 3)
  }

  func testPaletteColoursAreRGB565HighByteFirst() throws {
    let size = ScreenSize(width: 4, height: 1)
    var bytes = Capture.header(for: size)
    bytes += [4, 0]  // the palette: two colours, four bytes
    bytes += [0xF8, 0x00, 0x07, 0xE0]  // red and green, high byte first
    let row: [UInt8] = [0xFF, 0, 0xFF, 1]  // index 0 twice, then index 1 twice (0xFF: the next byte 257 − 255 times)
    bytes += [UInt8(row.count), 0] + row
    let screen = Framebuffer(size: size)
    try Capture.apply(Data(bytes), to: screen)
    XCTAssertEqual(screen.pixel(x: 0, y: 0).r, 255)
    XCTAssertEqual(screen.pixel(x: 1, y: 0).g, 0)
    XCTAssertEqual(screen.pixel(x: 2, y: 0).g, 255)
    XCTAssertEqual(screen.pixel(x: 3, y: 0).r, 0)
  }

  func testUnpackBits() {
    XCTAssertEqual(Capture.unpackBits([2, 7, 8, 9][...], count: 3), [7, 8, 9], "A literal block of three")
    XCTAssertEqual(Capture.unpackBits([0xFE, 5][...], count: 3), [5, 5, 5], "A run: 257 − 254")
    XCTAssertEqual(Capture.unpackBits([0, 1, 0x80, 0xFF, 2][...], count: 3), [1, 2, 2], "128 is nothing")
    XCTAssertNil(Capture.unpackBits([2, 7, 8][...], count: 3), "A literal block cut short")
    XCTAssertNil(Capture.unpackBits([0xFE, 5][...], count: 4), "Not the row's length")
  }

  func testShortReplyFails() {
    XCTAssertThrowsError(try Capture.apply(Data([1, 2, 3]), to: Framebuffer(size: .ultra)))
  }
}
