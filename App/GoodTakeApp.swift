import GoodTakePhotoKit
import GoodTakeUI
import GoodTakeVision
import SwiftUI

@main
struct GoodTakeApp: App {
    @State private var model = AppModel(
        source: PhotoKitSource(),
        analyzer: VisionFrameAnalyzer(),
        directory: GoodTakeApp.dataDirectory()
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }

    /// Application Support/GoodTake, left out of device backups: the analysis cache is rebuilt
    /// from the library, and nothing about the user's photos should leave the phone.
    static func dataDirectory() -> URL? {
        let fm = FileManager.default
        guard var url = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GoodTake", isDirectory: true)
        else { return nil }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
}
