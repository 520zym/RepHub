import RepositoryApplication
import DesignSystem
import SwiftUI
import VersionControlCore

/// 可由设置页挂载的迁移作者通讯录。
public struct MigrationAuthorDirectorySettingsView: View {
    @Bindable private var store: MigrationAuthorDirectoryStore
    private let palette: AppPalette
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var suffix = ""
    @State private var message: String?

    public init(store: MigrationAuthorDirectoryStore, palette: AppPalette) {
        self.store = store
        self.palette = palette
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    suffixes
                    contacts
                }
                .padding(20)
            }
            if let text = message ?? store.feedback?.message {
                HStack { Label(text, systemImage: store.feedback?.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.system(size: 11)); Spacer() }
                    .foregroundStyle(store.feedback?.kind == .error ? palette.removed : palette.accent)
                    .padding(.horizontal, 20).padding(.vertical, 9).background(palette.sidebar.opacity(0.5))
            }
        }
        .background(palette.background).foregroundStyle(palette.text)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.text.rectangle").foregroundStyle(palette.accent)
                .frame(width: 32, height: 32).background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("迁移作者通讯录").font(.system(size: 16, weight: .semibold))
                Text("按 SVN 服务端隔离保存，不保存 URL 中的账号或密码。")
                    .font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true)).accessibilityLabel("关闭作者通讯录")
        }
        .padding(.horizontal, 20).padding(.vertical, 15).background(palette.surface)
    }

    private var suffixes: some View {
        section(title: "邮箱后缀", subtitle: "创建或选择统一的域名；新作者默认使用当前默认后缀。") {
            HStack(spacing: 8) {
                TextField("例如 company.com", text: $suffix).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("添加") { addSuffix() }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                Spacer()
            }
            HStack(spacing: 8) {
                Button("将占位邮箱换为默认后缀") { applyDefaultSuffix(onlyPlaceholder: true) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                Button("统一替换全部保存邮箱") { applyDefaultSuffix(onlyPlaceholder: false) }
                    .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
                Text("第二项会覆盖现有邮箱后缀。")
                    .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
            }
            FlowLayout(spacing: 7) {
                ForEach(store.emailSuffixes, id: \.self) { value in
                    HStack(spacing: 5) {
                        Button("@\(value)") { setDefault(value) }
                            .buttonStyle(WorkbenchButtonStyle(palette: palette, role: value == store.defaultEmailSuffix ? .primary : .secondary, compact: true))
                        if value != "authors.invalid" {
                            Button { removeSuffix(value) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(palette.secondaryText).accessibilityLabel("移除 @\(value)")
                        }
                    }
                }
            }
        }
    }

    private var contacts: some View {
        section(title: "已保存映射", subtitle: "同一用户名在不同 SVN 服务端独立保存。") {
            TextField("搜索 SVN 用户名、Git 名称、邮箱或服务端", text: $search)
                .textFieldStyle(.roundedBorder)
            let rows = filteredRecords
            if rows.isEmpty {
                ContentUnavailableView("还没有匹配的作者映射", systemImage: "person.crop.circle.badge.questionmark", description: Text("在迁移预检页保存作者映射后会显示在这里。"))
                    .frame(maxWidth: .infinity).padding(.vertical, 25)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { record in
                        MigrationAuthorContactEditorRow(record: record, store: store, palette: palette) { text in message = text }
                    }
                }
            }
        }
    }

    private var filteredRecords: [MigrationAuthorDirectoryStore.Record] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.records }
        return store.records.filter { [ $0.scope, $0.source, $0.author.name, $0.author.email ].joined(separator: " ").lowercased().contains(query) }
    }

    private func section<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
            content()
        }
        .padding(15).background(palette.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func addSuffix() { do { try store.addEmailSuffix(suffix); suffix = ""; message = store.feedback?.message } catch { message = error.localizedDescription } }
    private func setDefault(_ value: String) { do { try store.setDefaultEmailSuffix(value); message = store.feedback?.message } catch { message = error.localizedDescription } }
    private func removeSuffix(_ value: String) { do { try store.removeEmailSuffix(value); message = store.feedback?.message } catch { message = error.localizedDescription } }
    private func applyDefaultSuffix(onlyPlaceholder: Bool) { do { _ = try store.applyDefaultSuffixToSavedAuthors(onlyPlaceholder: onlyPlaceholder); message = store.feedback?.message } catch { message = error.localizedDescription } }
}

private struct MigrationAuthorContactEditorRow: View {
    let record: MigrationAuthorDirectoryStore.Record
    @Bindable var store: MigrationAuthorDirectoryStore
    let palette: AppPalette
    let completed: (String) -> Void
    @State private var name: String
    @State private var email: String

    init(record: MigrationAuthorDirectoryStore.Record, store: MigrationAuthorDirectoryStore, palette: AppPalette, completed: @escaping (String) -> Void) {
        self.record = record; self.store = store; self.palette = palette; self.completed = completed
        _name = State(initialValue: record.author.name)
        _email = State(initialValue: record.author.email)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.source.isEmpty ? "SVN 未知作者" : record.source).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(record.scope).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
            }.frame(width: 205, alignment: .leading)
            TextField("Git 名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("邮箱", text: $email).textFieldStyle(.roundedBorder)
            Button("保存") { save() }.buttonStyle(WorkbenchButtonStyle(palette: palette, role: .secondary, compact: true))
            Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                .buttonStyle(WorkbenchButtonStyle(palette: palette, role: .quiet, compact: true)).accessibilityLabel("删除 \(record.source) 的映射")
        }
        .padding(9).background(palette.sidebar.opacity(0.38), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onChange(of: record.author) { previous, next in
            // 批量更新刷新未编辑的行，同时保护还没保存的手工草稿。
            if name == previous.name && email == previous.email {
                name = next.name; email = next.email
            }
        }
    }

    private func save() { do { try store.update(source: record.source, scope: record.scope, author: .init(name: name, email: email)); completed(store.feedback?.message ?? "已保存。") } catch { completed(error.localizedDescription) } }
    private func remove() { do { try store.remove(source: record.source, scope: record.scope); completed(store.feedback?.message ?? "已删除。") } catch { completed(error.localizedDescription) } }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat
    init(spacing: CGFloat) { self.spacing = spacing }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var point = CGPoint.zero; var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x + size.width > width, point.x > 0 { point.x = 0; point.y += lineHeight + spacing; lineHeight = 0 }
            point.x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? point.x, height: point.y + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin; var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX { point.x = bounds.minX; point.y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: point, proposal: ProposedViewSize(size)); point.x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
    }
}
