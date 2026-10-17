import Foundation
import TinySAKit

/// The command line: `tinysa-screen record --seconds 30 --output spectrum.gif`, and capture, screenshot, status. With
/// the app open, the app does it (it has the analyzer, and the seconds it keeps); without, the command line does it
/// alone, sharing the analyzer as the app would (borrowing and feeding included), without a window.
enum CommandLineTool {
  static let commands = ["record", "capture", "screenshot", "sweep", "peaks", "status", "help"]

  static let usage = """
    tinySA Screen: the screen of a tinySA spectrum analyzer, live on the Mac.

    Usage:
      tinysa-screen                     open the app
      tinysa-screen record --seconds N --output FILE.gif [options]
                                        record the screen for N seconds (1 to 120) as an animated GIF
      tinysa-screen capture [--seconds N] --output FILE.gif [options]
                                        save the last N seconds the open app keeps (all of them without --seconds)
      tinysa-screen screenshot --output FILE.png [--sharp] [--json]
                                        save the screen as it is now
      tinysa-screen sweep [--start F --stop F] [--json]
                                        the span the tinySA sweeps, or set it (a tinySA Ultra on USB)
      tinysa-screen peaks [--seconds N] [--count N] [--json]
                                        the highest peaks of the live trace over N seconds (10), read from the
                                        screen: the analyzer is asked nothing
      tinysa-screen status [--json]     what tinySA Screen sees: the analyzer, a program feeding pictures, the
                                        seconds it keeps

    Options:
      -s, --seconds N     how long (record, peaks), or how many of the kept seconds (capture)
      --count N           peaks: how many (5; at most 9)
      -o, --output FILE   where to save it; an existing file is replaced
      --small             the GIF at the screen's own size (480 × 320 for a tinySA Ultra); the default is twice that
      --sharp             the screenshot at twice the screen's size; the default is its own size
      --no-date           no date under the screen in the GIF
      --no-time           no time under the screen in the GIF
      --start F --stop F  record: sweep this span while recording, and put the tinySA's own back afterwards;
                          sweep: set it. Frequencies like 902M, 2.4G, 433.92MHz or 915000000
      --keep-span         record: leave the tinySA on the span afterwards
      --name NAME         who is asking, shown in the app's window while it records
      --json              the result as one line of JSON, for programs: {"ok": true, "file": ..., "seconds": ...}
      -h, --help          this help
      --version           the version

    With the app open, the app records (its window says so); without, the command line uses the analyzer itself, or the
    pictures of a program that feeds them, and lets go when done. A recording starts only from a live picture: when
    none comes within 15 seconds it fails with the reason. Exit status: 0 done, 1 failed, 2 wrong usage.

    Examples:
      tinysa-screen record -s 30 -o ~/Desktop/band.gif
      tinysa-screen record -s 20 --start 2.4G --stop 2.4835G -o wifi.gif
      tinysa-screen capture -s 15 -o last15.gif --json
      tinysa-screen peaks -s 30 --json
      tinysa-screen screenshot -o screen.png

    More: https://github.com/tolgabalci/tinysa-screen/blob/main/docs/COMMAND-LINE.md
    """

  /// Whether the arguments ask for the command line rather than the app: anything but the arguments macOS (or Xcode)
  /// gives an app it opens, "-psn_…", and "-NS…" or "-Apple…" with a value.
  static func isAsked(_ arguments: [String]) -> Bool {
    var args = arguments.dropFirst()[...]
    while let arg = args.first {
      args = args.dropFirst()
      if arg.hasPrefix("-psn_") { continue }
      if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
        args = args.dropFirst()  // its value
        continue
      }
      return true
    }
    return false
  }

  /// Runs the command line: the exit status.
  static func run(_ arguments: [String]) -> Int32 {
    var args = Array(arguments.dropFirst())
    // The command may come after options ("--json status"): it's the first word that is one.
    let command: String
    if let at = args.firstIndex(where: { commands.contains($0) || ["-h", "--help", "--version"].contains($0) }) {
      command = args.remove(at: at)
    } else {
      return fail("Which command: record, capture, screenshot, sweep, peaks or status (tinysa-screen --help)")
    }
    if ["help", "-h", "--help"].contains(command) {
      print(usage)
      return 0
    }
    if command == "--version" {
      print("tinySA Screen \(version)")
      return 0
    }
    guard commands.contains(command) else { return fail("Unknown command \"\(command)\" (tinysa-screen --help)") }

    var request = ControlRequest(command: command)
    var json = false
    var sharp = false
    while !args.isEmpty {
      let arg = args.removeFirst()
      func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
      switch arg {
      case "-s", "--seconds":
        guard let text = value(), let seconds = Double(text) else { return fail("--seconds needs a number") }
        request.seconds = seconds
      case "-o", "--output":
        guard let path = value() else { return fail("--output needs a file") }
        request.output = absolute(path)
      case "--small": request.scale = 1
      case "--sharp": sharp = true
      case "--no-date": request.date = false
      case "--no-time": request.time = false
      case "--name":
        guard let name = value() else { return fail("--name needs a name") }
        request.name = name
      case "--start", "--stop":
        guard let text = value(), let hertz = Frequency.parse(text) else {
          return fail("\(arg) needs a frequency, such as 902M or 2.4G")
        }
        if arg == "--start" { request.start = hertz } else { request.stop = hertz }
      case "--keep-span": request.restore = false
      case "--count":
        guard let text = value(), let count = Int(text), (1...9).contains(count) else {
          return fail("--count needs a number from 1 to 9")
        }
        request.count = count
      case "--json": json = true
      case "-h", "--help":
        print(usage)
        return 0
      default:
        if request.seconds == nil, let seconds = Double(arg), ["record", "capture", "peaks"].contains(command) {
          request.seconds = seconds
        } else {
          return fail("Unknown option \"\(arg)\" (tinysa-screen --help)")
        }
      }
    }
    if command == "screenshot" { request.scale = sharp ? 2 : 1 }
    if command == "record", request.seconds == nil { return fail("How long to record: --seconds N") }
    if let seconds = request.seconds {
      switch command {
      case "record", "capture":
        guard (1...FrameRecorder.longest).contains(seconds) else {
          return fail("--seconds: 1 to \(Int(FrameRecorder.longest))")
        }
      case "peaks": break  // checked below
      default: return fail("--seconds goes with record, capture and peaks")
      }
    }
    if let start = request.start, let stop = request.stop, start >= stop {
      return fail("The span's start must be below its stop")
    }
    if !["status", "sweep", "peaks"].contains(command), request.output == nil {
      return fail("Where to save it: --output FILE")
    }
    if command == "peaks", let seconds = request.seconds, !(1...600).contains(seconds) {
      return fail("--seconds: 1 to 600")
    }
    if (request.start == nil) != (request.stop == nil) { return fail("A span needs both --start and --stop") }
    if (request.start != nil || request.restore != nil), !["record", "sweep"].contains(command) {
      return fail("--start, --stop and --keep-span go with record and sweep")
    }
    if request.name == nil { request.name = "the command line" }

    let reply = carryOut(request)
    if json {
      print(reply.line())
    } else if reply.ok {
      print(describe(reply, command: command))
    } else {
      FileHandle.standardError.write(Data("tinysa-screen: \(reply.error ?? "failed")\n".utf8))
    }
    return reply.ok ? 0 : 1
  }

  /// The open app's answer, or the command line's own.
  static func carryOut(_ request: ControlRequest) -> ControlReply {
    let timeout = (request.seconds ?? 0) + 120
    do {
      if let reply = try ControlClient.send(request, timeout: timeout) { return reply }
    } catch {
      return .failure("tinySA Screen's answer couldn't be read: \(error.localizedDescription)")
    }
    let session = Session()
    let automation = Automation(session: session, isApp: false, version: version)
    guard ["record", "screenshot", "sweep", "peaks"].contains(request.command) else {
      return automation.handle(request)
    }
    // Control-C or kill: stop waiting, let go of the analyzer properly, then exit.
    let interrupted = Flag()
    let signals = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { interrupted.set() }
      source.resume()
      return source
    }
    session.start()
    let reply = automation.handle(request) { interrupted.isSet }
    session.stop()
    withExtendedLifetime(signals) {}
    return reply
  }

  static func describe(_ reply: ControlReply, command: String) -> String {
    var lines: [String] = []
    switch command {
    case "status":
      lines.append(statusText(reply))
    case "peaks":
      let span = reply.sweep.map { ", \($0.label)" } ?? ""
      lines.append("Peaks over \(Int(reply.seconds ?? 0)) s" + (reply.source.map { " of \($0)" } ?? "") + span + ":")
      let resolution = Double(reply.resolution?.hertz ?? 0)
      let decibels = reply.resolution?.decibels ?? 1
      for (n, peak) in (reply.peaks ?? []).enumerated() {
        let frequency = String(
          format: "%.\(max(0, min(6, Int((-log10(max(resolution, 1) / 1e6)).rounded(.up)))))f MHz",
          Double(peak.frequency) / 1e6)
        let level = decibels < 0.25 ? String(format: "%.1f", peak.level) : String(format: "%.0f", peak.level)
        lines.append("\(n + 1)  \(frequency)  \(level) dBm")
      }
      if reply.peaks?.isEmpty == true, reply.notes == nil { lines.append("None: the trace stayed within 6 dB of its noise.") }
      if let resolution = reply.resolution {
        lines.append(
          "(Read from the screen: \(Frequency.format(resolution.hertz)) and \(resolution.decibels) dB a pixel.)")
      }
    case "sweep":
      if let now = reply.sweep {
        let points = now.points.map { " (\($0) points)" } ?? ""
        lines.append(
          "The tinySA sweeps \(now.label)\(points)" + (reply.previousSweep.map { ", was \($0.label)" } ?? "") + ".")
      }
    case "screenshot":
      lines.append(
        "Saved \(reply.file ?? ""): \(reply.width ?? 0) × \(reply.height ?? 0)"
          + (reply.source.map { ", \($0)" } ?? ""))
    default:
      let size = ByteCountFormatter.string(fromByteCount: Int64(reply.bytes ?? 0), countStyle: .file)
      let seconds = String(format: "%.1f", reply.seconds ?? 0)
      lines.append(
        "Saved \(reply.file ?? ""): \(seconds) s" + (reply.source.map { " of \($0)" } ?? "")
          + ", \(reply.frames ?? 0) frames, \(reply.width ?? 0) × \(reply.height ?? 0), \(size)")
    }
    lines += (reply.notes ?? []).map { "Note: \($0)" }
    return lines.joined(separator: "\n")
  }

  static func statusText(_ reply: ControlReply) -> String {
    var lines: [String] = []
    if reply.app == true {
      if reply.picture == true {
        lines.append(
          "tinySA Screen \(reply.version ?? "") is open: \(reply.source ?? "a picture")"
            + (reply.usb == true ? ", live over USB." : "."))
      } else {
        lines.append("tinySA Screen \(reply.version ?? "") is open, without a picture: \(reply.note ?? "")")
      }
      if let kept = reply.keptSeconds, kept > 0 {
        lines.append("Capture keeps \(Int(kept)) s (\(Int(reply.availableSeconds ?? 0)) s so far).")
      } else {
        lines.append("Capture keeps no seconds (Settings › Keep the latest seconds).")
      }
      if let recordings = reply.recordings, recordings > 0 { lines.append("Recording now: \(recordings).") }
    } else {
      lines.append("tinySA Screen isn't open: record and screenshot use the analyzer from here.")
    }
    let devices = reply.devices ?? []
    lines.append(devices.isEmpty ? "No tinySA on USB." : "On USB: " + devices.joined(separator: ", ") + ".")
    if let feeder = reply.feeder { lines.append("Pictures fed by \(feeder).") }
    if let borrower = reply.borrower { lines.append("Lent to \(borrower).") }
    return lines.joined(separator: "\n")
  }

  static func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).path
  }

  /// The app's version, from the bundle the program is in, also when it's run through a link (Homebrew links it).
  static var version: String {
    let program = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let app = program?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = app.flatMap(Bundle.init(url:)) ?? Bundle.main
    return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(built from source)"
  }

  static func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("tinysa-screen: \(message)\n".utf8))
    return 2
  }
}

/// A flag set from a signal handler and read from another thread.
final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}
