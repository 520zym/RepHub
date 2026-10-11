import SwiftUI
import RepositoryApplication
import VersionControlCore

/// 原生设置页中的 SVN 旧 TLS 端点管理；规则更新后由调用方决定何时刷新仓库。
public struct RepositoryConnectionSettingsView: View {
    private let settings: RepositoryConnectionSettings
    private let onChange: (() -> Void)?
    @State private var address = ""
    @State private var rules: [RepositoryEndpointPolicy] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    public init(settings: RepositoryConnectionSettings, onChange: (() -> Void)? = nil) {
        self.settings = settings
        self.onChange = onChange
    }

    public var body: some View {
        Form {
            Section("旧 TLS 兼容") {
                Text("仅为明确指定的 SVN HTTPS 服务器放宽协议下限，允许 TLS 1.0–1.3 协商；证书与主机名校验仍会保留。旧协议安全性较低，仅用于指定的旧服务器。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("服务器地址", text: $address, prompt: Text("https://svn.example.com:8443"))
                        .labelsHidden()
                        .accessibilityLabel("SVN HTTPS 服务器地址")
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSaving)
                    Button("加入旧 TLS 兼容") { save(address: address, enabled: true) }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }

                if rules.isEmpty && errorMessage == nil {
                    Text("当前没有旧 TLS 兼容规则，所有连接使用现代协商。")
                        .foregroundStyle(.secondary)
                }

                ForEach(rules) { rule in
                    HStack {
                        Text(rule.id).textSelection(.enabled)
                        Spacer()
                        Text("旧 TLS 兼容").foregroundStyle(.secondary)
                        Button(role: .destructive) { save(address: "https://\(rule.id)", enabled: false) } label: {
                            Label("删除规则", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSaving)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("SVN 连接")
        .task { await reload() }
    }

    private func reload() async {
        do {
            rules = try await settings.rules()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(address: String, enabled: Bool) {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await settings.setLegacyCompatibility(for: address, enabled: enabled)
                self.address = ""
                await reload()
                onChange?()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
