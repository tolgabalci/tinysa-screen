import XCTest

@testable import TinySAKit

final class FrameRecorderTests: XCTestCase {
  let zero = Date(timeIntervalSinceReferenceDate: 800_000_000)

  /// A small screen, different for each `n`.
  func screen(_ n: Int, width: Int = 4) -> Snapshot {
    Snapshot(width: width, height: 2, pixels: (0..<(width * 2)).map { UInt32($0 + 1000 * n) })
  }

  func at(_ seconds: TimeInterval) -> Date { zero.addingTimeInterval(seconds) }

  /// A recording keeps the screen as it was when it began, and every frame after, until it ends.
  func testRecordingKeepsFramesFromItsStart() throws {
    let recorder = FrameRecorder()
    for t in 0..<3 { recorder.add(screen(t), at: at(Double(t))) }
    XCTAssertEqual(recorder.memory, 0, "nothing kept while nothing records")
    let id = recorder.begin(at: at(2.5))
    recorder.add(screen(3), at: at(3))
    recorder.add(screen(4), at: at(4))
    let clip = try XCTUnwrap(recorder.end(id, at: at(4.5)))
    XCTAssertEqual(clip.frames.map(\.time), [at(2), at(3), at(4)])
    XCTAssertEqual(clip.frames.first?.snapshot(), screen(2))
    XCTAssertEqual(clip.start, at(2.5))
    XCTAssertEqual(clip.end, at(4.5))
    XCTAssertEqual(recorder.memory, 0, "frames let go when the recording ends")
    XCTAssertNil(recorder.end(id), "ends once")
  }

  /// A recording runs two minutes at most.
  func testRecordingStopsAtTwoMinutes() throws {
    let recorder = FrameRecorder()
    let id = recorder.begin(at: at(0))
    for t in stride(from: 0, through: 150, by: 10) { recorder.add(screen(t), at: at(Double(t))) }
    let clip = try XCTUnwrap(recorder.end(id, at: at(150)))
    XCTAssertEqual(clip.duration, 120)
    XCTAssertEqual(clip.frames.last?.time, at(120))
  }

  /// With seconds kept, the latest of them are always there, and older ones go, except the screen as it was when the
  /// kept seconds begin.
  func testKeepsTheLatestSeconds() throws {
    let recorder = FrameRecorder()
    recorder.keepRecent = 5
    for t in 0...20 { recorder.add(screen(t), at: at(Double(t))) }
    XCTAssertEqual(recorder.recentSeconds(at: at(20)), 5)
    let clip = try XCTUnwrap(recorder.recent(at: at(20)))
    XCTAssertEqual(clip.frames.map(\.time), (15...20).map { at(Double($0)) })
    XCTAssertEqual(clip.duration, 5)
    let part = try XCTUnwrap(recorder.recent(2, at: at(20)))
    XCTAssertEqual(part.frames.map(\.time), [at(18), at(19), at(20)])
    recorder.keepRecent = 0
    XCTAssertNil(recorder.recent(at: at(20)))
    XCTAssertEqual(recorder.memory, 0)
  }

  /// Just switched on, the kept seconds are as many as have come.
  func testKeptSecondsGrowFromNothing() throws {
    let recorder = FrameRecorder()
    recorder.add(screen(0), at: at(0))
    recorder.keepRecent = 60
    for t in 1...10 { recorder.add(screen(t), at: at(Double(t))) }
    XCTAssertEqual(recorder.recentSeconds(at: at(10)), 10)
    XCTAssertEqual(try XCTUnwrap(recorder.recent(at: at(10))).duration, 10)
    XCTAssertEqual(recorder.keepRecent, 60)
    recorder.keepRecent = 500
    XCTAssertEqual(recorder.keepRecent, 120, "two minutes at most")
  }

  /// A screen that doesn't change is kept once: the GIF shows it until the next change.
  func testSameScreenIsKeptOnce() throws {
    let recorder = FrameRecorder()
    recorder.keepRecent = 60
    recorder.add(screen(1), at: at(0))
    recorder.add(screen(1), at: at(1))
    recorder.add(screen(1), at: at(2))
    recorder.add(screen(2), at: at(3))
    XCTAssertEqual(try XCTUnwrap(recorder.recent(at: at(4))).frames.map(\.time), [at(0), at(3)])
  }

  /// A screen of another size (another analyzer) starts afresh: one GIF has one size.
  func testAnotherSizeStartsAfresh() throws {
    let recorder = FrameRecorder()
    recorder.keepRecent = 60
    recorder.add(screen(1), at: at(0))
    recorder.add(screen(2, width: 6), at: at(1))
    let clip = try XCTUnwrap(recorder.recent(at: at(2)))
    XCTAssertEqual(clip.frames.count, 1)
    XCTAssertEqual(clip.frames.first?.width, 6)
  }

  /// Frames closer than 50 ms: the later replaces the earlier.
  func testCloseFramesReplaceEachOther() throws {
    let recorder = FrameRecorder()
    recorder.keepRecent = 60
    recorder.add(screen(1), at: at(0))
    recorder.add(screen(2), at: at(1))
    recorder.add(screen(3), at: at(1.02))
    let clip = try XCTUnwrap(recorder.recent(at: at(2)))
    XCTAssertEqual(clip.frames.map(\.time), [at(0), at(1.02)])
    XCTAssertEqual(clip.frames.last?.snapshot(), screen(3))
  }

  /// The last seconds of a clip, and the frame on the screen at a moment of it.
  func testClipParts() throws {
    let frames = (0...10).map { RecordedFrame(screen($0), at: at(Double($0))) }
    let clip = try XCTUnwrap(Clip(frames: frames, from: at(0.5), to: at(10.5)))
    XCTAssertEqual(clip.frames.count, 11)
    let last = clip.last(3)
    XCTAssertEqual(last.start, at(7.5))
    XCTAssertEqual(last.frames.map(\.time), [at(7), at(8), at(9), at(10)])
    XCTAssertEqual(clip.frame(at: at(4.2))?.time, at(4))
    XCTAssertEqual(clip.last(100).start, clip.start)
    // Before the first frame there is nothing to show: the clip starts with it.
    let late = try XCTUnwrap(Clip(frames: Array(frames[3...]), from: at(0), to: at(5)))
    XCTAssertEqual(late.start, at(3))
    XCTAssertNil(Clip(frames: frames, from: at(-5), to: at(-1)))
  }

  /// Frames are packed in memory, and come back exactly.
  func testFramesArePackedAndExact() {
    var pixels = [UInt32](repeating: Snapshot.pixel(r: 0, g: 0, b: 0), count: 480 * 320)
    for i in stride(from: 0, to: pixels.count, by: 97) { pixels[i] = Snapshot.pixel(r: 255, g: UInt8(i % 256), b: 0) }
    let screen = Snapshot(width: 480, height: 320, pixels: pixels)
    let frame = RecordedFrame(screen, at: zero)
    XCTAssertLessThan(frame.size, 480 * 320 * 4 / 10)
    XCTAssertEqual(frame.snapshot(), screen)
  }
}
