import AppKit
import Combine
import SwiftUI
import TinySAKit

/// Settings (⌘,): how recordings start and stop, how GIFs look, and whether clicks tap the analyzer.
struct SettingsView: View {
  @AppStorage(Preferences.Key.keepRecent) private var keepRecent = true
  @AppStorage(Preferences.Key.keepRecentSeconds) private var keepRecentSeconds = 60
  @AppStorage(Preferences.Key.recordLeadIn) private var recordLeadIn = 5
  @AppStorage(Preferences.Key.recordLongest) private var recordLongest = 120
  @AppStorage(Preferences.Key.gifShowsDate) private var showsDate = true
  @AppStorage(Preferences.Key.gifShowsTime) private var showsTime = true
  @AppStorage(Preferences.Key.gifShowsElapsed) private var showsElapsed = true
  @AppStorage(Preferences.Key.gifScale) private var scale = 2
  @AppStorage(Preferences.Key.gifLoops) private var loops = true
  @AppStorage(Preferences.Key.gifPauseAtEnd) private var pauseAtEnd = 5
  @AppStorage(Preferences.Key.controlEnabled) private var controlEnabled = true
  @AppStorage(Preferences.Key.inkSeconds) private var inkSeconds = 3
  @AppStorage(Preferences.Key.peakWindow) private var peakWindow = 60
  @AppStorage(Preferences.Key.peakColor) private var peakColor = PeakColor.cyan.rawValue
  @AppStorage(Preferences.Key.peakCount) private var peakCount = 5
  @AppStorage(Preferences.Key.savedBands) private var savedBandsData = Data()

  private var savedBands: [BandPreset] { (try? JSONDecoder().decode([BandPreset].self, from: savedBandsData)) ?? [] }

  var body: some View {
    Form {
      recording
      Section {
        Toggle("Date under the screen", isOn: $showsDate)
        Toggle("Time under the screen, to the second", isOn: $showsTime)
        Toggle("Time into the GIF and its length under the screen (0:10 / 2:30)", isOn: $showsElapsed)
        Picker("Resolution", selection: $scale) {
          Text("Sharp: twice the screen's size").tag(2)
          Text("Small: the screen's own size").tag(1)
        }
        Toggle("Play over and over", isOn: $loops)
        Stepper(value: $pauseAtEnd, in: 0...10) {
          HStack {
            Text("Pause at the end")
            Spacer()
            Text(pauseAtEnd == 0 ? "None" : "\(pauseAtEnd) s").monospacedDigit().foregroundStyle(.secondary)
          }
        }
        .accessibilityValue(pauseAtEnd == 0 ? "None" : "\(pauseAtEnd) seconds")
      } header: {
        Text("GIFs")
      } footer: {
        Text(
          "Stop & Save makes GIFs this way. The editor that Stop opens starts with them, and changes them too. A "
            + "pause longer than a second says \"End of recording\" under the screen. GIFs and screenshots (⌘S) go to "
            + "the folder the editor last saved to (its Save to), the Desktop at first.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Picker("Hold each level", selection: $peakWindow) {
          ForEach(Preferences.peakWindows, id: \.self) { seconds in
            Text(Self.holding(seconds)).tag(seconds)
          }
        }
        Picker("Color", selection: $peakColor) {
          ForEach(PeakColor.allCases) { color in
            Label {
              Text(color.name)
            } icon: {
              Image(nsImage: color.swatch)
            }
            .tag(color.rawValue)
          }
        }
        Stepper(value: $peakCount, in: 0...9) {
          HStack {
            Text("Peaks labeled")
            Spacer()
            Text("\(peakCount)").monospacedDigit().foregroundStyle(.secondary)
          }
        }
        .accessibilityValue("\(peakCount) peaks")
      } header: {
        Text("Peak hold")
      } footer: {
        Text(
          "Peak hold (⌥⌘P) reads the analyzer's live trace from its screen after each sweep, so the analyzer's own settings stay as they are. Levels are as fine as the screen's pixels: half a decibel at 10 dB a division. View › Hold Peaks For sets how long too. Cyan is the one color none of the analyzer's own traces has (yellow, green, red and magenta), so the held line never passes for one of them."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        if savedBands.isEmpty {
          Text("None yet. Band › Save Current Span as a Band adds the span the tinySA sweeps.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(savedBands) { band in
          HStack {
            Text(band.name)
            Spacer()
            Text(band.range.label).foregroundStyle(.secondary)
            Button {
              savedBandsData = (try? JSONEncoder().encode(savedBands.filter { $0 != band })) ?? Data()
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this band")
            .accessibilityLabel("Remove \(band.name)")
          }
        }
      } header: {
        Text("Your bands")
      }
      Section {
        Toggle("Clicks on the picture tap the tinySA", isOn: $controlEnabled)
        Stepper(value: $inkSeconds, in: 1...30) {
          HStack {
            Text("Pen strokes fade after")
            Spacer()
            Text("\(inkSeconds) s").monospacedDigit().foregroundStyle(.secondary)
          }
        }
        .accessibilityValue("\(inkSeconds) seconds")
      } header: {
        Text("Clicks")
      } footer: {
        Text(
          "Clicks reach the tinySA over USB, and through a program that feeds the pictures when it passes them on. "
            + "The pointer (⌘L) and the pen (⌘D) take the mouse while they're on, for presenting in a call; Esc ends "
            + "them.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, idealWidth: 480, maxWidth: 640, minHeight: 320, idealHeight: 620)
  }

  /// How far back a recording starts, how far back the editor can take it, and how long it runs.
  private var recording: some View {
    let kept = keepRecent ? min(max(keepRecentSeconds, 5), Int(FrameRecorder.longestAllowed)) : 0
    let keptChoices = Set(Self.keptChoices + (kept > 0 ? [kept] : [])).sorted()
    let leadIns = Self.leadInChoices.filter { $0 <= kept }
    return Section {
      Picker(
        "Keep in memory",
        selection: Binding(
          get: { kept },
          set: { seconds in
            keepRecent = seconds > 0
            if seconds > 0 { keepRecentSeconds = seconds }
          })
      ) {
        Text("Nothing").tag(0)
        ForEach(keptChoices, id: \.self) { Text("The last \(Self.spoken($0))").tag($0) }
      }
      Picker(
        "Start recordings",
        selection: Binding(get: { leadIns.last { $0 <= recordLeadIn } ?? 0 }, set: { recordLeadIn = $0 })
      ) {
        ForEach(leadIns, id: \.self) { seconds in
          Text(seconds == 0 ? "When Record is pressed" : "\(Self.spoken(seconds)) before Record").tag(seconds)
        }
      }
      .disabled(kept == 0)
      Picker(
        "Stop recordings after",
        selection: Binding(
          get: { Self.longestChoices.last { $0 <= recordLongest } ?? Self.longestChoices[0] },
          set: { recordLongest = $0 })
      ) {
        ForEach(Self.longestChoices, id: \.self) { Text(Self.spoken($0)).tag($0) }
      }
    } header: {
      Text("Recording")
    } footer: {
      Text(
        "The latest seconds stay in memory only, so a recording can start before Record (⌘R) is pressed. Stop opens "
          + "the editor, where the GIF can start as far back as they go and either end can be trimmed; ⌥ Stop & Save "
          + "(⌥⌘R) saves it as it is."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The latest seconds Settings offers to keep, the lead-ins, and the longest recordings.
  static let keptChoices = [15, 30, 60, 120, 180, 300]
  static let leadInChoices = [0, 2, 5, 10, 15, 30, 60, 120, 180, 300]
  static let longestChoices = [60, 120, 180, 240, 300]

  /// "2 seconds", "1 minute", "5 minutes", "90 seconds".
  static func spoken(_ seconds: Int) -> String {
    guard seconds >= 60, seconds % 60 == 0 else { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
    return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
  }

  /// "Until cleared", "For 10 seconds", "For 1 minute"…
  static func holding(_ seconds: Int) -> String {
    switch seconds {
    case 0: return "Until cleared"
    case ..<60: return "For \(seconds) seconds"
    case 60: return "For 1 minute"
    default: return "For \(seconds / 60) minutes"
    }
  }

  /// The same as menu items (View › Hold Peaks For): "Until Cleared", "10 Seconds", "1 Minute"…
  static func holdingTitle(_ seconds: Int) -> String {
    switch seconds {
    case 0: return "Until Cleared"
    case ..<60: return "\(seconds) Seconds"
    case 60: return "1 Minute"
    default: return "\(seconds / 60) Minutes"
    }
  }
}


/// The Settings window, made when first opened.
@MainActor
final class SettingsWindow {
  static let shared = SettingsWindow()
  private var window: NSWindow?

  func show() {
    if window == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
      window.title = "tinySA Screen Settings"
      // Resizable and scrolling: all of it is taller than a small display.
      window.styleMask = [.titled, .closable, .resizable]
      window.isReleasedWhenClosed = false
      let visible = NSScreen.main?.visibleFrame.height ?? 800
      window.setContentSize(NSSize(width: 480, height: min(620, visible - 80)))
      window.center()
      self.window = window
    }
    window?.makeKeyAndOrderFront(nil)
  }
}
