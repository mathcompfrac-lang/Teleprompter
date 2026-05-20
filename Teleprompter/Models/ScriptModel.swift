import Foundation
import SwiftData

@Model
final class ScriptModel {
    /// 脚本标题
    var title: String
    /// 脚本正文内容
    var content: String
    /// 创建时间
    var createdAt: Date
    /// 最后修改时间
    var updatedAt: Date
    /// 排序索引
    var sortOrder: Int

    init(
        title: String = "",
        content: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}
