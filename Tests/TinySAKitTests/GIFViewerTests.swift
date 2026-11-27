import XCTest

@testable import TinySAKit

final class GIFViewerTests: XCTestCase {
  /// A GIF opens in the browser when the app that opens GIFs shows them still, or when none does.
  func testStillAppsGiveWayToTheBrowser() {
    for app in [
      nil, "com.apple.Preview", "com.apple.Photos", "com.apple.ColorSyncUtility", "com.pixelmatorteam.pixelmator.x",
      "com.adobe.Photoshop", "org.gimp.gimp-2.10", "org.gimp.gimp-3.0", "com.seriflabs.affinityphoto2",
      "com.flyingmeat.Acorn7", "org.krita",
    ] {
      XCTAssertTrue(GIFViewer.usesBrowser(insteadOf: app), app ?? "no app")
    }
  }

  /// One that plays GIFs keeps them: a browser, a video player, an image viewer that animates.
  func testAppsThatPlayGIFsKeepThem() {
    for app in [
      "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
      "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX",
    ] {
      XCTAssertFalse(GIFViewer.usesBrowser(insteadOf: app), app)
    }
  }
}
