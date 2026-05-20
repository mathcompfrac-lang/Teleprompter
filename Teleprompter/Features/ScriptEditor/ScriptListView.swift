import SwiftUI
import SwiftData

/// 脚本列表视图
struct ScriptListView: View {

    // MARK: - 环境

    @Environment(\.modelContext) private var modelContext

    // MARK: - 查询

    @Query(sort: \ScriptModel.updatedAt, order: .reverse) private var scripts: [ScriptModel]

    // MARK: - 本地状态

    @State private var editingScript: ScriptModel?   // nil=新建, 非nil=编辑
    @State private var showingNewScript = false       // 新建专用
    @State private var showingDeleteAlert = false
    @State private var scriptToDelete: ScriptModel?
    @State private var searchText = ""

    // MARK: - 回调

    var onSelectScript: ((ScriptModel) -> Void)?

    // MARK: - 主体

    var body: some View {
        List {
            if filteredScripts.isEmpty {
                emptyState
            } else {
                ForEach(filteredScripts, id: \.persistentModelID) { script in
                    ScriptRow(script: script)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectScript?(script)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                scriptToDelete = script
                                showingDeleteAlert = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                editingScript = script
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的脚本")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showingNewScript = true
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索脚本...")
        // 编辑已有脚本（通过 sheet(item:) 确保传入正确的对象）
        .sheet(item: $editingScript) { script in
            ScriptEditorView(
                script: script,
                modelContext: modelContext,
                onSave: { }
            )
        }
        // 新建脚本
        .sheet(isPresented: $showingNewScript) {
            ScriptEditorView(
                script: nil,
                modelContext: modelContext,
                onSave: { }
            )
        }
        .alert("确认删除", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let script = scriptToDelete {
                    modelContext.delete(script)
                    try? modelContext.save()
                }
            }
        } message: {
            Text("删除后将无法恢复，确定要删除吗？")
        }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("还没有脚本")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("点击右上角 + 创建你的第一个台词脚本")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .listRowBackground(Color.clear)
    }

    // MARK: - 辅助

    private var filteredScripts: [ScriptModel] {
        if searchText.isEmpty { return scripts }
        return scripts.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - 脚本行

struct ScriptRow: View {
    let script: ScriptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.title.isEmpty ? "未命名脚本" : script.title)
                .font(.headline)
                .lineLimit(1)

            if !script.content.isEmpty {
                Text(script.content)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(script.updatedAt, style: .date)
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.6))
                    .lineLimit(1)
                Text("·")
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.6))
                Text("\(script.content.count) 字")
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
