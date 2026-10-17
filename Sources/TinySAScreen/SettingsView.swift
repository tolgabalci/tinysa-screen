import AppKit
import SwiftUI
import TinySAKit

/// Settings (⌘,): what Capture keeps, how GIFs look, and whether clicks tap the analyzer.
struct SettingsView: View {
  @AppStorage(Preferences.Key.keepRecent) private var keepRecent = true
  @AppStorage(Preferences.Key.keepRecentSeconds) private var keepRecentSeconds = 60
  @AppStorage(Preferences.Key.gifShowsDate) private var showsDate = true
  @AppStorage(Preferences.Key.gifShowsTime) private var showsTime = true
  @AppStorage(Preferences.Key.gifScale) private var scale = 2
  @AppStorage(Preferences.Key.controlEnabled) private var controlEnabled = true
  @AppStorage(Preferences.Key.savedBands) private var savedBandsData = Data()

  private var savedBands: [BandPreset] { (try? JSONDecoder().decode([BandPreset].self, from: savedBandsData)) ?? [] }

  var body: some View {
    Form {
      Section {
        Toggle("Keep the latest seconds for Capture", isOn: $keepRecent)
        Stepper(value: $keepRecentSeconds, in: 5...120, step: 5) {
          HStack {
            Text("Seconds kept")
            Spacer()
            Text(CaptureSheet.duration(Double(keepRecentSeconds)))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
        .disabled(!keepRecent)
        .accessibilityValue("\(keepRecentSeconds) seconds")
      } header: {
        Text("Capture")
      } footer: {
        Text(
          "Capture (⇧⌘R) saves these seconds, or the last part of them, as a GIF: for when something has just happened. They're kept in memory only."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Toggle("Date under the screen", isOn: $showsDate)
        Toggle("Time under the screen, to the second", isOn: $showsTime)
        Picker("Size", selection: $scale) {
          Text("Sharp: twice the screen's size").tag(2)
          Text("Small: the screen's own size").tag(1)
        }
      } header: {
        Text("GIFs")
      } footer: {
        Text("Record (⌘R) saves GIFs this way to the Desktop, for up to two minutes; Capture starts from these choices.")
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
      Section("Control") {
        Toggle("Clicks on the picture tap the tinySA", isOn: $controlEnabled)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .fixedSize()
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
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    window?.makeKeyAndOrderFront(nil)
  }
}
