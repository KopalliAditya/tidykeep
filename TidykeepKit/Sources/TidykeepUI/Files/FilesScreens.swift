import SwiftUI
import TidykeepCore

// STUB: replaced by this area's slice. Keep the view names and initializers.

struct DuplicateFilesView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Home.duplicateFiles)
    }
}

struct DuplicateFileSetView: View {
    let setID: String

    var body: some View {
        AllTidyView().navigationTitle(Copy.Home.duplicateFiles)
    }
}

struct LargeFilesView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Home.largeFiles)
    }
}

struct HoldingView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Home.holding)
    }
}
