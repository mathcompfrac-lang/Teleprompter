import SwiftUI
import SwiftData

@main
struct TeleprompterApp: App {

    // MARK: - 数据容器

    private let modelContainer: ModelContainer

    // MARK: - 初始化

    init() {
        do {
            modelContainer = try ModelContainer(for: ScriptModel.self, SettingsModel.self)
        } catch {
            fatalError("无法初始化 ModelContainer: \(error)")
        }
    }

    // MARK: - 场景

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .preferredColorScheme(nil) // 跟随系统
        }
    }
}
