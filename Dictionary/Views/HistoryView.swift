import SwiftUI

/// Recent lookups, like the search history in the macOS Dictionary app.
struct HistoryView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.recents.isEmpty {
                    Text("Words you look up will appear here.")
                        .font(.roboto(15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.recents, id: \.self) { word in
                            Button {
                                model.lookUp(word)
                                dismiss()
                            } label: {
                                Text(word)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            model.recents.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Recent Searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) {
                        model.clearRecents()
                    }
                    .disabled(model.recents.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(DictionaryViewModel())
}
