import AppKit

/// The menu bar: the app (settings), File (a screenshot, GIFs), Edit (copy the screenshot), View (sizes, control, full
/// screen), Window, Help.
@MainActor
func makeMenuBar() -> NSMenu {
  let bar = NSMenu()

  func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let holder = NSMenuItem()
    holder.submenu = menu
    bar.addItem(holder)
    return menu
  }
  func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command)
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }

  _ = menu(
    "tinySA Screen",
    [
      item("About tinySA Screen", #selector(AppDelegate.showAbout(_:))),
      .separator(),
      item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
      .separator(),
      item("Hide tinySA Screen", #selector(NSApplication.hide(_:)), "h"),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
      .separator(),
      item("Quit tinySA Screen", #selector(NSApplication.terminate(_:)), "q"),
    ])
  _ = menu(
    "File",
    [
      item("Save Screenshot to Desktop", #selector(AppDelegate.saveScreenshot(_:)), "s"),
      .separator(),
      item("Record GIF", #selector(AppDelegate.toggleRecording(_:)), "r"),
      item("Capture as GIF…", #selector(AppDelegate.capture(_:)), "r", [.command, .shift]),
      .separator(),
      item("Close", #selector(NSWindow.performClose(_:)), "w"),
    ])
  _ = menu("Edit", [item("Copy Screenshot", #selector(AppDelegate.copy(_:)), "c")])
  _ = menu(
    "View",
    [
      item("Actual Size", #selector(AppDelegate.actualSize(_:)), "1"),
      item("Double Size", #selector(AppDelegate.doubleSize(_:)), "2"),
      item("Triple Size", #selector(AppDelegate.tripleSize(_:)), "3"),
      .separator(),
      item("Control the tinySA by Clicking", #selector(AppDelegate.toggleControl(_:)), "k"),
      .separator(),
      item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ])
  let window = menu(
    "Window",
    [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:))),
      .separator(),
      item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
    ])
  let help = menu(
    "Help",
    [
      item("tinySA Screen on GitHub", #selector(AppDelegate.openRepository(_:))),
      item("Working with Other Programs", #selector(AppDelegate.openIntegrationGuide(_:))),
    ])
  NSApp.windowsMenu = window
  NSApp.helpMenu = help
  return bar
}

if CommandLineTool.isAsked(CommandLine.arguments) {
  exit(CommandLineTool.run(CommandLine.arguments))
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.mainMenu = makeMenuBar()

  // Quit as from the menu on `kill` or Control-C too, so the analyzer's live screen is turned off: left on, it would go
  // on sending to no one, and the next program to open the analyzer would find its console full of it.
  let quitSignals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
  }

  app.run()
  withExtendedLifetime((delegate, quitSignals)) {}
}
