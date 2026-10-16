import Foundation

/// Recordings from a tinySA Ultra+ (ZS406, firmware v1.4-252) sweeping 902–928 MHz:
/// - `capture-rle.bin`: its reply to `capture rle` (the screen packed);
/// - `capture-raw.bin.deflate`: its reply to `capture` half a second later (the same screen raw), DEFLATE-compressed;
/// - `stream.bin.deflate`: 7.5 s after `refresh on` (1,209 regions, with the echoes of `touch 240 160` and
///   `release 240 160` between them, then `refresh off`), DEFLATE-compressed.
enum Fixture {
  static func data(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    return name.hasSuffix(".deflate") ? try (data as NSData).decompressed(using: .zlib) as Data : data
  }
}
