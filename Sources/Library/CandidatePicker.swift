import SwiftUI
import SwiftData

/// 某个字的候选：从字库里挑一张。
struct CandidatePicker: View {
    let character: String
    let candidates: [CharacterEntry]
    let selected: String?
    /// 传 nil 表示清除手动选择，回到默认第一张
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView("字库里没有「\(character)」",
                                           systemImage: "character.book.closed",
                                           description: Text("去「字库」页导入包含这个字的碑帖，或先换一个字试试。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(candidates) { entry in
                                Button {
                                    onPick(entry.fileName)
                                    dismiss()
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color(.secondarySystemGroupedBackground))
                                            if let img = ImageStore.thumbnail(entry.fileName, maxSide: 200) {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .padding(6)
                                            }
                                        }
                                        .frame(height: 92)
                                        .overlay {
                                            if entry.fileName == selected {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.accentColor, lineWidth: 2.5)
                                            }
                                        }
                                        Text(entry.book?.title ?? "未署名")
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(character.isEmpty ? "选字" : "选「\(character)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("默认") {
                        onPick(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
