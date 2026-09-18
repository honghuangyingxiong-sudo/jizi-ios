import UIKit

/// 集字排版配置。所有尺寸都以「格」为单位，导出时按倍数放大。
struct ComposeConfig {

    enum Orientation: String, CaseIterable, Identifiable {
        case vertical
        case horizontal

        var id: String { rawValue }
        var label: String {
            switch self {
            case .vertical: return "竖排·右起"
            case .horizontal: return "横排·左起"
            }
        }
    }

    var orientation: Orientation = .vertical
    /// 每个字的相对大小 0.6 ... 1.15
    var scale: CGFloat = 1.0
    /// 字距，相对格宽 0 ... 0.5
    var spacing: CGFloat = 0.08
    /// 竖排每列字数 / 横排每行字数
    var perLine: Int = 6
    /// 整幅留白，相对格宽
    var padding: CGFloat = 0.7
    var background: UIColor = UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
    var ink: UIColor = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
    /// 落款文字（画在左侧 / 下方）
    var signature: String = ""
    /// 印章文字，2–4 个字，画成朱文方块
    var sealText: String = ""
    /// 印章/落款开关
    var showsSignature: Bool = true
    /// 缺字时是否用系统字体补位（浅灰显示，提示这个字库里没有）
    var showsFallbackGlyph: Bool = true
}

/// 把一串单字图排成一张作品。
enum Composer {

    /// 预览用的基准格边长（pt）
    static let previewCell: CGFloat = 96
    /// 导出用的基准格边长（pt）
    static let exportCell: CGFloat = 420

    struct Layout {
        var cells: [CGRect]
        var contentSize: CGSize
        var signatureFrame: CGRect?
        var totalSize: CGSize
    }

    // MARK: - 排布

    static func layout(count: Int, config: ComposeConfig, cell: CGFloat) -> Layout {
        let n = max(count, 1)
        let per = max(1, config.perLine)
        let cellSize = cell * config.scale
        let gap = cellSize * config.spacing
        let lines = Int(ceil(Double(n) / Double(per)))

        var content = CGSize.zero
        var cells: [CGRect] = []

        switch config.orientation {
        case .vertical:
            content = CGSize(width: cellSize * CGFloat(lines) + gap * CGFloat(lines - 1),
                             height: cellSize * CGFloat(per) + gap * CGFloat(per - 1))
            for i in 0..<n {
                let col = i / per
                let row = i % per
                // 右起：第一列贴右边
                let x = content.width - cellSize - CGFloat(col) * (cellSize + gap)
                let y = CGFloat(row) * (cellSize + gap)
                cells.append(CGRect(x: x, y: y, width: cellSize, height: cellSize))
            }
        case .horizontal:
            content = CGSize(width: cellSize * CGFloat(per) + gap * CGFloat(per - 1),
                             height: cellSize * CGFloat(lines) + gap * CGFloat(lines - 1))
            for i in 0..<n {
                let row = i / per
                let col = i % per
                let x = CGFloat(col) * (cellSize + gap)
                let y = CGFloat(row) * (cellSize + gap)
                cells.append(CGRect(x: x, y: y, width: cellSize, height: cellSize))
            }
        }

        let pad = cellSize * config.padding
        let wantsSignature = config.showsSignature && (!config.signature.isEmpty || !config.sealText.isEmpty)
        let sigW = wantsSignature ? cellSize * 0.62 : 0
        let signGap = wantsSignature ? cellSize * 0.18 : 0

        let total = CGSize(width: content.width + pad * 2 + sigW + signGap,
                           height: content.height + pad * 2)

        var resolvedCells = cells
        var sigFrame: CGRect?
        switch config.orientation {
        case .vertical:
            // 内容整体靠右，落款放左边
            let dx = pad + sigW + signGap
            resolvedCells = cells.map { $0.offsetBy(dx: dx, dy: pad) }
            sigFrame = wantsSignature
                ? CGRect(x: pad, y: pad, width: sigW, height: content.height)
                : nil
        case .horizontal:
            let dx = pad
            resolvedCells = cells.map { $0.offsetBy(dx: dx, dy: pad) }
            sigFrame = wantsSignature
                ? CGRect(x: total.width - pad - sigW,
                         y: pad + content.height - cellSize * 1.6,
                         width: sigW, height: cellSize * 1.6)
                : nil
        }

        return Layout(cells: resolvedCells, contentSize: content, signatureFrame: sigFrame, totalSize: total)
    }

    // MARK: - 渲染

    /// - Parameter images: 与文本逐字对应，缺字的传 nil
    static func render(images: [UIImage?], characters: [String], config: ComposeConfig, cell: CGFloat) -> UIImage {
        let lay = layout(count: images.count, config: config, cell: cell)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: lay.totalSize, format: format).image { ctx in
            config.background.setFill()
            ctx.fill(CGRect(origin: .zero, size: lay.totalSize))

            for (i, image) in images.enumerated() {
                guard i < lay.cells.count else { break }
                let rect = lay.cells[i]
                if let image {
                    drawFitted(image, in: rect, context: ctx.cgContext)
                } else if config.showsFallbackGlyph, i < characters.count, !characters[i].isEmpty {
                    drawFallback(characters[i], in: rect, config: config, ctx: ctx)
                }
            }

            if let frame = lay.signatureFrame {
                drawSignature(in: frame, config: config, ctx: ctx, cell: cell)
            }
        }
    }

    /// 按笔迹外框等比放进格子里并居中 —— 字与字之间的视觉大小才一致。
    private static func drawFitted(_ image: UIImage, in rect: CGRect, context: CGContext) {
        let trimmed = Segmenter.trimInk(image)
        let sw = trimmed.size.width, sh = trimmed.size.height
        guard sw > 0, sh > 0 else { return }
        let ratio = min(rect.width / sw, rect.height / sh)
        let dw = sw * ratio, dh = sh * ratio
        let target = CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh)
        context.saveGState()
        context.interpolationQuality = .high
        trimmed.draw(in: target)
        context.restoreGState()
    }

    private static func drawFallback(_ character: String, in rect: CGRect, config: ComposeConfig, ctx: UIGraphicsImageRendererContext) {
        let font = UIFont.systemFont(ofSize: rect.height * 0.82, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: config.ink.withAlphaComponent(0.18)
        ]
        let str = NSAttributedString(string: character, attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private static func drawSignature(in frame: CGRect, config: ComposeConfig, ctx: UIGraphicsImageRendererContext, cell: CGFloat) {
        var cursorY = frame.minY + cell * 0.1

        if !config.signature.isEmpty {
            let fontSize = cell * 0.30
            let font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: config.ink.withAlphaComponent(0.85)]
            let step = fontSize * 1.12
            let lineHeight = frame.width
            
            for ch in config.signature {
                let s = NSAttributedString(string: String(ch), attributes: attrs)
                let size = s.size()
                let x = frame.midX - size.width / 2 + (lineHeight * 0.12)
                s.draw(at: CGPoint(x: x, y: cursorY))
                cursorY += step
            }
            cursorY += fontSize * 0.5
        }

        if !config.sealText.isEmpty {
            let side = cell * 0.46
            let rect = CGRect(x: frame.midX - side / 2, y: cursorY, width: side, height: side)
            let sealColor = UIColor(red: 0.72, green: 0.13, blue: 0.13, alpha: 1)
            sealColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.08).fill()

            let chars = Array(config.sealText)
            let n = chars.count
            guard n > 0 else { return }
            let perRow = n <= 2 ? n : 2
            let rows = Int(ceil(Double(n) / Double(perRow)))
            let gs = side / CGFloat(max(perRow, rows))
            let font = UIFont.systemFont(ofSize: gs * 0.78, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            for (i, ch) in chars.enumerated() {
                let r = i / perRow, c = i % perRow
                // 篆刻一路是右起，这里从右往左排
                let x = rect.minX + CGFloat(perRow - 1 - c) * gs
                let y = rect.minY + CGFloat(r) * gs
                let s = NSAttributedString(string: String(ch), attributes: attrs)
                let size = s.size()
                s.draw(at: CGPoint(x: x + (gs - size.width) / 2, y: y + (gs - size.height) / 2))
            }
        }
    }

    // MARK: - 导出

    static func export(images: [UIImage?], characters: [String], config: ComposeConfig) -> UIImage {
        render(images: images, characters: characters, config: config, cell: exportCell)
    }

    /// 长边限制到 4096，避免超大画布把内存顶爆。
    static func capped(_ image: UIImage, maxSide: CGFloat = 4096) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let ratio = maxSide / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
