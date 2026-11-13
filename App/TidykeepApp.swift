import TidykeepPhotoKit
import TidykeepUI
import TidykeepVision
import SwiftUI

@main
struct TidykeepApp: App {
    @State private var model = AppModel(
        source: PhotoKitSource(),
        analyzer: VisionFrameAnalyzer(),
        directory: TidykeepApp.dataDirectory()
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }

    /// Application Support/Tidykeep, left out of device backups: the analysis cache is rebuilt
    /// from the library, and nothing about the user's photos should leave the phone.
    static func dataDirectory() -> URL? {
        let fm = FileManager.default
        guard var url = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Tidykeep", isDirectory: true)
        else { return nil }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
}
