import AppKit
import Combine
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
  @AppStorage(Preferences.Key.inkSeconds) private var inkSeconds = 3
  @AppStorage(Preferences.Key.peakWindow) private var peakWindow = 60
  @AppStorage(Preferences.Key.peakColor) private var peakColor = PeakColor.cyan.rawValue
  @AppStorage(Preferences.Key.peakCount) private var peakCount = 5
  @AppStorage(Preferences.Key.savedBands) private var savedBandsData = Data()
  @AppStorage(Preferences.Key.saveFolderPath) private var saveFolderPath = ""
  @AppStorage(Preferences.Key.saveFolderBookmark) private var saveFolderBookmark = Data()

  private enum SaveChoice: Hashable { case desktop, chosen, other }
  /// Every two seconds: the folder can go (a drive unplugged) or come back while Settings is open.
  @State private var folderCheck = 0

  private var saveFolder: SaveFolder {
    SaveFolder(
      bookmark: saveFolderBookmark.isEmpty ? nil : saveFolderBookmark, path: saveFolderPath.isEmpty ? nil : saveFolderPath)
  }

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
        Text("Record (⌘R) saves GIFs this way, for up to two minutes; Capture starts from these choices.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      saving
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
        Text("The pointer (⌘L) and the pen (⌘D) take the mouse while they're on, for presenting in a call; Esc ends them.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, idealWidth: 480, maxWidth: 640, minHeight: 320, idealHeight: 620)
    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in folderCheck += 1 }
  }

  /// Where GIFs and screenshots go: the Desktop, or a folder chosen with Other….
  private var saving: some View {
    _ = folderCheck  // looked at again with each check
    let folder = saveFolder
    let place = folder.place()
    return Section {
      Picker(
        "Save to",
        selection: Binding<SaveChoice>(
          get: { folder.isDesktop ? .desktop : .chosen },
          set: { choice in
            switch choice {
            case .desktop: Preferences.saveFolder = .desktop
            case .chosen: break
            case .other: DispatchQueue.main.async { SaveFolderPanel.choose() }  // after the menu has closed
            }
          })
      ) {
        Text("Desktop").tag(SaveChoice.desktop)
        if !folder.isDesktop {
          Text(place.missing.map { "\($0) (not found)" } ?? place.name).tag(SaveChoice.chosen)
        }
        Divider()
        Text("Other…").tag(SaveChoice.other)
      }
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.shortPath(folder.path.map { URL(fileURLWithPath: $0) } ?? place.url))
            .textSelection(.enabled)
          if place.missing != nil {
            Text("Not found, so they go to the Desktop until it's back.")
          }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Show in Finder") { NSWorkspace.shared.open(place.url) }
          .help("Open the folder GIFs and screenshots go to")
      }
    } header: {
      Text("Saving")
    } footer: {
      Text(
        "GIFs (Record and Capture) and screenshots (⌘S) are saved here, named after when they start. A folder that's moved or renamed is followed there; while it can't be found (on a drive that's unplugged, say), files go to the Desktop."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
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

  /// A path with the home folder as ~, as Finder's Go to Folder takes it.
  static func shortPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}

/// The folder panel for Settings › Save to › Other….
@MainActor
enum SaveFolderPanel {
  static func choose() {
    let panel = NSOpenPanel()
    panel.title = "Save GIFs and Screenshots To"
    panel.message = "Choose the folder tinySA Screen saves GIFs and screenshots in."
    panel.prompt = "Choose"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = Preferences.saveFolder.place().url
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard FileManager.default.isWritableFile(atPath: url.path) else {
      let alert = NSAlert()
      alert.messageText = "tinySA Screen can't save in “\(FileManager.default.displayName(atPath: url.path))”"
      alert.informativeText = "Choose a folder you can add files to."
      alert.runModal()
      return
    }
    do {
      Preferences.saveFolder = try SaveFolder.chosen(url)
    } catch {
      NSAlert(error: error).runModal()
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
