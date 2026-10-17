import XCTest

@testable import TinySAKit

final class LZWTests: XCTestCase {
  /// Whatever goes in comes out, at every code size, through table resets.
  func testRoundTrips() throws {
    var generator = SystemRandomNumberGenerator()
    var lzw = LZWEncoder()
    for codeSize in 2...8 {
      for count in [1, 2, 3, 10, 1000, 70_000] {
        let symbols = (0..<count).map { _ in UInt8.random(in: 0..<UInt8(1 << codeSize - 1), using: &generator) }
        let encoded = lzw.encode(symbols, codeSize: codeSize)
        XCTAssertEqual(
          try DecodedGIF.lzwDecode(encoded, codeSize: codeSize, count: count), symbols,
          "code size \(codeSize), \(count) symbols")
      }
    }
  }

  /// A long run of one value fills the table with ever longer strings, and screens are mostly such runs.
  func testLongRuns() throws {
    var lzw = LZWEncoder()
    let symbols = [UInt8](repeating: 3, count: 500_000) + [UInt8](repeating: 1, count: 1000) + [2]
    let encoded = lzw.encode(symbols, codeSize: 2)
    XCTAssertLessThan(encoded.count, 2000)
    XCTAssertEqual(try DecodedGIF.lzwDecode(encoded, codeSize: 2, count: symbols.count), symbols)
  }

  /// Runs and noise mixed, as a screen with a waterfall has: the table fills and starts again many times.
  func testMixedContent() throws {
    var generator = SystemRandomNumberGenerator()
    var lzw = LZWEncoder()
    var symbols: [UInt8] = []
    for _ in 0..<300 {
      symbols += [UInt8](repeating: UInt8.random(in: 0..<255, using: &generator), count: Int.random(in: 1...400))
      symbols += (0..<Int.random(in: 1...300)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
    let encoded = lzw.encode(symbols, codeSize: 8)
    XCTAssertEqual(try DecodedGIF.lzwDecode(encoded, codeSize: 8, count: symbols.count), symbols)
  }

  /// Where a pixel offers two indices, the decoded one is one of them, and the choice makes the output smaller.
  func testAlternatesGiveEitherIndex() throws {
    var generator = SystemRandomNumberGenerator()
    var lzw = LZWEncoder()
    let count = 50_000
    var symbols: [UInt8] = []
    var alternates: [UInt8] = []
    // Runs of unchanged pixels (transparent 15, or their own colour), and changed pixels.
    while symbols.count < count {
      let n = Int.random(in: 1...60, using: &generator)
      let color = UInt8.random(in: 0..<4, using: &generator)
      if Bool.random(using: &generator) {
        symbols += [UInt8](repeating: 15, count: n)
        alternates += [UInt8](repeating: color, count: n)
      } else {
        symbols += [UInt8](repeating: color, count: n)
        alternates += [UInt8](repeating: color, count: n)
      }
    }
    let encoded = lzw.encode(symbols, alternates: alternates, codeSize: 4)
    let decoded = try DecodedGIF.lzwDecode(encoded, codeSize: 4, count: symbols.count)
    for i in symbols.indices {
      XCTAssertTrue(decoded[i] == symbols[i] || decoded[i] == alternates[i], "pixel \(i)")
    }
    XCTAssertLessThan(encoded.count, lzw.encode(symbols, codeSize: 4).count)
  }

  func testEmptyAndCodeSizes() throws {
    var lzw = LZWEncoder()
    XCTAssertEqual(try DecodedGIF.lzwDecode(lzw.encode([], codeSize: 2), codeSize: 2, count: 0), [])
    XCTAssertEqual(LZWEncoder.codeSize(for: 1), 2)
    XCTAssertEqual(LZWEncoder.codeSize(for: 4), 2)
    XCTAssertEqual(LZWEncoder.codeSize(for: 5), 3)
    XCTAssertEqual(LZWEncoder.codeSize(for: 256), 8)
  }
}
