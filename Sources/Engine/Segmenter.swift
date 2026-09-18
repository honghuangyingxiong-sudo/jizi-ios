import UIKit
import CoreGraphics

/// 切字参数。默认值对「一页碑帖 / 字帖扫描件」还算能打，
/// 行书连笔、印章、边款这类情况需要手动调阈值或改用网格模式。
struct SegmentOptions {
    /// 灰度阈值：低于该值算「暗」。墨迹 = 白底黑字时取暗像素。
    var threshold: UInt8 = 150
    /// 自动判正负片：拓本是黑底白字，整体偏暗就反转。
    var autoInvert: Bool = true
    /// 一列里墨点占比低于此值，认为该列是空白
    var minInkRatio: CGFloat = 0.012
    /// 块小于该比例（相对整页宽/高）就丢掉，用来滤掉噪点和虫蛀
    var minBlockRatio: CGFloat = 0.028
    /// 相邻块之间的缝合间距（相对整页尺寸）
    var mergeGapRatio: CGFloat = 0.007
    /// 处理前先缩到这个宽度以内，速度优先
    var workingWidth: CGFloat = 1400
}

/// 基于投影的版面切分：先切列，再在每列里切字。
/// 不依赖 Vision，纯像素统计，结果可预测、好调。
enum Segmenter {

    struct Result {
        /// 归一化坐标（0...1，原点左上），乘以原图像素尺寸即得裁剪框
        var rects: [CGRect]
        /// 是否判定为负片（拓本）
        var inverted: Bool
    }

    // MARK: - 入口

    static func segment(_ image: UIImage, options: SegmentOptions = SegmentOptions()) -> Result {
        let normalized = image.normalizedUp()
        guard let cg = normalized.cgImage else { return Result(rects: [], inverted: false) }

        let scale = min(1, options.workingWidth / CGFloat(cg.width))
        let w = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        guard let gray = grayscale(cg, width: w, height: h) else {
            return Result(rects: [], inverted: false)
        }

        var inverted = false
        if options.autoInvert {
            let sum = gray.reduce(0) { $0 + Int($1) }
            inverted = Double(sum) / Double(gray.count) < 128
        }

        var ink = [Bool](repeating: false, count: w * h)
        var inkTotal = 0
        for i in 0..<(w * h) {
            let dark = gray[i] < options.threshold
            let isInk = inverted ? !dark : dark
            ink[i] = isInk
            if isInk { inkTotal += 1 }
        }
        guard inkTotal > 0 else { return Result(rects: [], inverted: inverted) }

        // 1) 列投影
        var colInk = [Int](repeating: 0, count: w)
        for x in 0..<w {
            var c = 0
            for y in 0..<h where ink[y * w + x] { c += 1 }
            colInk[x] = c
        }
        let colMin = max(1, Int(CGFloat(h) * options.minInkRatio))
        let colGap = max(1, Int(CGFloat(w) * options.mergeGapRatio))
        let columns = runs(colInk.map { $0 >= colMin }, minGap: colGap)

        // 2) 在每一列里做行投影，切出单字
        let rowGap = max(1, Int(CGFloat(h) * options.mergeGapRatio))
        var rects: [CGRect] = []

        for col in columns {
            let cw = col.upperBound - col.lowerBound
            guard CGFloat(cw) >= CGFloat(w) * options.minBlockRatio * 0.5 else { continue }

            var rowInk = [Int](repeating: 0, count: h)
            for y in 0..<h {
                var c = 0
                for x in col.lowerBound..<col.upperBound where ink[y * w + x] { c += 1 }
                rowInk[y] = c
            }
            let rowMin = max(1, Int(CGFloat(cw) * options.minInkRatio))
            let rowRuns = runs(rowInk.map { $0 >= rowMin }, minGap: rowGap)

            for r in rowRuns {
                let rh = r.upperBound - r.lowerBound
                guard CGFloat(rh) >= CGFloat(h) * options.minBlockRatio * 0.5 else { continue }
                guard let box = tighten(ink, w, h, col.lowerBound, col.upperBound, r.lowerBound, r.upperBound) else { continue }
                rects.append(CGRect(x: CGFloat(box.minX) / CGFloat(w),
                                    y: CGFloat(box.minY) / CGFloat(h),
                                    width: CGFloat(box.width) / CGFloat(w),
                                    height: CGFloat(box.height) / CGFloat(h)))
            }
        }

        return Result(rects: rects.sorted(by: readingOrder(inverted: false)), inverted: inverted)
    }

    /// 均匀网格切分：自己数好「几列几行」时最稳，行草也能用。
    /// - Parameters:
    ///   - columns: 列数（竖排时是列，横排时是行）
    ///   - rows: 每列里的字数
    ///   - inset: 每格向内收缩的比例，避免吃到邻字
    static func grid(_ image: UIImage, columns: Int, rows: Int, inset: CGFloat = 0.04) -> [CGRect] {
        guard columns > 0, rows > 0 else { return [] }
        let cw = 1.0 / CGFloat(columns)
        let ch = 1.0 / CGFloat(rows)
        var out: [CGRect] = []
        for c in 0..<columns {
            for r in 0..<rows {
                out.append(CGRect(x: CGFloat(c) * cw + cw * inset,
                                  y: CGFloat(r) * ch + ch * inset,
                                  width: cw * (1 - inset * 2),
                                  height: ch * (1 - inset * 2)))
            }
        }
        return out
    }

    // MARK: - 裁剪与修边

    /// 按归一化框裁出一块。
    static func crop(_ image: UIImage, normalized rect: CGRect) -> UIImage? {
        let src = image.normalizedUp()
        guard let cg = src.cgImage else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let px = CGRect(x: rect.minX * W, y: rect.minY * H,
                        width: max(1, rect.width * W), height: max(1, rect.height * H))
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            .integral
        guard px.width >= 2, px.height >= 2, let cropped = cg.cropping(to: px) else { return nil }
        return UIImage(cgImage: cropped, scale: src.scale, orientation: .up)
    }

    /// 把四周空白削掉，只留笔迹。
    /// 集字排版时这一步很关键：不修边，字的大小和重心会乱跳。
    static func trimInk(_ image: UIImage, threshold: UInt8 = 170, marginRatio: CGFloat = 0.02) -> UIImage {
        let src = image.normalizedUp()
        guard let cg = src.cgImage else { return src }
        let w = cg.width, h = cg.height
        guard w > 2, h > 2, let gray = grayscale(cg, width: w, height: h) else { return src }

        let sum = gray.reduce(0) { $0 + Int($1) }
        let inverted = Double(sum) / Double(gray.count) < 128

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let dark = gray[row + x] < threshold
                let isInk = inverted ? !dark : dark
                if isInk {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return src }

        let m = Int(CGFloat(max(w, h)) * marginRatio)
        let rect = CGRect(x: max(0, minX - m), y: max(0, minY - m),
                          width: min(w, maxX + 1 + m) - max(0, minX - m),
                          height: min(h, maxY + 1 + m) - max(0, minY - m)).integral
        guard rect.width > 2, rect.height > 2, let cropped = cg.cropping(to: rect) else { return src }
        return UIImage(cgImage: cropped, scale: src.scale, orientation: .up)
    }

    /// 把单字统一到正方形画布居中，方便直接排版。
    static func squarePad(_ image: UIImage, target: CGFloat = 512, background: UIColor = .clear) -> UIImage {
        let src = image.normalizedUp()
        let size = CGSize(width: target, height: target)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            background.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            let sw = src.size.width, sh = src.size.height
            guard sw > 0, sh > 0 else { return }
            let ratio = min(target / sw, target / sh) * 0.94
            let dw = sw * ratio, dh = sh * ratio
            src.draw(in: CGRect(x: (target - dw) / 2, y: (target - dh) / 2, width: dw, height: dh))
        }
    }

    // MARK: - 内部工具

    private static func readingOrder(inverted: Bool) -> (CGRect, CGRect) -> Bool {
        // 竖排右起：先按列（x 从大到小），同列再按 y 从小到大
        return { a, b in
            if abs(a.minX - b.minX) > 0.02 { return a.minX > b.minX }
            return a.minY < b.minY
        }
    }

    private static func grayscale(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    private static func runs(_ mask: [Bool], minGap: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        var gap = 0
        for i in 0..<mask.count {
            if mask[i] {
                if start == nil { start = i }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap >= minGap {
                    out.append(s..<(i - gap + 1))
                    start = nil
                    gap = 0
                }
            }
        }
        if let s = start { out.append(s..<mask.count) }
        return out.filter { $0.count > 0 }
    }

    private static func tighten(_ ink: [Bool], _ w: Int, _ h: Int,
                                _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int)
        -> (minX: Int, minY: Int, width: Int, height: Int)? {
        var minX = x1, maxX = -1, minY = y1, maxY = -1
        let xa = max(0, x0), xb = min(w, x1), ya = max(0, y0), yb = min(h, y1)
        guard xa < xb, ya < yb else { return nil }
        for y in ya..<yb {
            let row = y * w
            for x in xa..<xb where ink[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY, minX < x1, minY < y1 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }
}

extension UIImage {
    /// 把 EXIF 方向烤进像素，后续所有裁剪都基于同一个坐标系。
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
