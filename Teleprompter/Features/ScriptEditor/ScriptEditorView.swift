import SwiftUI
import SwiftData

/// 脚本编辑器视图
struct ScriptEditorView: View {

    // MARK: - 环境

    @Environment(\.dismiss) private var dismiss

    // MARK: - 输入

    var script: ScriptModel?
    var modelContext: ModelContext
    var onSave: (() -> Void)?

    // MARK: - 本地状态

    @State private var title: String
    @State private var content: String
    @State private var showingCancelAlert = false
    @State private var hasChanges = false
    @FocusState private var isContentFocused: Bool

    // MARK: - 直接通过 init 初始化（避免 sheet 复用导致状态错乱）

    init(script: ScriptModel?, modelContext: ModelContext, onSave: (() -> Void)?) {
        self.script = script
        self.modelContext = modelContext
        self.onSave = onSave
        _title = State(initialValue: script?.title ?? "")
        _content = State(initialValue: script?.content ?? "")
    }

    // MARK: - 主体

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 标题输入
                TextField("脚本标题（选填）", text: $title)
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .onChange(of: title) { _, _ in hasChanges = true }

                Divider()

                // 内容编辑器
                ZStack(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("在此输入台词内容...\n\n提示：\n• 每行建议写一个句子\n• 可以用空行分隔段落\n• 保存后可在提词器中使用")
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $content)
                        .font(.body)
                        .padding(.horizontal, 4)
                        .focused($isContentFocused)
                        .onChange(of: content) { _, _ in hasChanges = true }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // 字数统计
                HStack {
                    Spacer()
                    Text("\(content.count) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing)
                }
                .padding(.vertical, 6)
            }
            .navigationTitle(script == nil ? "新建脚本" : "编辑脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        if hasChanges {
                            showingCancelAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveScript()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.isEmpty && content.isEmpty)
                }

                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("完成") {
                            isContentFocused = false
                        }
                    }
                }
            }
            .alert("放弃更改？", isPresented: $showingCancelAlert) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃", role: .destructive) { dismiss() }
            } message: {
                Text("你有未保存的更改，确定要离开吗？")
            }
            .onAppear {
                // 新脚本自动聚焦标题
                if script == nil {
                    isContentFocused = true
                }
            }
        }
    }

    // MARK: - 保存

    private func saveScript() {
        if let existingScript = script {
            // 更新现有脚本
            existingScript.title = title
            existingScript.content = content
            existingScript.updatedAt = Date()
        } else {
            // 创建新脚本
            let newScript = ScriptModel(
                title: title,
                content: content,
                createdAt: Date(),
                updatedAt: Date()
            )
            modelContext.insert(newScript)
        }

        try? modelContext.save()
        onSave?()
        dismiss()
    }
}
