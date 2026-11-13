import SwiftUI

/// A photo from the library, loaded on demand. Decorative: the containing view labels it.
struct PhotoThumbnail: View {
    @Environment(AppModel.self) private var model
    let id: String
    var pixelSize = 300
    var contentMode: ContentMode = .fill
    @ViewState private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: "\(id)@\(pixelSize)") {
            image = await model.thumbnail(for: id, pixelSize: pixelSize)
        }
    }
}
