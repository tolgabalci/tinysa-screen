import XCTest

@testable import TinySAKit

final class InstrumentTests: XCTestCase {
  /// tinySAs and the NanoVNAs whose firmware speaks the same console; never another USB serial device.
  func testKnowsInstrumentsByTheirUSBName() {
    XCTAssertEqual(Instrument(product: "tinySA4"), .tinySA)
    XCTAssertEqual(Instrument(product: "tinySA"), .tinySA)
    XCTAssertEqual(Instrument(product: "NanoVNA-H4"), .nanoVNA)
    XCTAssertEqual(Instrument(product: "NanoVNA-H"), .nanoVNA)
    XCTAssertEqual(Instrument(product: "NanoVNA"), .nanoVNA)
    XCTAssertNil(Instrument(product: "NanoVNA-F"))
    XCTAssertNil(Instrument(product: "NanoVNA V2"))
    XCTAssertNil(Instrument(product: "USB Serial"))
  }

  func testScreenSizes() {
    XCTAssertEqual(ScreenSize.of(version: "tinySA4_v1.4-252-g2b4aa51"), .ultra)
    XCTAssertEqual(ScreenSize.of(version: "tinySA_v1.4-199"), .basic)
    XCTAssertEqual(ScreenSize.of(nanoVNA: "NanoVNA-H4"), .ultra)
    XCTAssertEqual(ScreenSize.of(nanoVNA: "NanoVNA-H"), .basic)
  }

  func testShortVersions() {
    XCTAssertEqual(Session.shortVersion("tinySA4_v1.4-252-g2b4aa51"), "v1.4-252")
    XCTAssertEqual(Session.shortVersion("1.2.52"), "v1.2.52")
  }
}
