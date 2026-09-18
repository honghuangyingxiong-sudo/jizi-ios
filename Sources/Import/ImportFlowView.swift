import SwiftUI
import SwiftData
import PhotosUI

/// 导入 → 切字 → 标释文 → 入库。
/// 核心省事的地方：碑帖的释文按阅读顺序逐字对齐到切出来的格子，label 自动就有了。
struct ImportFlowView: View {

    enum Mode: String, CaseIterable, Identifiable {
        case auto, grid
        var id: String { rawValue }
        var label: String { self == .auto ? "自动切分" : "网格切分" }
    }

    enum Order: String, CaseIterable, Identifiable {
        case verticalRTL, horizontalLTR, asIs
        var id: String { rawValue }
        var label: String {
            switch self {
            case .verticalRTL: return "竖排·右起"
            case .horizontalLTR: return "横排·左起"
            case .asIs: return "按切分顺序"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var queue: [UIImage] = []
    @State private var cursor = 0

    @State private var mode: Mode = .auto
    @State private var options = SegmentOptions()
    @State private var gridColumns = 4
    @State private var gridRows = 6

    @State private var rects: [CGRect] = []
    @State private var inverted = false
    @State private var order: Order = .verticalRTL

    @State private var bookTitle = ""
    @State private var calligrapher = ""
    @State private var script = "楷"
    @State private var transcription = ""
    @State private var isWorking = false
    @State private var message: String?
    /// 同一批导入共用一个 SourceBook，避免每页建一帖
    @State private var sessionBook: SourceBook?

    private let scripts = ["楷", "行", "草", "隶", "篆", "魏碑", "其他"]

    private var current: UIImage? { queue[safe: cursor] }

    private var transcriptChars: [String] {
        transcription.filter { !$0.isWhitespace && !$0.isNewline }.map(String.init)
    }

    private var orderedRects: [CGRect] {
        Self.ordered(rects, order: order)
    }

    var body: some View {
        NavigationStack {
            Group {
                if current == nil {
                    pickerScreen
                } else {
                    editorScreen
                }
            }
            .navigationTitle(current == nil ? "导入碑帖" : "\(cursor + 1)/\(queue.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if current != nil {
                        Button("入库") { saveCurrent() }
                            .disabled(orderedRects.isEmpty || isWorking)
                    }
                }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await load(items) }
            }
            .onChange(of: mode) { _, _ in resegment() }
            .onChange(of: order) { _, _ in resegment() }
        }
    }

    // MARK: - 选图

    private var pickerScreen: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("选一页碑帖 / 字帖", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("一张图 = 一页。可以一次选多页，切完一页自动接下一页。")
            }
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: 20,
                         matching: .images,
                         photoLibrary: .shared()) {
                Text("从相册选择").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        isWorking = true
        var imgs: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                imgs.append(img.normalizedUp())
            }
        }
        queue = imgs
        cursor = 0
        sessionBook = nil
        isWorking = false
        if imgs.isEmpty { message = "没有读到图片" } else { resegment() }
    }

    // MARK: - 编辑

    private var editorScreen: some View {
        ScrollView {
            VStack(spacing: 14) {
                preview
                controls
                transcriptionBlock
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .overlay { if isWorking { ProgressView().padding(24).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("识别到 \(orderedRects.count) 个字")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if inverted {
                    Text("拓本（已反相）")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
            }
            GeometryReader { geo in
                if let image = current {
                    let fit = Self.aspectFit(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                        ForEach(Array(orderedRects.enumerated()), id: \.offset) { idx, r in
                            let f = CGRect(x: fit.minX + r.minX * fit.width,
                                           y: fit.minY + r.minY * fit.height,
                                           width: r.width * fit.width,
                                           height: r.height * fit.height)
                            Rectangle()
                                .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
                                .frame(width: f.width, height: f.height)
                                .position(x: f.midX, y: f.midY)
                            if idx < transcriptChars.count {
                                Text(transcriptChars[idx])
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(1)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                                    .position(x: f.minX + 8, y: f.minY + 8)
                            }
                        }
                    }
                }
            }
            .frame(height: 320)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("模式", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .auto {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("墨色阈值").font(.footnote)
                        Spacer()
                        Text("\(options.threshold)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(options.threshold) },
                        set: { options.threshold = UInt8(max(0, min(255, $0))) }
                    ), in: 60...230, step: 1) { _ in resegment() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("去噪强度").font(.footnote)
                        Spacer()
                        Text(String(format: "%.3f", Double(options.minBlockRatio))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $options.minBlockRatio, in: 0.008...0.12, step: 0.002) { _ in resegment() }
                }
            } else {
                HStack {
                    Stepper("列数 \(gridColumns)", value: $gridColumns, in: 1...20) { _ in resegment() }
                    Spacer()
                    Stepper("每列 \(gridRows) 字", value: $gridRows, in: 1...30) { _ in resegment() }
                }
                .font(.footnote)
            }

            Picker("阅读顺序", selection: $order) {
                ForEach(Order.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                resegment()
            } label: { Label("重新切分", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("释文（按阅读顺序逐字对齐）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(transcriptChars.count) / \(orderedRects.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(transcriptChars.count == orderedRects.count ? Color.secondary : Color.orange)
            }
            TextEditor(text: $transcription)
                .frame(minHeight: 96)
                .padding(6)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .font(.system(size: 17))

            Text("这一帖的信息（同一批导入共用）")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("帖名，如：兰亭序（神龙本）", text: $bookTitle)
                .textFieldStyle(.roundedBorder)
            TextField("书家，如：王羲之", text: $calligrapher)
                .textFieldStyle(.roundedBorder)
            Picker("字体", selection: $script) {
                ForEach(scripts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 切分 / 入库

    private func resegment() {
        guard let image = current else { return }
        let m = mode, o = options, c = gridColumns, r = gridRows
        var result: [CGRect] = []
        var inv = false
        if m == .auto {
            let s = Segmenter.segment(image, options: o)
            result = s.rects
            inv = s.inverted
        } else {
            result = Segmenter.grid(image, columns: c, rows: r)
        }
        inverted = inv
        rects = result
    }

    private func saveCurrent() {
        guard let image = current else { return }
        isWorking = true
        let boxes = orderedRects
        let chars = transcriptChars

        let book: SourceBook
        if let existing = sessionBook {
            book = existing
        } else {
            let title = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let fresh = SourceBook(title: title.isEmpty ? "未命名帖 \(Self.stamp())" : title,
                                   calligrapher: calligrapher.trimmingCharacters(in: .whitespacesAndNewlines),
                                   script: script)
            context.insert(fresh)
            sessionBook = fresh
            book = fresh
        }

        var saved = 0
        for (i, box) in boxes.enumerated() {
            guard let raw = Segmenter.crop(image, normalized: box) else { continue }
            let trimmed = Segmenter.trimInk(raw)
            let squared = Segmenter.squarePad(trimmed, target: 512)
            guard let name = ImageStore.save(squared) else { continue }
            let ch = i < chars.count ? chars[i] : ""
            let entry = CharacterEntry(character: ch, fileName: name, book: book)
            context.insert(entry)
            saved += 1
        }
        try? context.save()
        isWorking = false

        if cursor + 1 < queue.count {
            cursor += 1
            transcription = ""
            resegment()
            message = "本页入库 \(saved) 字，继续下一页"
        } else {
            message = "共入库 \(saved) 字，完成"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
        }
    }

    // MARK: - 工具

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmm"
        return f.string(from: Date())
    }

    static func aspectFit(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let ratio = min(box.width / size.width, box.height / size.height)
        let w = size.width * ratio, h = size.height * ratio
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    static func ordered(_ rects: [CGRect], order: Order) -> [CGRect] {
        switch order {
        case .asIs:
            return rects
        case .verticalRTL:
            let sorted = rects.sorted { $0.midX > $1.midX }
            return cluster(sorted, key: { $0.midX }) { $0.minY < $1.minY }
        case .horizontalLTR:
            let sorted = rects.sorted { $0.midY < $1.midY }
            return cluster(sorted, key: { $0.midY }) { $0.minX < $1.minX }
        }
    }

    /// 同一「列/行」里的块，主坐标差在容差内就归到一起，组内再按次坐标排。
    private static func cluster(_ rects: [CGRect],
                                key: (CGRect) -> CGFloat,
                                tolerance: CGFloat = 0.05,
                                then: (CGRect, CGRect) -> Bool) -> [CGRect] {
        var out: [CGRect] = []
        var group: [CGRect] = []
        var anchor: CGFloat?

        func flush() {
            guard !group.isEmpty else { return }
            out.append(contentsOf: group.sorted(by: then))
            group = []
        }

        for r in rects {
            let k = key(r)
            if let a = anchor {
                if abs(k - a) > tolerance {
                    flush()
                    anchor = k
                }
            } else {
                anchor = k
            }
            group.append(r)
        }
        flush()
        return out
    }
}
