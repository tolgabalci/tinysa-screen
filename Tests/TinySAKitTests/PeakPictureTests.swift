import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import TinySAKit

/// The peak hold in pictures (GIFs, screenshots) and its words: when each peak came in, the box in the order they came,
/// the labels beside them.
final class PeakPictureTests: XCTestCase {
  let start = Date(timeIntervalSinceReferenceDate: 1000)  // 2001-01-01 00:16:40 UTC
  let utc = TimeZone(identifier: "UTC")!
  let us = Locale(identifier: "en_US")
  static let cyan = PeakLook.Color.cyan.pixel

  /// A screen like the analyzer's: a dotted grid every 24 rows from x = 30, the noise floor at row 200, and peaks.
  func screen(peaks: [(column: Int, row: Int)]) -> Snapshot {
    var screen = Snapshot(
      width: 480, height: 320, pixels: Array(repeating: Snapshot.pixel(r: 0, g: 0, b: 0), count: 480 * 320))
    let grey = Snapshot.pixel(r: 0x83, g: 0x81, b: 0x83)
    let yellow = Snapshot.pixel(r: 255, g: 255, b: 0)
    for y in stride(from: 0, through: 240, by: 24) {
      for x in stride(from: 30, to: 480, by: 2) { screen.pixels[y * 480 + x] = grey }
    }
    for y in stride(from: 0, through: 240, by: 2) { screen.pixels[y * 480 + 30] = grey }
    for x in 30..<480 { screen.pixels[200 * 480 + x] = yellow }
    for peak in peaks {
      for y in peak.row...200 { screen.pixels[y * 480 + peak.column] = yellow }
    }
    return screen
  }

  /// The hold of `screens` (each at its seconds from `start`), its labels as if read: 900 to 930 MHz across the
  /// graph, +10 dBm at the top, 10 dB a division of 24 rows; its peaks numbered highest first.
  func held(_ screens: [(Snapshot, TimeInterval)]) throws -> PeakHold.State {
    let hold = PeakHold()
    for (screen, seconds) in screens { hold.add(screen, at: start.addingTimeInterval(seconds)) }
    var state = try XCTUnwrap(hold.state)
    state.scale = GraphScale(level0: 10, perRow: -10.0 / 24, start: 900_000_000, stop: 930_000_000)
    state.peaks = PeakHold.peaks(in: state, count: 5).enumerated().map { i, peak in
      var peak = peak
      peak.number = i + 1
      return peak
    }
    return state
  }

  /// "12:16:45 AM", the narrow space before AM as a plain one.
  func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

  /// A peak's time is the sweep that first reached its held level: a later sweep as high leaves it, a higher one
  /// moves it.
  func testPeaksRememberWhenTheyCameIn() throws {
    let state = try held([
      (screen(peaks: [(100, 120), (300, 150)]), 0),
      (screen(peaks: [(100, 120), (300, 140)]), 2),
      (screen(peaks: [(100, 110), (300, 140)]), 4),
      (screen(peaks: [(100, 110), (300, 140)]), 6),
    ])
    let times = Dictionary(uniqueKeysWithValues: state.peaks.map { ($0.column, $0.time) })
    XCTAssertEqual(times[100], start.addingTimeInterval(4))
    XCTAssertEqual(times[300], start.addingTimeInterval(2))
  }

  /// The box lists a peak a line in the order they came in, not by number: its number, the time to the second, the
  /// frequency as finely as a column resolves and the level; no "since" title.
  func testTheBoxListsThePeaksInTheOrderTheyCameIn() throws {
    var state = try held([(screen(peaks: [(100, 120), (300, 150)]), 0)])
    XCTAssertEqual(state.peaks.count, 2)
    state.peaks[0].time = start.addingTimeInterval(9)  // number 1 came in last
    state.peaks[1].time = start.addingTimeInterval(5)
    let lines = state.readouts(locale: us, timeZone: utc).map(plain)
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].hasPrefix("2  12:16:45 AM  9"), lines[0])
    XCTAssertTrue(lines[1].hasPrefix("1  12:16:49 AM  9"), lines[1])
    XCTAssertTrue(lines[0].hasSuffix(" dBm"), lines[0])
    XCTAssertEqual(lines[0].split(separator: ".").last?.prefix(2).allSatisfy(\.isNumber), true, "decimals")
    XCTAssertEqual(state.title, "Peak hold")
    state.window = 60
    XCTAssertEqual(state.title, "Peak hold, last 1:00")
  }

  /// Without the box, a peak's label is when it came in, its megahertz to the nearest and its level to the decibel.
  func testALabelBesideAPeak() {
    var peak = PeakHold.Peak(number: 3, column: 100, row: 50)
    XCTAssertEqual(peak.label(locale: us, timeZone: utc), ["3"], "nothing known yet but its number")
    peak.time = start
    peak.frequency = 910_740_000
    peak.level = -58.4
    XCTAssertEqual(peak.label(locale: us, timeZone: utc), ["12:16:40", "911 MHz", "−58 dBm"], "no AM or PM")
    let british = Locale(identifier: "en_GB")  // a 24-hour clock: nothing to drop
    XCTAssertEqual(
      peak.label(locale: british, timeZone: utc).first, PeakHold.clock(start, locale: british, timeZone: utc))
  }

  /// Labels go right of their peaks, left at the graph's right edge, and never over one another or a peak's top.
  func testLabelsKeepClearOfEachOther() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 60, height: 40)
    let tops = [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 150), CGPoint(x: 390, y: 50)]
    let places = PeakLabels.place([size, size, size], at: tops, within: bounds, gap: 4)
    XCTAssertEqual(places[0].rect.minX, 104)
    XCTAssertEqual(places[2].rect.maxX, 386, "left of a peak at the right edge")
    XCTAssertEqual(places.map(\.away), [false, false, false])
    for place in places { XCTAssertTrue(bounds.contains(place.rect)) }
  }

  /// Peaks close together: the older peak's label goes beside it, a newer one's moves clear, above first, with an
  /// arrow to its peak; none covers another or a peak's top.
  func testANewerPeaksLabelMovesClearWithAnArrow() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 60, height: 40)
    let tops = [CGPoint(x: 200, y: 200), CGPoint(x: 206, y: 195), CGPoint(x: 194, y: 198)]
    let places = PeakLabels.place([size, size, size], at: tops, order: [2, 0, 1], within: bounds, gap: 4)
    XCTAssertFalse(places[2].away, "the oldest, beside its peak")
    XCTAssertTrue(places[0].away && places[1].away)
    for (i, place) in places.enumerated() {
      XCTAssertTrue(bounds.contains(place.rect))
      for (j, other) in places.enumerated() where j != i { XCTAssertFalse(place.rect.intersects(other.rect)) }
      for top in tops { XCTAssertFalse(place.rect.contains(top)) }
    }
    XCTAssertLessThan(places[0].rect.maxY, tops[0].y, "moved up, where the graph's emptier")
    let arrow = PeakLabels.arrow(from: places[0].rect, to: tops[0])
    XCTAssertEqual(arrow.to, tops[0])
    XCTAssertTrue(places[0].rect.insetBy(dx: -0.5, dy: -0.5).contains(arrow.from))
  }

  /// Drawn into a picture, the hold is its line, tags and box (or labels), in its colour, black and white, and the
  /// words' few shades: a GIF keeps them all.
  func testThePictureHasFewColours() throws {
    var state = try held([(screen(peaks: [(100, 120), (300, 150), (420, 100)]), 0)])
    for i in state.peaks.indices { state.peaks[i].time = start.addingTimeInterval(Double(i)) }
    for listed in [true, false] {
      let picture = PeakPicture(
        width: 960, height: 640, scale: 2, look: PeakLook(listed: listed), locale: us, timeZone: utc)
      let pixels = picture.pixels(for: state)
      let colours = Set(pixels.filter { $0 != 0 })
      XCTAssertTrue(colours.contains(Self.cyan))
      XCTAssertTrue(colours.contains(PeakPicture.white), "words")
      XCTAssertLessThanOrEqual(colours.count, 24, "listed \(listed)")
      // Each peak's tag (listed) or label (not) at its right, a few pixels from its top.
      for peak in state.peaks where peak.column < 400 {
        let (x, y) = (peak.column * 2 + 1, peak.row * 2 + 1)
        let near = (x + 4..<x + 40).contains { pixels[y * 960 + $0] != 0 }
        XCTAssertTrue(near, "listed \(listed), peak \(peak.number)")
      }
      if let folder = ProcessInfo.processInfo.environment["TINYSA_SCREEN_TEST_PICTURES"] {
        var still = GIF.still(
          screen(peaks: [(100, 120), (300, 150), (420, 100)]), caption: Caption(clock: start),
          options: GIFOptions(scale: 2, showsDate: false, showsTime: false, peaks: PeakLook(listed: listed)),
          peaks: state)
        still = Snapshot(width: still.width, height: still.height, pixels: still.pixels)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("peaks-\(listed ? "listed" : "labels").png")
        let destination = try XCTUnwrap(
          CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(still.image()), nil)
        CGImageDestinationFinalize(destination)
      }
    }
  }

  /// However peaks crowd, a label moved away has an arrow that passes behind no label placed before it, and no label
  /// moved away sits on an arrow placed before it.
  func testArrowsPassNoOtherLabel() {
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return range.lowerBound + CGFloat(seed >> 11) / CGFloat(1 << 53) * (range.upperBound - range.lowerBound)
    }
    let bounds = CGRect(x: 60, y: 0, width: 900, height: 480)
    let size = CGSize(width: 76, height: 44)
    var moved = 0
    for _ in 0..<200 {
      let count = 6 + Int(random(0...4))
      let tops = (0..<count).map { _ in CGPoint(x: random(70...950), y: random(60...420)) }
      let places = PeakLabels.place(Array(repeating: size, count: count), at: tops, within: bounds, gap: 8)
      for (i, place) in places.enumerated() where place.away {
        moved += 1
        XCTAssertTrue(bounds.contains(place.rect))
        let (from, to) = PeakLabels.arrow(from: place.rect, to: tops[i])
        for j in 0..<i {
          XCTAssertFalse(PeakLabels.crosses(from, to, places[j].rect.insetBy(dx: 0.5, dy: 0.5)), "behind label \(j)")
          if places[j].away {
            let earlier = PeakLabels.arrow(from: places[j].rect, to: tops[j])
            XCTAssertFalse(PeakLabels.crosses(earlier.from, earlier.to, place.rect), "on label \(j)'s arrow")
          }
        }
      }
    }
    XCTAssertGreaterThan(moved, 50, "crowds enough to move labels")
  }

  /// A low peak by the graph's left edge, tall ones around it: its label moves clear, its arrow passing no label.
  func testALowPeakByTheEdgeAmongTallOnes() throws {
    let scene = screen(peaks: [(40, 150), (60, 40), (90, 46), (130, 43), (200, 40)])
    var state = try held([(scene, 0)])
    XCTAssertEqual(state.peaks.count, 5)
    // The low one by the edge came in last.
    for i in state.peaks.indices {
      state.peaks[i].time = start.addingTimeInterval(state.peaks[i].column == 40 ? 10 : Double(i))
    }
    let still = GIF.still(
      scene, caption: Caption(clock: start),
      options: GIFOptions(scale: 2, showsDate: false, showsTime: false, peaks: PeakLook(listed: false)), peaks: state)
    let orange = still.pixels.filter { $0 == PeakLook.Color.orange.pixel }.count
    XCTAssertGreaterThan(orange, 0, "an arrow, in its own colour")
    if let folder = ProcessInfo.processInfo.environment["TINYSA_SCREEN_TEST_PICTURES"] {
      let url = URL(fileURLWithPath: folder).appendingPathComponent("peaks-edge.png")
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, try XCTUnwrap(still.image()), nil)
      CGImageDestinationFinalize(destination)
    }
  }

  /// Three peaks a few columns apart, labeled beside them: the newer ones' labels moved clear with arrows.
  func testCrowdedPeaksLabelsInAPicture() throws {
    let crowd = screen(peaks: [(200, 110), (206, 120), (212, 105), (360, 140)])
    var state = try held([(crowd, 0)])
    for i in state.peaks.indices { state.peaks[i].time = start.addingTimeInterval(Double(i)) }
    let still = GIF.still(
      crowd, caption: Caption(clock: start),
      options: GIFOptions(scale: 2, showsDate: false, showsTime: false, peaks: PeakLook(listed: false)), peaks: state)
    let cyan = still.pixels.filter { $0 == Self.cyan }.count
    XCTAssertGreaterThan(cyan, 200)
    if let folder = ProcessInfo.processInfo.environment["TINYSA_SCREEN_TEST_PICTURES"] {
      let url = URL(fileURLWithPath: folder).appendingPathComponent("peaks-crowded.png")
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, try XCTUnwrap(still.image()), nil)
      CGImageDestinationFinalize(destination)
    }
  }

  /// A GIF draws the hold where it was on, over the screen, only with `peaks` set; a clip without it has none.
  func testGIFsDrawThePeakHoldWhereItWasOn() throws {
    let state = try held([(screen(peaks: [(100, 120), (300, 150)]), 0)])
    let still = screen(peaks: [(100, 120), (300, 150)])
    let frames = [RecordedFrame(still, at: start)]
    let moments = [PeakMoment(time: start, state: nil), PeakMoment(time: start.addingTimeInterval(1), state: state)]
    let clip = try XCTUnwrap(
      Clip(frames: frames, from: start, to: start.addingTimeInterval(2), peaks: moments))
    XCTAssertTrue(clip.hasPeaks)
    XCTAssertNil(clip.peaks(at: start.addingTimeInterval(0.5)))
    XCTAssertEqual(clip.peaks(at: start.addingTimeInterval(1.5)), state)
    func cyan(_ options: GIFOptions) throws -> [Int] {
      let gif = try DecodedGIF(try XCTUnwrap(GIF.make(clip, options: options)).data)
      return gif.images.map { image in image.canvas.filter { $0 == GIFTests.rgb(Self.cyan) }.count }
    }
    let drawn = try cyan(GIFOptions(showsDate: false, showsTime: false, peaks: PeakLook()))
    XCTAssertEqual(drawn.first, 0, "off at first")
    XCTAssertGreaterThan(drawn.last ?? 0, 100, "on from a second in")
    XCTAssertEqual(try cyan(GIFOptions(showsDate: false, showsTime: false)).max(), 0, "not asked for")
  }

  /// The recorder keeps the hold as it was when nothing recorded, so a recording knows it from its start.
  func testARecordingKnowsTheHoldFromItsStart() throws {
    let state = try held([(screen(peaks: [(100, 120)]), 0)])
    let recorder = FrameRecorder()
    recorder.notePeaks(state, at: start)
    let id = recorder.begin(at: start.addingTimeInterval(5))
    recorder.add(screen(peaks: [(100, 120)]), at: start.addingTimeInterval(5))
    recorder.add(screen(peaks: [(100, 110)]), at: start.addingTimeInterval(6))
    recorder.notePeaks(nil, at: start.addingTimeInterval(7))
    let clip = try XCTUnwrap(recorder.end(id, at: start.addingTimeInterval(8)))
    XCTAssertEqual(clip.peaks(at: clip.start), state)
    XCTAssertNil(clip.peaks(at: start.addingTimeInterval(7.5)), "turned off")
  }
}
