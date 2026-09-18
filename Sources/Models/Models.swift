import Foundation
import SwiftData

/// 一部碑帖 / 字帖，作为单字的来源。
@Model
final class SourceBook {
    var title: String
    var calligrapher: String
    var script: String          // 楷 / 行 / 草 / 隶 / 篆
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CharacterEntry.book)
    var entries: [CharacterEntry] = []

    init(title: String, calligrapher: String = "", script: String = "楷", createdAt: Date = .now) {
        self.title = title
        self.calligrapher = calligrapher
        self.script = script
        self.createdAt = createdAt
    }
}

/// 一个字库里的一张单字图。
@Model
final class CharacterEntry {
    var character: String       // 该字对应的汉字，未鉴定时为空串
    var fileName: String        // 存在 Documents/Library 下的 PNG 文件名
    var createdAt: Date
    var book: SourceBook?

    init(character: String, fileName: String, book: SourceBook? = nil, createdAt: Date = .now) {
        self.character = character
        self.fileName = fileName
        self.book = book
        self.createdAt = createdAt
    }

    var displayCharacter: String {
        character.isEmpty ? "？" : character
    }
}
