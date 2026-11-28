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
      for k in 0...140 {
        if (124..<130).contains(k), id != nil { continue }  // 62 to 65 s: no picture, as when the analyzer stalls
        let time = zero.addingTimeInterval(Double(k) / 2)
        var screen = sized[(k / 12) % sized.count]
        let x = (k * 3) % max(screen.width - 12, 1)
        for row in 2..<8 {
          for column in x..<(x + 12) { screen.pixels[row * screen.width + column] = UInt32(0xFF00_FFFF).littleEndian }
        }
        recorder.add(screen, at: time)
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
      func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
        guard
          let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
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
    private static func picture(of window: NSWindow) -> CGImage? {
      typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
      let create = unsafeBitCast(symbol, to: Create.self)
      // Just this window, without its shadow, at the display's resolution.
      return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }
  }
#endif
