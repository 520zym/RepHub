import RepositoryApplication
import DesignSystem
import SwiftUI
import VersionControlCore

/// 迁移预检完成后的作者映射编辑器。编辑实时回传给迁移计划，保存按钮才写入本机通讯录。
public struct MigrationAuthorMappingEditor: View {
    public let sourceURL: String
    public let authors: [String: MigrationAuthor]
    public let onUpdate: (String, MigrationAuthor) -> Void
    @Bindable private var store: MigrationAuthorDirectoryStore
    private let palette: AppPalette
    @State private var workingAuthors: [String: MigrationAuthor]
    @State private var showsDirectory = false
    @State private var newSuffix = ""
    @State private var message: String?

    public init(sourceURL: String, authors: [String: MigrationAuthor],
                onUpdate: @escaping (String, MigrationAuthor) -> Void,
                store: MigrationAuthorDirectoryStore, palette: AppPalette) {
        self.sourceURL = sourceURL
        self.authors = authors
        self.onUpdate = onUpdate
        self.store = store
        self.palette = palette
        _workingAuthors = State(initialValue: authors)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("作者映射").font(.system(size: 13, weight: .semibold))
                    Text("Git 名称默认沿用 SVN 提交人；邮箱由本地名和可管理的后缀组成。@authors.invalid 是明确占位值。")
                        .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Button("管理通讯录") { showsDirectory = true }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
            }

            HStack(spacing: 10) {
                Menu("统一本次邮箱后缀") {
                    ForEach(store.emailSuffixes, id: \.self) { suffix in
                        Button("@\(suffix)") {
                            for source in workingAuthors.keys.sorted() {
                                guard let author = workingAuthors[source] else { continue }
                                let parts = store.emailParts(for: author, source: source)
                                replace(source, name: author.name, localPart: parts.localPart, suffix: suffix)
                            }
                            message = "本次计划已统一为 @\(suffix)，保存或生成预览后写入通讯录。"
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("从通讯录填入") {
                    let resolved = store.resolve(authors: workingAuthors, sourceURL: sourceURL)
                    for source in resolved.keys.sorted() {
                        if let author = resolved[source] { update(source, author) }
                    }
                    message = "已填入此 SVN 来源的作者映射。"
                }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true))
                Spacer()
            }

            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Text("SVN 账号").frame(width: 120, alignment: .leading)
                    Text("Git 提交人").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    Text("邮箱名称").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    Text("邮箱后缀").frame(width: 150, alignment: .leading)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondaryText)
                ForEach(workingAuthors.keys.sorted(), id: \.self) { source in
                    authorRow(source, author: workingAuthors[source] ?? .init(name: source, email: ""))
                }
            }
            .padding(10)
            .background(palette.sidebar.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                TextField("新增邮箱后缀，例如 company.com", text: $newSuffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
                Button("添加后缀") { addSuffix() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                Spacer()
                Button("保存当前映射") { save() }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .primary, compact: true))
            }
            Text("保存当前映射；生成预览时也会自动保存。")
                .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
            if let message { showFeedback(message, error: store.feedback?.kind == .error) }
            else if let notice = store.feedback { showFeedback(notice.message, error: notice.kind == .error) }
        }
        .sheet(isPresented: $showsDirectory) {
            MigrationAuthorDirectorySettingsView(store: store, palette: palette)
                .frame(minWidth: 700, minHeight: 520)
        }
        .onChange(of: authors) { _, next in
            // 外部重新预检或切换来源时才同步；输入变更已在下方写入 workingAuthors。
            if next != workingAuthors { workingAuthors = next }
        }
    }

    private func authorRow(_ source: String, author: MigrationAuthor) -> some View {
        let parts = store.emailParts(for: author, source: source)
        return HStack(spacing: 8) {
            Text(source.isEmpty ? "SVN 未知作者" : source)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
            TextField("Git 名称", text: binding(source, keyPath: \.name))
                .textFieldStyle(.roundedBorder).frame(minWidth: 130)
            TextField("邮箱前缀", text: Binding(
                get: { parts.localPart },
                set: { replace(source, name: author.name, localPart: $0, suffix: parts.suffix) }
            ))
            .textFieldStyle(.roundedBorder).frame(minWidth: 120)
            Picker("邮箱后缀", selection: Binding(
                get: { parts.suffix },
                set: { replace(source, name: author.name, localPart: parts.localPart, suffix: $0) }
            )) {
                ForEach((store.emailSuffixes.contains(parts.suffix) ? store.emailSuffixes : [parts.suffix] + store.emailSuffixes), id: \.self) { Text("@\($0)").tag($0) }
            }
            .labelsHidden().frame(width: 150)
        }
    }

    private func binding(_ source: String, keyPath: WritableKeyPath<MigrationAuthor, String>) -> Binding<String> {
        Binding(get: { workingAuthors[source]?[keyPath: keyPath] ?? "" }, set: { value in
            var author = workingAuthors[source] ?? .init(name: source, email: "")
            author[keyPath: keyPath] = value
            update(source, author)
        })
    }

    private func replace(_ source: String, name: String, localPart: String, suffix: String) {
        // 允许输入过程存在空前缀或半成品；点击保存时由 store 严格校验并可见报错。
        update(source, .init(name: name, email: "\(localPart)@\(suffix)"))
    }

    private func update(_ source: String, _ author: MigrationAuthor) {
        workingAuthors[source] = author
        onUpdate(source, author)
    }

    private func addSuffix() {
        do {
            try store.addEmailSuffix(newSuffix)
            newSuffix = ""
            message = store.feedback?.message
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do {
            try store.save(authors: workingAuthors, sourceURL: sourceURL)
            message = store.feedback?.message
        } catch { message = error.localizedDescription }
    }

    @ViewBuilder private func showFeedback(_ text: String, error: Bool) -> some View {
        Label(text, systemImage: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(error ? palette.removed : palette.accent)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background((error ? palette.removed : palette.selection).opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
