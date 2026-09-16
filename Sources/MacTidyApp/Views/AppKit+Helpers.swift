import AppKit
import SwiftUI

/// Reads the marketing version + build number from the main bundle's
/// Info.plist so the welcome screen and Settings show a consistent version.
public enum AppVersion {
    public static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    public static var full: String { "\(short) (\(build))" }
}

extension View {
    /// Reads the app icon from the running bundle's Resources, used when the
    /// SwiftUI `AppIcon` asset isn't resolvable (bare SwiftPM binary path).
    var bundledAppIcon: NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "AppIcon", withExtension: "icns")
            ?? bundle.url(forResource: "AppIcon", withExtension: "png")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}
