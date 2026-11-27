import XCTest

@testable import TinySAKit

final class TrimTests: XCTestCase {
  let zero = Date(timeIntervalSinceReferenceDate: 800_000_000)
  func at(_ seconds: TimeInterval) -> Date { zero.addingTimeInterval(seconds) }

  /// A clip of a frame a second from `from` to `to`.
  func clip(_ from: Int, _ to: Int) throws -> Clip {
    let frames = (from...to).map {
      RecordedFrame(Snapshot(width: 2, height: 1, pixels: [UInt32($0), 0]), at: at(Double($0)))
    }
    return try XCTUnwrap(Clip(frames: frames, from: at(Double(from)), to: at(Double(to))))
  }

  /// Stop's GIF: from the lead-in before Record to the end, the minute kept before it there to drag back to.
  func testStartsTheLeadInBeforeRecord() throws {
    let trim = Trim(try clip(0, 70), began: at(60), leadIn: 5)
    XCTAssertEqual(trim.bounds, at(0)...at(70))
    XCTAssertEqual(trim.start, at(55))
    XCTAssertEqual(trim.end, at(70))
    XCTAssertEqual(trim.duration, 15)
    XCTAssertEqual(Trim(try clip(57, 70), began: at(60), leadIn: 5).start, at(57), "as far back as the clip goes")
    XCTAssertEqual(Trim(try clip(0, 70), began: at(60), leadIn: 0).start, at(60), "no lead-in: from Record")
  }

  /// The handles stay within the clip and a second apart at least.
  func testHandlesStayInTheClipAndApart() throws {
    var trim = Trim(try clip(0, 70), began: at(60), leadIn: 5)
    trim.moveStart(to: at(-10))
    XCTAssertEqual(trim.start, at(0))
    trim.moveStart(to: at(80))
    XCTAssertEqual(trim.start, at(69))
    trim.moveEnd(to: at(30))
    XCTAssertEqual(trim.end, at(70), "not before the start's second")
    trim.moveStart(to: at(10))
    trim.moveEnd(to: at(30))
    XCTAssertEqual(trim.end, at(30))
    trim.moveEnd(to: at(500))
    XCTAssertEqual(trim.end, at(70))
  }

  /// A clip shorter than a second is kept whole.
  func testAShortClipIsKeptWhole() throws {
    let frames = [RecordedFrame(Snapshot(width: 1, height: 1, pixels: [1]), at: at(0))]
    var trim = Trim(try XCTUnwrap(Clip(frames: frames, from: at(0), to: at(0.4))), began: at(0), leadIn: 5)
    trim.moveEnd(to: at(0.1))
    XCTAssertEqual(trim.start, at(0))
    XCTAssertEqual(trim.end, at(0.4))
  }

  /// Frame by frame: to the next frame, back to the start of the frame on the screen, then to the one before.
  func testStepsFrameByFrame() throws {
    let clip = try clip(10, 20)
    XCTAssertEqual(clip.frameTime(after: at(12)), at(13))
    XCTAssertEqual(clip.frameTime(after: at(12.5)), at(13))
    XCTAssertEqual(clip.frameTime(after: at(20)), at(20), "the end at the last")
    XCTAssertEqual(clip.frameTime(before: at(12.5)), at(12))
    XCTAssertEqual(clip.frameTime(before: at(12)), at(11))
    XCTAssertEqual(clip.frameTime(before: at(10)), at(10), "the start at the first")
    var trim = Trim(clip, began: at(15), leadIn: 2)
    trim.moveEnd(to: at(18))
    let part = clip.part(trim)
    XCTAssertEqual(part.start, at(13))
    XCTAssertEqual(part.end, at(18))
    XCTAssertEqual(part.frames.map(\.time), (13...18).map { at(Double($0)) })
  }
}
