import AppKit
import SwiftUI

/// Loads and renders the Blofeld logo from the resource bundle.
///
/// The emblem ships as an SVG, so `NSImage` keeps a vector representation and
/// stays crisp at any size (including Retina menu-bar @2x). We never rasterize
/// it to a fixed small bitmap — that is what previously turned it into a blurry
/// white disc.
enum AppAssets {
    /// Resolves the SwiftPM resource bundle.
    ///
    /// We deliberately avoid `Bundle.module`: the generated accessor only checks the
    /// `.app` *root* and an absolute build path baked in at compile time, so inside a
    /// packaged/signed app — where resources are sealed under `Contents/Resources` —
    /// merely touching `Bundle.module` would `fatalError`. Instead we look in the real
    /// locations: `Contents/Resources` (packaged .app) and the executable dir
    /// (`swift run`), falling back to the main bundle if resources were flattened.
    private static let resourceBundle: Bundle = {
        let name = "Blofeld_Blofeld.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) {
                return bundle
            }
        }
        return .main
    }()

    /// Fresh vector-backed copy of the emblem.
    private static func loadEmblem() -> NSImage {
        if let url = resourceBundle.url(forResource: "blofeld_scar_logo_v2", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = resourceBundle.url(forResource: "blofeld_scar_logo_v2", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    /// Template image for the menu bar status item. `isTemplate = true` lets
    /// macOS auto-invert it for light/dark menu bars; the vector keeps it sharp.
    static func menuBar(pointSize: CGFloat = 18) -> NSImage {
        sized(pointSize: pointSize, template: true)
    }

    /// Template image for use inside the panel; tint it with `.foregroundStyle`.
    static func panelLogo(pointSize: CGFloat = 22) -> NSImage {
        sized(pointSize: pointSize, template: true)
    }

    private static func sized(pointSize: CGFloat, template: Bool) -> NSImage {
        let image = loadEmblem()
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: round(pointSize * aspect), height: pointSize)
        image.isTemplate = template
        return image
    }
}
