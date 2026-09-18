import SwiftUI
import SwiftData
import PhotosUI

struct ComposeView: View {

    @Query(sort: \CharacterEntry.createdAt, order: .reverse) private var entries: [CharacterEntry]

    @State private var text: String = "永和九年"
    @State private var config = ComposeConfig()
    /// 第几个字 → 选中的 CharacterEntry.fileName
    @State private var picks: [Int: String] = [:]
    @State private var preview: UIImage?
    @State private var hashSeed: Int = 0
    @State private var editingIndex: Int?
    @State private var toast: String?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showControls = true

    private var characters: [String] {
        text.filter { !$0.isWhitespace && !$0.isNewline }.map(String.init)
    }

    private var grouped: [String: [CharacterEntry]] {
        Dictionary(grouping: entries.filter { !$0.character.isEmpty }, by: { $0.character })
    }

    /// 每个字最终用的图
    private var resolvedImages: [UIImage?] {
        characters.enumerated().map { idx, ch in
            if let name = picks[idx], let img = ImageStore.load(name) { return img }
            if let first = grouped[ch]?.first { return ImageStore.load(first.fileName) }
            return nil
        }
    }

    private var renderKey: String {
        let p = picks.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "\(text)|\(config.orientation.rawValue)|\(config.scale)|\(config.spacing)|\(config.perLine)|\(config.signature)|\(config.sealText)|\(p)|\(hashSeed)"
    }

    private var coverage: (have: Int, total: Int) {
        let total = characters.count
        let have = characters.enumerated().filter { pair -> Bool in
            if picks[pair.offset] != nil { return true }
            return grouped[pair.element]?.isEmpty == false
        }.count
        return (have, total)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    canvas
                    characterStrip
                    if showControls { controls }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("集字")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation { showControls.toggle() }
                    } label: {
                        Image(systemName: showControls ? "textformat.size" : "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportToPhotos()
                        } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                        Button {
                            prepareShare()
                        } label: { Label("导出 PNG", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button(role: .destructive) {
                            picks.removeAll()
                            hashSeed += 1
                        } label: { Label("清空逐字选择", systemImage: "arrow.counterclockwise") }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: renderKey) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let imgs = resolvedImages
            let chars = characters
            let cfg = config
            preview = Composer.render(images: imgs, characters: chars, config: cfg, cell: Composer.previewCell)
        }
        .onChange(of: text) { _, _ in
            picks = picks.filter { $0.key < characters.count }
        }
        .sheet(item: Binding(
            get: { editingIndex.map { IndexBox(index: $0) } },
            set: { if $0 == nil { editingIndex = nil } }
        )) { box in
            CandidatePicker(
                character: characters.indices.contains(box.index) ? characters[box.index] : "",
                candidates: candidates(for: box.index),
                selected: picks[box.index]
            ) { chosen in
                if let chosen { picks[box.index] = chosen } else { picks.removeValue(forKey: box.index) }
                editingIndex = nil
            }
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) { toast = nil }
        } message: {
            Text(toast ?? "")
        }
    }

    // MARK: - 画布

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("预览")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                let c = coverage
                Text("\(c.have)/\(c.total) 有字")
                    .font(.caption)
                    .foregroundStyle(c.have == c.total ? Color.secondary : Color.orange)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 220)
        }
        .padding(.top, 8)
    }

    // MARK: - 逐字条

    private var characterStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("逐字换字")
                .font(.subheadline.weight(.semibold))
            if characters.isEmpty {
                Text("上面输入文字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(characters.enumerated()), id: \.offset) { idx, ch in
                            Button {
                                editingIndex = idx
                            } label: {
                                VStack(spacing: 4) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(.secondarySystemGroupedBackground))
                                        if let img = resolvedImages[safe: idx] ?? nil {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFit()
                                                .padding(4)
                                        } else {
                                            Text(ch)
                                                .font(.system(size: 22))
                                                .foregroundStyle(.tertiary)
                                        }
                                        if candidates(for: idx).count > 1 {
                                            Text("\(candidates(for: idx).count)")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(3)
                                                .background(Circle().fill(Color.orange))
                                                .offset(x: 16, y: -16)
                                        }
                                    }
                                    .frame(width: 48, height: 48)
                                    Text(ch)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func candidates(for index: Int) -> [CharacterEntry] {
        guard characters.indices.contains(index) else { return [] }
        let ch = characters[index]
        var list = grouped[ch] ?? []
        if let name = picks[index], let hit = entries.first(where: { $0.fileName == name }) {
            list.removeAll { $0.fileName == name }
            list.insert(hit, at: 0)
        }
        return list
    }

    // MARK: - 参数面板

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("内容")
                .font(.subheadline.weight(.semibold))

            TextField("输入要集的文字", text: $text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            Text("排版")
                .font(.subheadline.weight(.semibold))

            Picker("方向", selection: $config.orientation) {
                ForEach(ComposeConfig.Orientation.allCases) { o in
                    Text(o.label).tag(o)
                }
            }
            .pickerStyle(.segmented)

            stepperRow("每行字数", value: Binding(
                get: { Double(config.perLine) },
                set: { config.perLine = max(1, Int($0)) }
            ), range: 1...20, step: 1, format: "%.0f")

            sliderRow("字号", value: $config.scale, range: 0.55...1.2)
            sliderRow("字距", value: $config.spacing, range: -0.15...0.5)

            Divider()

            Text("落款与印章")
                .font(.subheadline.weight(.semibold))

            Toggle("显示落款 / 印章", isOn: $config.showsSignature)

            TextField("落款（如：壬寅秋月 张临）", text: $config.signature)
                .textFieldStyle(.roundedBorder)
                .disabled(!config.showsSignature)

            TextField("印章文字（2–4 字）", text: $config.sealText)
                .textFieldStyle(.roundedBorder)
                .disabled(!config.showsSignature)

            HStack(spacing: 12) {
                ColorButton(title: "宣纸", color: UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)) {
                    config.background = UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
                }
                ColorButton(title: "纯白", color: .white) { config.background = .white }
                ColorButton(title: "淡青", color: UIColor(red: 0.94, green: 0.96, blue: 0.95, alpha: 1)) {
                    config.background = UIColor(red: 0.94, green: 0.96, blue: 0.95, alpha: 1)
                }
                ColorButton(title: "黑底", color: UIColor(white: 0.12, alpha: 1)) {
                    config.background = UIColor(white: 0.12, alpha: 1)
                    config.ink = .white
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sliderRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(String(format: "%.2f", Double(value.wrappedValue)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func stepperRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    // MARK: - 导出

    private func exportToPhotos() {
        let imgs = resolvedImages
        let chars = characters
        let cfg = config
        Task {
            let img = Composer.capped(Composer.export(images: imgs, characters: chars, config: cfg))
            let result = await PhotosSaver.save(img)
            switch result {
            case .saved: toast = "已保存到相册"
            case .denied: toast = "没有相册写入权限，去「设置 → 隐私 → 照片」打开"
            case .failed(let msg): toast = "保存失败：\(msg)"
            }
        }
    }

    private func prepareShare() {
        let imgs = resolvedImages
        let chars = characters
        let cfg = config
        let img = Composer.capped(Composer.export(images: imgs, characters: chars, config: cfg))
        if let url = PhotosSaver.temporaryPNG(img, name: "\(text.prefix(8)).png") {
            shareURL = url
            showShare = true
        } else {
            toast = "导出失败"
        }
    }
}

// MARK: - 辅助

struct IndexBox: Identifiable {
    let index: Int
    var id: Int { index }
}

struct ColorButton: View {
    let title: String
    let color: UIColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(color))
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator)))
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
