import Darwin
import Foundation
import IOKit
import IOKit.serial

/// A tinySA on USB: its serial port, and the product name it gives ("tinySA4" for the Ultra models).
public struct Device: Equatable, Sendable {
  public let path: String
  public let product: String
  public let serialNumber: String?
}

public enum DeviceFinder {
  /// The tinySAs on USB, by the product name of the USB device behind each serial port, so other USB serial devices
  /// are never opened.
  public static func tinySAs() -> [Device] {
    let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
    matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var devices: [Device] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard let path = property(service, kIOCalloutDeviceKey, searchParents: false) as? String,
        let product = (property(service, "USB Product Name") ?? property(service, "kUSBProductString")) as? String,
        product.lowercased().contains("tinysa")
      else { continue }
      let serial = (property(service, "USB Serial Number") ?? property(service, "kUSBSerialNumberString")) as? String
      devices.append(Device(path: path, product: product, serialNumber: serial))
    }
    return devices.sorted { $0.path < $1.path }
  }

  private static func property(_ service: io_object_t, _ key: String, searchParents: Bool = true) -> Any? {
    if !searchParents {
      return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
  }
}

/// A serial port opened for this program alone (TIOCEXCL), raw, without blocking.
public final class SerialPort {
  public enum Failure: Error, Equatable {
    /// Another program has the port.
    case busy
    /// The port is gone: the tinySA was unplugged or switched off.
    case gone
    case system(Int32)
  }

  public let path: String
  private var fd: Int32 = -1

  public init(path: String) throws {
    self.path = path
    fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { throw Self.failure(errno) }
    guard ioctl(fd, TIOCEXCL) == 0 else {
      let error = errno
      Darwin.close(fd)
      fd = -1
      throw Self.failure(error)
    }
    var settings = termios()
    tcgetattr(fd, &settings)
    cfmakeraw(&settings)
    settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
    tcsetattr(fd, TCSANOW, &settings)
    tcflush(fd, TCIOFLUSH)
  }

  deinit { close() }

  public var isOpen: Bool { fd >= 0 }

  public func close() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
  }

  /// Writes all of `text`: a device that takes nothing for 2 s counts as gone.
  public func write(_ text: String) throws {
    var bytes = Array(text.utf8)[...]
    let deadline = Date() + 2
    while !bytes.isEmpty {
      let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if (errno == EAGAIN || errno == EINTR) && Date() < deadline {
          usleep(1000)
          continue
        }
        throw errno == EAGAIN ? Failure.gone : Self.failure(errno)
      }
      bytes = bytes.dropFirst(n)
    }
  }

  /// The bytes that came within `timeout` seconds: empty when none did.
  public func read(timeout: TimeInterval) throws -> [UInt8] {
    var readable = fd_set()
    fdZero(&readable)
    fdSet(fd, &readable)
    var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    let ready = select(fd + 1, &readable, nil, nil, &wait)
    if ready < 0 {
      if errno == EINTR { return [] }
      throw Self.failure(errno)
    }
    guard ready > 0 else { return [] }
    let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    if n == 0 { throw Failure.gone }  // readable with nothing to read: the device left
    if n < 0 {
      if errno == EAGAIN || errno == EINTR { return [] }
      throw Self.failure(errno)
    }
    return Array(scratch[0..<n])
  }

  /// Where reads land before they are copied out (the stream comes at about 150 KB a second).
  private var scratch = [UInt8](repeating: 0, count: 1 << 16)

  /// Drops what came in and wasn't read.
  public func discardInput() {
    tcflush(fd, TCIFLUSH)
  }

  private static func failure(_ code: Int32) -> Failure {
    switch code {
    case EBUSY: return .busy
    case ENOENT, ENXIO, ENODEV, EIO: return .gone
    default: return .system(code)
    }
  }
}

// fd_set helpers (the C macros don't come through to Swift).
private func fdZero(_ set: inout fd_set) {
  set = fd_set()
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
  let word = Int(fd) / 32
  let bit = Int32(fd) % 32
  withUnsafeMutableBytes(of: &set.fds_bits) { raw in
    let words = raw.bindMemory(to: Int32.self)
    words[word] |= 1 << bit
  }
}

public enum PortUsers {
  /// The other programs that have a file open, by name (lsof), so the window can say who has the tinySA.
  public static func of(_ path: String) -> [String] {
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-F", "pc", "--", path]
    let output = Pipe()
    lsof.standardOutput = output
    lsof.standardError = FileHandle.nullDevice
    do { try lsof.run() } catch { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    lsof.waitUntilExit()
    var names: [String] = []
    var pid: Int32 = 0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
      if line.hasPrefix("c"), pid != getpid() { names.append(String(line.dropFirst())) }
    }
    return names
  }
}
