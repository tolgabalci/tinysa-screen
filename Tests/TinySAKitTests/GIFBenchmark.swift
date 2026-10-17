import ImageIO
import XCTest

@testable import TinySAKit

/// Sizes and times of GIFs from real frames of the analyzer: set GIF_BENCH_FRAMES to a folder of PNG frames, each twice
/// the screen's size, taken a sweep apart (and GIF_BENCH_NO_WATERFALL to blank the waterfall's rows). Skipped otherwise.
final class GIFBenchmark: XCTestCase {
  func testSizes() throws {
    guard let folder = ProcessInfo.processInfo.environment["GIF_BENCH_FRAMES"] else {
      throw XCTSkip("Set GIF_BENCH_FRAMES to a folder of frames")
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".png") }.sorted()
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000.4)
    var frames: [RecordedFrame] = []
    for (k, file) in files.enumerated() {
      let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
      let big = try XCTUnwrap(Snapshot(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))))
      let width = big.width / 2
      let height = big.height / 2
      var pixels = [UInt32](repeating: 0, count: width * height)
      for y in 0..<height {
        for x in 0..<width { pixels[y * width + x] = big.pixels[2 * y * big.width + 2 * x] }
      }
      frames.append(RecordedFrame(Snapshot(width: width, height: height, pixels: pixels), at: start.addingTimeInterval(0.77 * Double(k))))
    }
    if ProcessInfo.processInfo.environment["GIF_BENCH_NO_WATERFALL"] != nil {
      // The waterfall's rows blanked: what a screen without a waterfall costs.
      frames = frames.map { frame in
        var snapshot = frame.snapshot()!
        for y in 180..<snapshot.height {
          for x in 30..<snapshot.width { snapshot.pixels[y * snapshot.width + x] = Snapshot.pixel(r: 0, g: 0, b: 0) }
        }
        return RecordedFrame(snapshot, at: frame.time)
      }
    }
    let end = start.addingTimeInterval(0.77 * Double(frames.count))
    let clip = try XCTUnwrap(Clip(frames: frames, from: start, to: end))
    print("frames \(frames.count), \(String(format: "%.1f", clip.duration)) s, kept \(frames.reduce(0) { $0 + $1.size } / 1024) KB")
    for scale in [1, 2] {
      for caption in [false, true] {
        for ways in [[GIF.Way.opaque, .either]] {
          GIF.ways = ways
          let began = Date()
          let gif = try XCTUnwrap(GIF.make(clip, options: GIFOptions(scale: scale, showsDate: caption, showsTime: caption)))
          let took = Date().timeIntervalSince(began)
          print(
            "scale \(scale) caption \(caption) ways \(ways): \(gif.data.count / 1024) KB, \(gif.images) images, \(String(format: "%.2f", took)) s"
          )
          if scale == 2, caption, ways == [.opaque, .either] {
            try gif.data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-2x.gif"))
          }
          if scale == 1, caption, ways == [.opaque, .either] {
            try gif.data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-1x.gif"))
          }
        }
      }
    }
    GIF.ways = [.opaque, .either]
  }
}
