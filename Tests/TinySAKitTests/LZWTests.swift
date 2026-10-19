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

  /// The end code is written at the width a decoder reads it: wider when the table reached the next size with the
  /// last code (a strict decoder found no end code in such streams).
  func testEndCodeWidth() throws {
    var lzw = LZWEncoder()
    let example: [UInt8] = [1, 0, 0, 0, 2, 3, 2, 2, 1, 3, 1, 1, 0]
    XCTAssertEqual(try DecodedGIF.lzwDecode(lzw.encode(example, codeSize: 2), codeSize: 2, count: example.count), example)
    var generator = SeededGenerator(seed: 7)
    for _ in 0..<20_000 {
      let symbols = (0..<Int.random(in: 1...40, using: &generator)).map { _ in UInt8.random(in: 0...3, using: &generator) }
      XCTAssertEqual(try DecodedGIF.lzwDecode(lzw.encode(symbols, codeSize: 2), codeSize: 2, count: symbols.count), symbols)
    }
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

/// The same "random" numbers on every run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
