import UIKit

/// 单字图片的落盘位置：<Documents>/Library/<uuid>.png
/// 打开 UIFileSharingEnabled 后，可以用「文件」App 或 iTunes 直接往里拷图片。
enum ImageStore {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var root: URL {
        let dir = documents.appendingPathComponent("Library", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(_ fileName: String) -> URL {
        root.appendingPathComponent(fileName)
    }

    static func newFileName() -> String {
        UUID().uuidString + ".png"
    }

    @discardableResult
    static func save(_ image: UIImage, fileName: String? = nil) -> String? {
        let name = fileName ?? newFileName()
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: url(name), options: .atomic)
            cache.setObject(image, forKey: name as NSString)
            return name
        } catch {
            return nil
        }
    }

    static func load(_ fileName: String) -> UIImage? {
        if let hit = cache.object(forKey: fileName as NSString) { return hit }
        guard let img = UIImage(contentsOfFile: url(fileName).path) else { return nil }
        cache.setObject(img, forKey: fileName as NSString)
        return img
    }

    static func delete(_ fileName: String) {
        cache.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: url(fileName))
    }

    /// 缩略图，列表里用，避免一次解码一堆大图。
    static func thumbnail(_ fileName: String, maxSide: CGFloat = 220) -> UIImage? {
        let key = "thumb-\(fileName)-\(Int(maxSide))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = load(fileName) else { return nil }
        let size = img.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return img }
        let ratio = maxSide / longest
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        cache.setObject(out, forKey: key)
        return out
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        return c
    }()
}
