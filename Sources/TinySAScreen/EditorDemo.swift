#if DEBUG
  import AppKit
  import SwiftUI
  import TinySAKit

  /// For working on the editor, in debug builds only: with TINYSA_SCREEN_EDITOR_DEMO set to a folder of PNG screens,
  /// the app opens the editor on its own, on a made-up recording of them (a minute kept before Record, ten seconds
  /// after), without the analyzer, the control socket or the app's window. With TINYSA_SCREEN_EDITOR_SNAPSHOTS set to
  /// a folder too, it saves pictures of the editor in a few states there and quits.
  @MainActor
  enum EditorDemo {
    /// Where the strip is in the editor's window, top-down as SwiftUI has it, for the script's drags.
    static var strip: CGRect?
    /// Each picture of the frame at the playhead made: when, how long it took, and the second it shows.
    static var renders: [(at: Date, took: TimeInterval, second: Double)] = []

    static func runIfAsked() -> Bool {
      if Showcase.editorIfAsked() { return true }
      let environment = ProcessInfo.processInfo.environment
      if let folder = environment["TINYSA_SCREEN_RECORD_DEMO"],
        let out = environment["TINYSA_SCREEN_EDITOR_SNAPSHOTS"]
      {
        recordDemo(screens: URL(fileURLWithPath: folder), out: URL(fileURLWithPath: out))
        return true
      }
      guard let folder = environment["TINYSA_SCREEN_EDITOR_DEMO"] else { return false }
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      app.mainMenu = makeMenuBar()
      Preferences.register()
      guard let (clip, began) = recording(from: URL(fileURLWithPath: folder)) else {
        FileHandle.standardError.write(Data("No PNG screens in \(folder)\n".utf8))
        exit(1)
      }
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 760), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      window.title = "Editor demo"
      window.center()
      // On a Retina screen, if there is one, for sharp pictures.
      if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) {
        let frame = retina.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
      }
      window.makeKeyAndOrderFront(nil)
      let model = TrimModel(clip: clip, began: began, trim: Trim(clip, began: began, leadIn: 5))
      let note = environment["TINYSA_SCREEN_EDITOR_NOTE"]
      let editor = EditorWindow(model: model, note: note) { action in
        print("Done: \(action.map { "\($0)" } ?? "cancelled"), \(model.trim.start) to \(model.trim.end)")
        exit(0)
      }
      editor.show(over: window)
      let screen = window.screen?.visibleFrame.size ?? .zero
      print("Editor \(editor.window.contentLayoutRect.size) on a screen of \(screen)")
      if let out = environment["TINYSA_SCREEN_EDITOR_SNAPSHOTS"] {
        snapshots(of: editor.window, model: model, to: URL(fileURLWithPath: out))  // in the background: nothing taken
      } else if #available(macOS 14.0, *) {
        app.activate()
      } else {
        app.activate(ignoringOtherApps: true)
      }
      app.run()
      return true
    }

    /// Record as the window does it, on screens fed live, a frame each half second, GIFs saved to `out` (Settings
    /// changed in memory only): Record and Stop open the editor, its Return saves; Stop & Save saves at once; quitting
    /// saves a recording running. What happened is printed.
    private static func recordDemo(screens folder: URL, out: URL) {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      Preferences.register()
      try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      guard let chosen = try? SaveFolder.chosen(out), let screens = Optional(pictures(in: folder)), !screens.isEmpty
      else { exit(1) }
      Preferences.defaults.register(defaults: [
        Preferences.Key.saveFolderBookmark: chosen.bookmark ?? Data(),
        Preferences.Key.saveFolderPath: chosen.path ?? "",
        Preferences.Key.keepRecentSeconds: 60, Preferences.Key.recordLeadIn: 5,
      ])
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 760), styleMask: [.titled, .closable], backing: .buffered,
        defer: false)
      let view = ScreenView(frame: window.contentLayoutRect)
      window.contentView = view
      window.center()
      window.orderFront(nil)
      let recorder = FrameRecorder()
      recorder.keepRecent = TimeInterval(Preferences.keptSeconds)
      let gifs = GIFController(recorder: recorder, window: window, view: view)
      gifs.onMade = { url in print("Made \(url.lastPathComponent)") }
      var k = 0
      let feed = Timer(timeInterval: 0.5, repeats: true) { _ in
        var screen = screens[(k / 12) % screens.count]
        let x = (k * 3) % max(screen.width - 12, 1)
        for row in 2..<8 {
          for column in x..<(x + 12) { screen.pixels[row * screen.width + column] = UInt32(0xFF00_FFFF).littleEndian }
        }
        recorder.add(screen, at: Date())
        k += 1
      }
      RunLoop.main.add(feed, forMode: .common)
      func files() -> [String] {
        let names = FileManager.default.subpaths(atPath: out.path) ?? []
        return names.filter { $0.hasSuffix(".gif") }.sorted()
      }
      let file = out.appendingPathComponent("not a folder.txt")
      try? Data("x".utf8).write(to: file)
      let newFolder = out.appendingPathComponent("Band GIFs/915 MHz", isDirectory: true)
      func returnKey(_ sheet: NSWindow) {
        if let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
          isARepeat: false, keyCode: 36), !sheet.performKeyEquivalent(with: event)
        {
          print("Return wasn't taken")
        }
      }
      let steps: [(TimeInterval, () -> Void)] = [
        (9, {
          gifs.startRecording()
          print("Recording: \(gifs.isRecording), lead-in \(gifs.leadIn), length \(gifs.length)")
        }),
        (3, {
          print("Length after 3 s: \(gifs.length)")
          gifs.stopRecording()
          print("Editor open: \(gifs.isEditing), windows \(gifs.editorWindows.count), recording \(gifs.isRecording)")
        }),
        (1.5, {
          guard let editor = gifs.editorWindows.first, let model = gifs.editorModels.first else { return }
          print("Save to shows \(model.folder), can save \(model.canSave)")
          model.folder = file.path
          print("A file typed: \(model.folderStatus), can save \(model.canSave)")
          returnKey(editor)
        }),
        (1, {
          guard let editor = gifs.editorWindows.first, let model = gifs.editorModels.first else {
            print("The editor closed: Return saved to a file?")
            return
          }
          print("Return with a file typed: editor open \(gifs.isEditing), files \(files())")
          model.folder = SaveFolder.shortPath(newFolder)
          print("A new folder typed (\(model.folder)): \(model.folderStatus), can save \(model.canSave)")
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let image = picture(of: editor) {
              let url = out.appendingPathComponent("editor.png")
              try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
            returnKey(editor)
          }
        }),
        (3, {
          print("After Return: editor \(gifs.isEditing), files \(files())")
          print("Kept for next time: \(Preferences.saveFolder.path ?? "the Desktop")")
          gifs.startRecording()
        }),
        (2, {
          gifs.toggleRecording(andSave: true)
          print("Stop & Save: editor \(gifs.isEditing), recording \(gifs.isRecording)")
        }),
        (3, {
          print("Files \(files())")
          gifs.startRecording()
        }),
        (2, {
          gifs.finish {
            print("Quit saved it: files \(files())")
            // The demo leaves nothing kept.
            Preferences.defaults.removeObject(forKey: Preferences.Key.saveFolderBookmark)
            Preferences.defaults.removeObject(forKey: Preferences.Key.saveFolderPath)
            exit(0)
          }
        }),
      ]
      func run(_ index: Int) {
        guard index < steps.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].0) {
          steps[index].1()
          run(index + 1)
        }
      }
      run(0)
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("Timed out")
        exit(1)
      }
      app.run()
    }

    /// The app's window with TINYSA_SCREEN_WINDOW_DEMO set to a PNG screen, without the analyzer or the control socket,
    /// pictured into TINYSA_SCREEN_EDITOR_SNAPSHOTS: behind other apps' windows, and in front (AppKit told to draw it
    /// so: the app is never brought forward, nobody's typing is taken), with the link to a GIF just made as it pulses
    /// and after, and at its narrowest. Then the app quits.
    static func window(
      _ window: NSWindow, screen: URL, show: (CGImage) -> Void, made: @escaping (URL) -> Void,
      peaks: @escaping (PeakHold.State?) -> Void, ring: @escaping (Int?) -> Void
    ) {
      guard let folder = ProcessInfo.processInfo.environment["TINYSA_SCREEN_EDITOR_SNAPSHOTS"],
        let source = CGImageSourceCreateWithURL(screen as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { exit(1) }
      let out = URL(fileURLWithPath: folder)
      try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      show(image)
      window.setContentSize(NSSize(width: 960, height: 640))
      func save(_ name: String) {
        guard let picture = picture(of: window) else { return print("No picture of \(name)") }
        let url = out.appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])?.write(to: url)
        print("Pictured \(name): \(Int(window.frame.width)) × \(Int(window.frame.height)) points")
      }
      func settingsWindow() -> NSWindow? { NSApp.windows.first { $0.title == "tinySA Screen Settings" } }
      // Settings scrolled `down` points from its top (its form scrolls).
      func scrollSettings(_ down: CGFloat) {
        func scroller(in view: NSView) -> NSScrollView? {
          view as? NSScrollView ?? view.subviews.lazy.compactMap { scroller(in: $0) }.first
        }
        guard let content = settingsWindow()?.contentView, let scroll = scroller(in: content),
          let document = scroll.documentView
        else { return print("Settings doesn't scroll") }
        let room = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let y = document.isFlipped ? min(down, room) : max(0, room - down)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      func saveSettings(_ name: String) {
        guard let settings = settingsWindow(), let picture = picture(of: settings) else {
          return print("No picture of \(name)")
        }
        let url = out.appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])?.write(to: url)
        print("Pictured \(name): \(Int(settings.frame.width)) × \(Int(settings.frame.height)) points")
      }
      let steps: [(TimeInterval, () -> Void)] = [
        (1.2, { save("window-behind") }),
        (0.1, {
          drawInFront(window)
          ToolbarLook.drawnInFront = true
          ToolbarLook.redraw(window.toolbar)
        }),
        (0.8, { save("window-in-front") }),
        (0.1, { made(out.appendingPathComponent("tinySA 2026-11-27 at 22.15.00.gif")) }),
        (0.45, { save("link-pulse-a") }),
        (0.3, { save("link-pulse-b") }),
        (0.75, { save("link-pulse-c") }),
        (4, { save("link-after") }),
        // The peak hold on, its peaks listed beside the screen: a hold read from the screen, its labels as if read.
        (0.1, {
          Preferences.defaults.set(PeakDisplay.list.rawValue, forKey: Preferences.Key.peakDisplay)
          Preferences.defaults.set(true, forKey: Preferences.Key.peakHold)
        }),
        (0.5, { peaks(held(Snapshot(image)!, count: 4)) }),
        (0.8, { save("list") }),
        (0.1, { ring(2) }),
        (0.6, { save("list-ring") }),
        (0.1, {
          ring(nil)
          peaks(held(Snapshot(image)!, count: 6))
        }),
        (0.8, { save("list-more") }),
        (0.1, { Preferences.defaults.set(PeakDisplay.labels.rawValue, forKey: Preferences.Key.peakDisplay) }),
        (0.8, { save("labels") }),
        // Settings, tall enough for all of it (past the screen's foot if need be): the labels' colour, then greyed
        // with the peaks in a box.
        (0.1, {
          SettingsWindow.shared.show()
          settingsWindow()?.setContentSize(NSSize(width: 480, height: 1900))
        }),
        (1.0, { scrollSettings(640) }),
        (0.6, { saveSettings("settings") }),
        (0.1, { Preferences.defaults.set(PeakDisplay.box.rawValue, forKey: Preferences.Key.peakDisplay) }),
        (0.8, { saveSettings("settings-box") }),
        (0.1, {
          settingsWindow()?.close()
          Preferences.defaults.set(false, forKey: Preferences.Key.peakHold)
          window.setContentSize(NSSize(width: 480, height: 320))
        }),
        (0.9, {
          save("window-narrowest")
          exit(0)
        }),
      ]
      func run(_ index: Int) {
        guard index < steps.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].0) {
          steps[index].1()
          run(index + 1)
        }
      }
      run(0)
    }

    /// `window` drawn as the window in front is, by AppKit's own switches for it, though the app never comes forward:
    /// so a picture shows what the user sees, and nobody's typing is taken.
    static func drawInFront(_ window: NSWindow, again: Bool = false) {
      for name in ["_setForceActiveControls:", "_setForceMainAppearance:", "_setHasActiveAppearance:"] {
        let selector = NSSelectorFromString(name)
        guard window.responds(to: selector) else {
          print("AppKit has no \(name)")
          continue
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let set = unsafeBitCast(window.method(for: selector), to: Setter.self)
        if again { set(window, selector, false) }  // AppKit passes over the same value set twice
        set(window, selector, true)
      }
      window.contentView?.superview?.needsDisplay = true  // the frame, the toolbar with it
      for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(kind)?.needsDisplay = true  // their colours, in front
      }
    }

    /// The hold of `screen`, its labels as if read (902 to 928 MHz, +10 dBm at the top, 10 dB a division of 24
    /// rows), its `count` highest peaks numbered, a few seconds apart.
    private static func held(_ screen: Snapshot, count: Int) -> PeakHold.State? {
      // Bursts in the live (yellow) trace: humps, a burst a few columns wide each, some side by side.
      var screen = screen
      let yellow = UInt32(0xFF00_FFFF).littleEndian
      let humps = [(80, 60, 9), (100, 70, 8), (180, 50, 10), (205, 58, 9), (300, 64, 10), (390, 90, 8)]
      for (center, top, half) in humps.prefix(count) {
        for x in (center - half)...(center + half) {
          let fraction = Double(x - center) / Double(half)
          let row = top + Int(fraction * fraction * Double(200 - top))
          for y in row...min(row + 1, screen.height - 1) { screen.pixels[y * screen.width + x] = yellow }
        }
      }
      let hold = PeakHold()
      hold.add(screen, at: Date())
      guard var state = hold.state else { return nil }
      state.scale = GraphScale(level0: 10, perRow: -10.0 / 24, start: 902_000_000, stop: 928_000_000)
      state.peaks = PeakHold.peaks(in: state, count: count).enumerated().map { i, peak in
        var peak = peak
        peak.number = i + 1
        peak.time = Date().addingTimeInterval(Double(i * 7 - 60))
        return peak
      }
      return state
    }

    private static func pictures(in folder: URL) -> [Snapshot] {
      let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }.compactMap { url in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return Snapshot(image)
      }
    }

    /// Seventy seconds of the screens in turn, a frame each half second, a block moving along the top so that each
    /// differs; Record pressed at 60 s.
    private static func recording(from folder: URL) -> (Clip, Date)? {
      let screens = pictures(in: folder)
      guard let first = screens.first else { return nil }
      let sized = screens.filter { $0.width == first.width && $0.height == first.height }
      let recorder = FrameRecorder()
      recorder.keepRecent = 300
      let zero = Date().addingTimeInterval(-70)
      var id: UUID?
      // A peak hold on, as live: a burst every 8 seconds somewhere else, the labels as if read.
      let hold = PeakHold(readsLabels: false)
      hold.window = 60
      let scale = GraphScale(level0: 10, perRow: -10.0 / 24, start: 902_000_000, stop: 928_000_000)
      let yellow = UInt32(0xFF00_FFFF).littleEndian
      for k in 0...140 {
        if (124..<130).contains(k), id != nil { continue }  // 62 to 65 s: no picture, as when the analyzer stalls
        let time = zero.addingTimeInterval(Double(k) / 2)
        var screen = sized[(k / 12) % sized.count]
        let x = (k * 3) % max(screen.width - 12, 1)
        for row in 2..<8 {
          for column in x..<(x + 12) { screen.pixels[row * screen.width + column] = yellow }
        }
        let (center, top) = (60 + ((k / 16) * 53) % 360, 70 + (k / 16 % 3) * 15)
        for column in (center - 8)...(center + 8) where column > 31 && column < screen.width {
          let fraction = Double(column - center) / 8
          let row = top + Int(fraction * fraction * Double(200 - top))
          screen.pixels[row * screen.width + column] = yellow
        }
        recorder.add(screen, at: time)
        hold.know(scale, for: screen)
        hold.add(screen, at: time)
        recorder.notePeaks(hold.state, at: time)
        if k == 120 { id = recorder.begin(at: time, before: 300, longest: 300) }
      }
      guard let id, let began = recorder.started(id), let clip = recorder.end(id, at: zero.addingTimeInterval(70))
      else { return nil }
      return (clip, began)
    }

    /// The editor driven as a person would, with mouse and key events, and pictured after each step: as it opens,
    /// playing, with its start dragged back, with the playhead stepped and the end set there, after ⌘Z, and asking
    /// before Cancel deletes the recording.
    private static func snapshots(of sheet: NSWindow, model: TrimModel, to folder: URL) {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      func picture(_ name: String) {
        if let image = Self.picture(of: sheet) {
          let url = folder.appendingPathComponent("\(name).png")
          try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        print("\(name): start \(model.trim.start.timeIntervalSince(model.clip.start)), end "
          + "\(model.trim.end.timeIntervalSince(model.clip.start)), playhead "
          + "\(model.playhead.timeIntervalSince(model.clip.start)), playing \(model.isPlaying)")
      }
      func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          guard
            let event = NSEvent.keyEvent(
              with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: sheet.windowNumber, context: nil, characters: characters,
              charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
          else { continue }
          if type == .keyDown, let target = NSApp.windows.last(where: { $0.isVisible && $0.sheetParent === sheet })
            ?? Optional(sheet), target.performKeyEquivalent(with: event)
          {
            continue
          }
          (NSApp.windows.last { $0.isVisible && $0.sheetParent === sheet } ?? sheet).sendEvent(event)
        }
      }
      /// Straight to the view under the mouse: the window would take a first click in an app that isn't in front
      /// to bring it there, and the demo leaves you where you are.
      var pressed: NSView?
      // An event at a moment of its own (seconds since startup): a person's clicks keep their times while the Mac is
      // busy handling the first.
      func mouse(_ type: NSEvent.EventType, _ point: NSPoint, at moment: TimeInterval? = nil) {
        guard
          let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: moment ?? ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
          let content = sheet.contentView
        else { return }
        switch type {
        case .leftMouseDown:
          pressed = content.hitTest(content.convert(point, from: nil))
          pressed?.mouseDown(with: event)
        case .leftMouseDragged: pressed?.mouseDragged(with: event)
        default:
          pressed?.mouseUp(with: event)
          pressed = nil
        }
      }
      let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
      let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
      var steps: [(TimeInterval, () -> Void)] = [
        (3, { picture("1-opened") }),
        (0.1, { drawInFront(sheet) }),
        (0.8, { picture("1b-in-front") }),
        (0.1, {
          renders.removeAll()
          key(" ", 49)
        }),
        (12, {
          picture("2-playing")
          // The clock as the picture showed it while playing: each new second, when it came after the one before.
          let seconds = renders.enumerated().filter {
            $0.offset == 0 || $0.element.second != renders[$0.offset - 1].second
          }
          let gaps = zip(seconds, seconds.dropFirst()).map { $1.element.at.timeIntervalSince($0.element.at) }
          let took = renders.map(\.took)
          print(String(format: "Playing: %d pictures made, %.1f ms each at most, %.1f on average",
            renders.count, (took.max() ?? 0) * 1000, took.reduce(0, +) / Double(max(took.count, 1)) * 1000))
          print("New seconds came after: " + gaps.map { String(format: "%.2f", $0) }.joined(separator: " "))
        }),
        (0.1, { key(" ", 49) }),
        // Seconds no picture came in: the strip pink.
        (0.3, { model.seek(to: model.clip.start.addingTimeInterval(63.5)) }),
        (1, { picture("3a-no-pictures") }),
        // Ten times faster, every frame; then two frames a second, played to its end, then held there, saying so.
        (0.1, { model.speed = 10 }),
        (1, { picture("3b0-fast-full") }),
        (0.1, {
          model.speed = 10
          model.framesPerSecond = 2
          model.seek(to: model.trim.start)
          model.play()
        }),
        (3, { picture("3b-fast-end-pause") }),
        (0.1, {
          model.pause()
          model.speed = 1
        }),
      ]
      // The start handle, dragged 250 points back, a few points at a time.
      var from = NSPoint.zero
      steps.append((0.3, {
        // The start handle's middle: the GIF's start, half a handle to the left. SwiftUI's global space runs down from
        // the window's top, title bar and all.
        if let strip = EditorDemo.strip, case let height = sheet.frame.height {
          let inner = strip.width - 2 * TrimStrip.handle
          let fraction = model.trim.start.timeIntervalSince(model.clip.start) / model.total
          from = NSPoint(
            x: strip.minX + TrimStrip.handle + inner * CGFloat(fraction) - TrimStrip.handle / 2, y: height - strip.midY)
        }
        print("Strip \(EditorDemo.strip.map { "\($0)" } ?? "unknown"), the GIF's start at \(from)")
        print("GIF start handle at \(from)")
        mouse(.leftMouseDown, from)
      }))
      for i in 1...25 {
        steps.append((0.02, { mouse(.leftMouseDragged, NSPoint(x: from.x - CGFloat(i * 10), y: from.y)) }))
      }
      steps.append((0.05, { mouse(.leftMouseUp, NSPoint(x: from.x - 250, y: from.y)) }))
      steps.append((1, { picture("3-start-dragged") }))
      // The peak hold captured afresh from there: a debug build's replay takes a few seconds.
      steps.append((8, {
        print("Fresh capture \(model.freshPeaks == nil ? "not made yet" : "made")")
        picture("3b-captured-afresh")
      }))
      // To the GIF's end, back three frames, and the end set there.
      steps.append((0.1, { key(right, 124, [.option, .function]) }))
      for _ in 0..<3 { steps.append((0.1, { key(left, 123, [.function]) })) }
      steps.append((0.1, { key("o", 31) }))
      steps.append((1, { picture("4-end-set") }))
      steps.append((0.2, {
        print("Undo: \(model.undoManager == nil ? "none" : "there"), sheet's \(sheet.undoManager?.canUndo ?? false)")
        model.undoManager?.undo()
      }))
      steps.append((1, { picture("5-undone") }))
      // Double clicks: the end handle to the recording's very end, the start handle to its very start; ⌘Z back.
      func handle(start: Bool) -> NSPoint {
        guard let strip = EditorDemo.strip else { return .zero }
        let inner = strip.width - 2 * TrimStrip.handle
        let moment = start ? model.trim.start : model.trim.end
        let fraction = moment.timeIntervalSince(model.clip.start) / model.total
        let x = strip.minX + TrimStrip.handle + inner * CGFloat(fraction) + (start ? -1 : 1) * TrimStrip.handle / 2
        return NSPoint(x: x, y: sheet.frame.height - strip.midY)
      }
      func trimmed() -> String {
        String(
          format: "start %.1f, end %.1f of %.1f", model.trim.start.timeIntervalSince(model.clip.start),
          model.trim.end.timeIntervalSince(model.clip.start), model.total)
      }
      for (name, start) in [("end", false), ("start", true)] {
        var point = NSPoint.zero
        var pressed: TimeInterval = 0
        steps.append((0.3, {
          point = handle(start: start)
          print("Before double-clicking the \(name) handle: \(trimmed())")
          pressed = ProcessInfo.processInfo.systemUptime
          mouse(.leftMouseDown, point, at: pressed)
        }))
        steps.append((0.05, { mouse(.leftMouseUp, point, at: pressed + 0.05) }))
        steps.append((0.1, { mouse(.leftMouseDown, point, at: pressed + 0.15) }))
        steps.append((0.05, { mouse(.leftMouseUp, point, at: pressed + 0.2) }))
        steps.append((0.5, { print("After double-clicking the \(name) handle: \(trimmed())") }))
      }
      steps.append((0.6, { picture("5b-double-clicked") }))
      steps.append((0.1, {
        model.undoManager?.undo()
        print("After ⌘Z: \(trimmed())")
      }))
      steps.append((0.1, { key("\u{1b}", 53) }))
      steps.append((1.2, {
        for window in NSApp.windows where window.isVisible {
          print("Window \(window.className) \(window.frame) sheet of \(window.sheetParent?.className ?? "nothing")")
        }
        if let alert = NSApp.windows.last(where: { $0.isVisible && $0.className.contains("Glass") }),
          let image = Self.picture(of: alert)
        {
          let url = folder.appendingPathComponent("6-cancel-asks.png")
          try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        picture("6-behind-the-question")
      }))
      steps.append((0.5, { exit(0) }))
      func run(_ index: Int) {
        guard index < steps.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].0) {
          steps[index].1()
          run(index + 1)
        }
      }
      run(0)
    }

    /// The window as it is on the screen. A program can picture its own windows without being let record the screen;
    /// the call is looked up as the SDK no longer offers it to Swift.
    static func picture(of window: NSWindow) -> CGImage? {
      typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
      let create = unsafeBitCast(symbol, to: Create.self)
      // Just this window, without its shadow, at the display's resolution.
      return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }
  }
#endif
