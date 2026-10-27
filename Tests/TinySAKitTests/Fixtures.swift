import Foundation
import ImageIO

@testable import TinySAKit

/// Recordings from a tinySA Ultra+ (ZS406, firmware v1.4-252) sweeping 902–928 MHz:
/// - `capture-rle.bin`: its reply to `capture rle` (the screen packed);
/// - `capture-raw.bin.deflate`: its reply to `capture` half a second later (the same screen raw), DEFLATE-compressed;
/// - `stream.bin.deflate`: 7.5 s after `refresh on` (1,209 regions, with the echoes of `touch 240 160` and
///   `release 240 160` between them, then `refresh off`), DEFLATE-compressed.
///
/// And its screen as tinySA Screen saw it (480 × 320):
/// - `screen-915.png`: 902–928 MHz, +10 dBm at the top, 10 dB a division, the small waterfall;
/// - `screen-915-big.png`: the same band with a reader hopping, the green holding its channels, a taller waterfall;
/// - `screen-433.png`: 433.05–434.79 MHz, 0 dBm at the top;
/// - `screen-915-burst.png`: a sweep that caught the reader's burst at 902.231 MHz, −23.2 dBm by the analyzer's own
///   marker 2 (fed by a monitor program, its markers on the green);
/// - `screen-keypad.png`: its number keypad, START being typed, nothing typed yet (opened by a click in the window).
enum Fixture {
  static func data(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    return name.hasSuffix(".deflate") ? try (data as NSData).decompressed(using: .zlib) as Data : data
  }

  static func screen(_ name: String) throws -> Snapshot {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return Snapshot(CGImageSourceCreateImageAtIndex(source, 0, nil)!)!
  }
}
