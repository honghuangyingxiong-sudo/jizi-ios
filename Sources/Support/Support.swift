import UIKit
import Photos

enum PhotosSaver {
    enum Outcome {
        case saved
        case denied
        case failed(String)
    }

    static func save(_ image: UIImage) async -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 写到临时目录，给分享面板用（导出 PNG 文件而不是内存图）。
    static func temporaryPNG(_ image: UIImage, name: String = "集字.png") -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
