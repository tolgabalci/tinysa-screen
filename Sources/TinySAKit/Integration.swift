import CoreGraphics
import Foundation
import ImageIO

/// How other programs work alongside tinySA Screen (docs/INTEGRATION.md). A tinySA's USB console takes one program at
/// a time, so there are two ways:
///
/// - **Borrowing**: a program that needs the analyzer for a while writes its process ID and name to `~/.tinysa-busy`.
///   tinySA Screen lets go of the analyzer within half a second and says who has it; when the file is gone (or that
///   process has ended), it takes the analyzer back.
/// - **Feeding**: a program that keeps the analyzer itself (a monitor running all day, say) feeds tinySA Screen its
///   pictures: while `watching` in the feed folder is less than three seconds old (the app touches it every second
///   while open), it puts the screen in `screen.png` there, and what it is doing in `state.json`. A feeder whose process
///   runs comes first: the app shows its pictures and leaves the analyzer to it.
public enum Integration {
  /// The home folder the files are in (another one in tests).
  public internal(set) static var home = FileManager.default.homeDirectoryForCurrentUser
  /// Borrowing: "PID name" of the program that asked for the analyzer.
  public static var borrowFile: URL { home.appendingPathComponent(".tinysa-busy") }
  /// Feeding: the folder with `watching`, `screen.png` and `state.json`.
  public static var feedFolder: URL { home.appendingPathComponent("Library/Caches/tinySA Screen", isDirectory: true) }
  public static var watchingFile: URL { feedFolder.appendingPathComponent("watching") }
  public static var pictureFile: URL { feedFolder.appendingPathComponent("screen.png") }
  public static var stateFile: URL { feedFolder.appendingPathComponent("state.json") }
  /// Asking: the open app's control socket, for recordings, captures, screenshots and its status (docs/INTEGRATION.md).
  public static var controlSocket: URL { feedFolder.appendingPathComponent("control.sock") }
}

/// A program that asked to borrow the analyzer.
public struct BorrowRequest: Equatable, Sendable {
  public let pid: Int32
  public let name: String

  /// The current request: nil when there is none, it is this process's own, or the process that asked has ended.
  public static func current() -> BorrowRequest? {
    guard let text = try? String(contentsOf: Integration.borrowFile, encoding: .utf8) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
    guard let first = parts.first, let pid = Int32(first), pid != getpid(),
      isRunning(pid, wrote: Integration.borrowFile)
    else { return nil }
    let name = parts.count > 1 ? String(parts[1]) : "process \(pid)"
    return BorrowRequest(pid: pid, name: name)
  }
}

/// Whether the process that wrote `file` still runs: a process with that ID runs (one of another user counts too), and
/// it started before the file was written, so the ID wasn't handed to another process after the writer ended.
func isRunning(_ pid: Int32, wrote file: URL) -> Bool {
  guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
  guard let started = processStart(pid),
    let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
  else { return true }
  return started <= written.addingTimeInterval(1)
}

/// When a process started, from the kernel (sysctl), or nil if that can't be read.
func processStart(_ pid: Int32) -> Date? {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
  let start = info.kp_proc.p_starttime
  return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
}

/// What a feeding program says it is doing (`state.json`).
public struct FeedState: Decodable, Equatable, Sendable {
  /// "holding" (pictures come while watched), "lent" (to `program`), "waiting" (for the analyzer) or "stopped".
  public let state: String
  public let program: String?
  /// The feeder's process: its pictures count while it runs.
  public let pid: Int32?
  /// The feeder's name, for the window ("Pictures from …").
  public let name: String?

  /// The feeder, when one runs: its state says so and its process is alive.
  public static func current() -> FeedState? {
    guard let data = try? Data(contentsOf: Integration.stateFile),
      let feed = try? JSONDecoder().decode(FeedState.self, from: data),
      feed.state != "stopped", let pid = feed.pid, isRunning(pid, wrote: Integration.stateFile)
    else { return nil }
    return feed
  }

  /// Tells a feeder someone is watching (every second while the window is open).
  public static func touchWatching() {
    let manager = FileManager.default
    let path = Integration.watchingFile.path
    if manager.fileExists(atPath: path) {
      try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    } else {
      try? manager.createDirectory(at: Integration.feedFolder, withIntermediateDirectories: true)
      manager.createFile(atPath: path, contents: Data())
    }
  }

  /// No one watches any more: the feeder can stop making pictures at once.
  public static func stopWatching() {
    try? FileManager.default.removeItem(at: Integration.watchingFile)
  }

  /// The latest picture and when it was made, when there is one.
  public static func picture(newerThan known: Date?) -> (CGImage, Date)? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: Integration.pictureFile.path)
    guard let modified = attributes?[.modificationDate] as? Date, modified != known,
      let source = CGImageSourceCreateWithURL(
        Integration.pictureFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return (image, modified)
  }
}
