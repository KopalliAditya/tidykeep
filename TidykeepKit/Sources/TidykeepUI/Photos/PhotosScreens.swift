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

struct CopiesView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Copies.title)
    }
}

struct CopySetView: View {
    let groupID: String

    var body: some View {
        AllTidyView().navigationTitle(Copy.Copies.title)
    }
}

struct ScreenshotsView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Screenshots.title)
    }
}

struct BigVideosView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Videos.title)
    }
}

struct VideoDetailView: View {
    let videoID: String

    var body: some View {
        AllTidyView().navigationTitle(Copy.Videos.title)
    }
}
