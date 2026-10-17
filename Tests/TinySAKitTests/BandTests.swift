import XCTest

@testable import TinySAKit

final class BandTests: XCTestCase {
  func testReadsTheSweepReply() {
    XCTAssertEqual(SweepRange(reply: "902000000 928000000 450"), SweepRange(start: 902_000_000, stop: 928_000_000, points: 450))
    XCTAssertEqual(SweepRange(reply: "\r\n87500000 108000000 290\r\n")?.stop, 108_000_000)
    XCTAssertNil(SweepRange(reply: "usage: sweep {start(Hz)} [stop(Hz)] [points]"))
    XCTAssertNil(SweepRange(reply: "928000000 902000000 450"), "start after stop")
  }

  /// Start and stop are set in the order that never lets start pass stop: the analyzer would take the moment they
  /// meet for a zero span and reset its sweep time.
  func testCommandsNeverLetStartPassStop() {
    let ism915 = SweepRange(start: 902_000_000, stop: 928_000_000)
    let wifi = SweepRange(start: 2_400_000_000, stop: 2_483_500_000)
    let fm = SweepRange(start: 87_500_000, stop: 108_000_000)
    XCTAssertEqual(wifi.commands(from: ism915), ["sweep stop 2483500000", "sweep start 2400000000"])
    XCTAssertEqual(fm.commands(from: ism915), ["sweep start 87500000", "sweep stop 108000000"])
    XCTAssertEqual(ism915.commands(from: wifi), ["sweep start 902000000", "sweep stop 928000000"])
    XCTAssertEqual(ism915.commands(from: nil), ["sweep start 902000000", "sweep stop 928000000"])
    // Spans that share an edge: start set first would meet stop.
    let low = SweepRange(start: 902_000_000, stop: 915_000_000)
    let high = SweepRange(start: 915_000_000, stop: 928_000_000)
    XCTAssertEqual(high.commands(from: low), ["sweep stop 928000000", "sweep start 915000000"])
    XCTAssertEqual(low.commands(from: high), ["sweep start 902000000", "sweep stop 915000000"])
    // Every order, simulated as the firmware does it: start never ends up above stop on the way.
    let spans = BandPreset.builtIn.flatMap { $0 }.map(\.range) + [low, high]
    for from in spans {
      for to in spans {
        var current = from
        for line in to.commands(from: from) {
          let parts = line.split(separator: " ")
          let value = Int64(parts[2])!
          if parts[1] == "start" { current.start = value } else { current.stop = value }
          XCTAssertLessThan(current.start, current.stop, "\(from.label) to \(to.label): \(line)")
        }
        XCTAssertTrue(current.matches(to))
      }
    }
  }

  func testParsesFrequencies() {
    XCTAssertEqual(Frequency.parse("902M"), 902_000_000)
    XCTAssertEqual(Frequency.parse("2.4G"), 2_400_000_000)
    XCTAssertEqual(Frequency.parse("433.92 MHz"), 433_920_000)
    XCTAssertEqual(Frequency.parse("100k"), 100_000)
    XCTAssertEqual(Frequency.parse("915000000"), 915_000_000)
    XCTAssertEqual(Frequency.parse("2.4835GHz"), 2_483_500_000)
    XCTAssertEqual(Frequency.parse("1.2e9"), 1_200_000_000)
    XCTAssertNil(Frequency.parse("fast"))
    XCTAssertNil(Frequency.parse("-5M"))
    XCTAssertNil(Frequency.parse(""))
  }

  func testFormatsFrequencies() {
    XCTAssertEqual(Frequency.format(902_000_000), "902 MHz")
    XCTAssertEqual(Frequency.format(2_483_500_000), "2483.5 MHz")
    XCTAssertEqual(Frequency.format(100_000), "100 kHz")
    XCTAssertEqual(Frequency.format(433_920_000), "433.92 MHz")
    XCTAssertEqual(Frequency.range(902_000_000, 928_000_000), "902–928 MHz")
    XCTAssertEqual(Frequency.range(2_400_000_000, 2_483_500_000), "2400–2483.5 MHz")
    XCTAssertEqual(Frequency.range(698_000_000, 1_095_000_000), "698–1095 MHz")
    XCTAssertEqual(Frequency.range(100_000, 30_000_000), "0.1–30 MHz")
    XCTAssertEqual(SweepRange(start: 87_500_000, stop: 108_000_000).label, "87.5–108 MHz")
  }

  /// The analyzer rounds to its steps: a span read back within a hertz per megahertz is the same.
  func testMatchesWithinRounding() {
    let asked = SweepRange(start: 433_050_000, stop: 434_790_000)
    XCTAssertTrue(asked.matches(SweepRange(start: 433_050_000, stop: 434_789_900, points: 450)))
    XCTAssertFalse(asked.matches(SweepRange(start: 433_000_000, stop: 434_790_000)))
  }

  /// The built-in bands are within a tinySA Ultra's range, and named once.
  func testBuiltInBands() {
    let bands = BandPreset.builtIn.flatMap { $0 }
    XCTAssertEqual(Set(bands.map(\.name)).count, bands.count)
    for band in bands {
      XCTAssertGreaterThan(band.range.stop, band.range.start, band.name)
      XCTAssertLessThanOrEqual(band.range.stop, 6_000_000_000, band.name)
    }
  }
}
