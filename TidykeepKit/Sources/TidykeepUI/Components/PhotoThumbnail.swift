import SwiftUI

/// A photo or video poster from the library, loaded on demand. Decorative: the containing
/// view labels it.
struct PhotoThumbnail: View {
    @Environment(PhotosModel.self) private var photos
    let id: String
    var pixelSize = 300
    var contentMode: ContentMode = .fill
    @ViewState private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.fill)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .clipped()
        .task(id: "\(id)@\(pixelSize)") {
            image = await photos.thumbnail(for: id, pixelSize: pixelSize)
        }
    }
}

/// Up to three photos fanned like a small stack of prints, for Home cards and list rows.
/// Falls back to a symbol when there's nothing to show.
struct ThumbnailStack: View {
    let ids: [String]
    var symbol: String
    var size: CGFloat = 56

    var body: some View {
        let shown = Array(ids.prefix(3))
        ZStack {
            if shown.isEmpty {
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Palette.accent.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
            } else {
                ForEach(Array(shown.enumerated().reversed()), id: \.element) { index, id in
                    PhotoThumbnail(id: id, pixelSize: 200)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner * 0.7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.inner * 0.7, style: .continuous)
                                .strokeBorder(Palette.card, lineWidth: 2)
                        }
                        .rotationEffect(.degrees(Double(index) * 7))
                        .offset(x: CGFloat(index) * size * 0.14, y: CGFloat(index) * -size * 0.04)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
            }
        }
        .frame(width: size * 1.3, height: size * 1.1, alignment: .leading)
        .accessibilityHidden(true)
    }
}
