import SwiftUI

/// A text file bundled with the app (the privacy policy, the acknowledgements), read on this
/// iPhone. Nothing is fetched.
struct TextDocumentView: View {
    let resource: String
    let title: String
    @ViewState private var text: String?

    var body: some View {
        ScrollView {
            Text(text ?? "")
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
        }
        .background(Palette.groupedBackground)
        .navigationTitle(title)
        .inlineNavigationTitle()
        .task { text = Self.load(resource) }
    }

    static func load(_ resource: String) -> String {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}
