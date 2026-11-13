import SwiftUI
import TidykeepCore

// STUB: replaced by this area's slice. Keep the view names and initializers.

struct HistoryView: View {

    var body: some View {
        AllTidyView().navigationTitle(Copy.Tabs.history)
    }
}

struct ReceiptView: View {
    let receiptID: UUID

    var body: some View {
        AllTidyView().navigationTitle(Copy.Tabs.history)
    }
}
