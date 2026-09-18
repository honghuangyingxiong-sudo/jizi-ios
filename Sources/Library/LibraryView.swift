import SwiftUI
import SwiftData

struct LibraryView: View {

    @Environment(\.modelContext) private var context
    @Query(sort: \CharacterEntry.createdAt, order: .reverse) private var entries: [CharacterEntry]
    @Query(sort: \SourceBook.createdAt, order: .reverse) private var books: [SourceBook]

    @State private var search = ""
    @State private var showImport = false
    @State private var detail: CharacterEntry?
    @State private var renaming: CharacterEntry?
    @State private var renameText = ""

    private var filtered: [CharacterEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.character.contains(search) || ($0.book?.title.contains(search) ?? false) }
    }

    private let columns = [GridItem(.adaptive(minimum: 82), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("字库是空的", systemImage: "square.grid.3x3.square")
                    } description: {
                        Text("导入一页碑帖 / 字帖扫描图，切好字、填上释文，就能开始集字。")
                    } actions: {
                        Button("导入碑帖") { showImport = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 60)
                } else {
                    if !books.isEmpty { bookSection }
                    characterSection
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("字库")
            .searchable(text: $search, prompt: "搜字 / 搜帖名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImport = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportFlowView()
            }
            .sheet(item: $detail) { entry in
                EntryDetail(entry: entry)
            }
            .alert("改字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("汉字", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    renaming?.character = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? context.save()
                    renaming = nil
                }
            }
        }
    }

    private var bookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("碑帖 (\(books.count))")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(books) { b in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(b.title)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                            Text("\(b.calligrapher.isEmpty ? "未署名" : b.calligrapher) · \(b.script) · \(b.entries.count) 字")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(width: 150, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        .contextMenu {
                            Button(role: .destructive) { deleteBook(b) } label: { Label("删除整帖", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    private var characterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("单字 (\(filtered.count))")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filtered) { entry in
                    Button {
                        detail = entry
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.secondarySystemGroupedBackground))
                                if let img = ImageStore.thumbnail(entry.fileName) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .padding(4)
                                }
                            }
                            .frame(height: 72)
                            Text(entry.displayCharacter)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameText = entry.character
                            renaming = entry
                        } label: { Label("改字", systemImage: "pencil") }
                        Button(role: .destructive) { delete(entry) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
    }

    private func delete(_ entry: CharacterEntry) {
        ImageStore.delete(entry.fileName)
        context.delete(entry)
        try? context.save()
    }

    private func deleteBook(_ book: SourceBook) {
        for e in book.entries { ImageStore.delete(e.fileName) }
        context.delete(book)
        try? context.save()
    }
}

struct EntryDetail: View {
    let entry: CharacterEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var character: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let img = ImageStore.load(entry.fileName) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Text("字").font(.footnote)
                    TextField("汉字", text: $character)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: character) { _, new in
                            entry.character = new.trimmingCharacters(in: .whitespacesAndNewlines)
                            try? context.save()
                        }
                }
                if let b = entry.book {
                    Text("\(b.title) \(b.calligrapher.isEmpty ? "" : "· " + b.calligrapher) · \(b.script)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("单字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .onAppear { character = entry.character }
        }
    }
}
