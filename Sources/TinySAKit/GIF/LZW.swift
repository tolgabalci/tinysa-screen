/// GIF's LZW compression (GIF89a, appendix F): palette indices in, variable-length codes out, packed least significant
/// bit first. Codes start one bit wider than the indices and grow to 12 bits; a clear code starts the stream and the
/// table again whenever it fills, and the end code closes it.
///
/// A pixel may offer two indices: one where the frame shows through to the one before it (the transparent index), the
/// other its own colour; both look the same, and the encoder takes whichever continues the string it is matching, so
/// runs of unchanged pixels and runs of one colour both stay long.
struct LZWEncoder {
  private static let slots = 8192  // twice the 4096 codes: short probes
  private var keys = [Int32](repeating: -1, count: LZWEncoder.slots)
  private var codes = [UInt16](repeating: 0, count: LZWEncoder.slots)

  /// The smallest code size for indices below `count`: at least 2 bits, as GIF requires.
  static func codeSize(for count: Int) -> Int {
    var bits = 2
    while 1 << bits < count { bits += 1 }
    return bits
  }

  /// The compressed codes of `symbols` (each below `1 << codeSize`); where `alternates` differs from `symbols`, either
  /// index will do for that pixel.
  mutating func encode(_ symbols: [UInt8], alternates: [UInt8]? = nil, codeSize: Int) -> [UInt8] {
    precondition((2...8).contains(codeSize))
    var out = BitWriter(capacity: symbols.count / 2 + 16)
    let clear = 1 << codeSize
    let end = clear + 1
    var width = codeSize + 1
    var next = clear + 2
    reset()
    out.write(clear, width)
    guard let first = symbols.first else {
      out.write(end, width)
      return out.finish()
    }
    let alternates = alternates ?? symbols
    precondition(alternates.count == symbols.count)
    symbols.withUnsafeBufferPointer { symbols in
      alternates.withUnsafeBufferPointer { alternates in
        keys.withUnsafeMutableBufferPointer { keys in
          codes.withUnsafeMutableBufferPointer { codes in
            let n = symbols.count
            var current = Int(first)
            if alternates[0] != first, n > 1, alternates[0] == symbols[1] { current = Int(alternates[0]) }
            var i = 1
            while i < n {
              let symbol = Int(symbols[i])
              var slot = Self.slot(current << 8 | symbol, keys)
              if keys[slot] >= 0 {
                current = Int(codes[slot])
                i += 1
                continue
              }
              let alternate = Int(alternates[i])
              if alternate != symbol {
                let other = Self.slot(current << 8 | alternate, keys)
                if keys[other] >= 0 {
                  current = Int(codes[other])
                  i += 1
                  continue
                }
              }
              out.write(current, width)
              // The next string starts with this pixel: as its own colour when the next pixel has that colour too.
              var start = symbol
              if alternate != symbol, i + 1 < n, Int(symbols[i + 1]) == alternate {
                start = alternate
                slot = Self.slot(current << 8 | alternate, keys)
              }
              keys[slot] = Int32(current << 8 | start)
              codes[slot] = UInt16(next)
              next += 1
              if next > 1 << width, width < 12 { width += 1 }
              if next == 4096 {
                out.write(clear, width)
                keys.update(repeating: -1)
                width = codeSize + 1
                next = clear + 2
              }
              current = start
              i += 1
            }
            out.write(current, width)
          }
        }
      }
    }
    out.write(end, width)
    return out.finish()
  }

  /// Where `key` is in the table, or the empty slot where it would go.
  @inline(__always)
  private static func slot(_ key: Int, _ keys: UnsafeMutableBufferPointer<Int32>) -> Int {
    var slot = Int((UInt32(truncatingIfNeeded: key) &* 2_654_435_761) >> 19)
    while true {
      let found = keys[slot]
      if found < 0 || Int(found) == key { return slot }
      slot = (slot + 1) & (slots - 1)
    }
  }

  private mutating func reset() {
    keys.withUnsafeMutableBufferPointer { $0.update(repeating: -1) }
  }
}

/// Codes of varying width packed into bytes, least significant bit first.
struct BitWriter {
  private var bytes: [UInt8] = []
  private var buffer: UInt64 = 0
  private var count = 0

  init(capacity: Int) { bytes.reserveCapacity(capacity) }

  @inline(__always)
  mutating func write(_ code: Int, _ width: Int) {
    buffer |= UInt64(code) << UInt64(count)
    count += width
    while count >= 8 {
      bytes.append(UInt8(truncatingIfNeeded: buffer))
      buffer >>= 8
      count -= 8
    }
  }

  mutating func finish() -> [UInt8] {
    if count > 0 { bytes.append(UInt8(truncatingIfNeeded: buffer)) }
    buffer = 0
    count = 0
    return bytes
  }
}
