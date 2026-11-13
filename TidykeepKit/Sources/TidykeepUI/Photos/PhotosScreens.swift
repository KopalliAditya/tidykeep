import SwiftUI
import TidykeepCore

// STUB: replaced by this area's slice. Keep the view names and initializers.

struct SimilarShotsView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Similar.title)
    }
}

struct SimilarGroupView: View {
    let groupID: String

    var body: some View {
        AllTidyView().navigationTitle(Copy.Similar.title)
    }
}
