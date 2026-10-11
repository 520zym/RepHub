import { diffStats } from './diff-utils';
// 设计稿演示数据：不读取本机仓库，也不代表真实提交记录。
export const gitCommits = [
  {
    id: 'b3f8e21', vcs: 'git', message: 'feat: 增加提交历史与分支图', author: 'zym', date: '2026-10-11 20:57',
    parents: ['a1d9c3e'], refs: ['main', 'origin/main'],
    files: [
      { id: 'graph', name: 'GraphView.swift', path: 'Sources/RepHub/Core/GraphView.swift', status: 'M', added: 34, removed: 7, before: "import SwiftUI\n\nstruct GraphView: View {\n    let node: CommitNode\n    let isSelected: Bool\n\n    private var nodeColor: Color {\n        isSelected ? .accentColor : node.color\n    }\n\n    var body: some View {\n        HStack(spacing: 12) {\n            Circle()\n                .fill(nodeColor)\n                .frame(width: 8, height: 8)\n\n            Text(node.title)\n                .font(.system(size: 14))\n                .foregroundStyle(.primary)\n\n            Spacer()\n        }\n        .padding(.horizontal, 12)\n    }\n}", after: "import SwiftUI\n\nstruct GraphView: View {\n    let node: CommitNode\n    let isSelected: Bool\n\n    private var nodeColor: Color {\n        isSelected ? .accentColor : node.color\n    }\n\n    var body: some View {\n        HStack(spacing: 12) {\n            ZStack {\n                Circle()\n                    .fill(nodeColor)\n                    .frame(width: 8, height: 8)\n                if isSelected {\n                    Circle()\n                        .stroke(nodeColor, lineWidth: 2)\n                        .frame(width: 14, height: 14)\n                }\n            }\n\n            Text(node.title)\n                .font(.system(size: 14))\n                .foregroundStyle(.primary)\n\n            Spacer()\n        }\n        .padding(.horizontal, 12)\n    }\n}" },
      { id: 'store', name: 'HistoryStore.swift', path: 'Sources/RepHub/Core/HistoryStore.swift', status: 'M', added: 18, removed: 4, before: 'var commits: [Commit] = []', after: 'var commits: [Commit] = []\nvar selectedCommit: Commit?' },
      { id: 'readme', name: 'README.md', path: 'README.md', status: 'M', added: 6, removed: 1, before: '## RepHub', after: '## RepHub\n\n统一管理 Git 与 SVN 工作区。' },
    ],
  },
  {
    id: 'a1d9c3e', vcs: 'git', message: "Merge branch 'feature/history'", author: 'zym', date: '2026-10-11 16:32',
    parents: ['7c6d9a5', '9f4e2b1'], refs: [],
    files: [{ id: 'merge', name: 'HistoryPanel.jsx', path: 'src/HistoryPanel.jsx', status: 'M', added: 12, removed: 3, before: 'const rows = []', after: 'const rows = buildGraph(commits)' }],
  },
  {
    id: '9f4e2b1', vcs: 'git', message: 'feat: 支持作者与路径筛选', author: 'zym', date: '2026-10-11 14:20',
    parents: ['3c9b7e1'], refs: ['feature/history'],
    files: [{ id: 'filter', name: 'CommitFilters.swift', path: 'Sources/RepHub/UI/CommitFilters.swift', status: 'A', added: 74, removed: 0, before: '', after: 'struct CommitFilters: View {\n  @State private var query = ""\n}' }],
  },
  {
    id: '7c6d9a5', vcs: 'git', message: 'fix: 修复差异行号显示', author: 'zym', date: '2026-10-10 22:18',
    parents: ['5e3f8d2'], refs: ['fix/diff'],
    files: [{ id: 'diff', name: 'DiffLineNumberView.swift', path: 'Sources/RepHub/UI/DiffLineNumberView.swift', status: 'M', added: 8, removed: 5, before: 'Text(line.number)', after: 'Text(line.displayNumber)' }],
  },
  {
    id: '5e3f8d2', vcs: 'git', message: 'feat: 增加 SVN 历史查询', author: 'zym', date: '2026-10-10 18:05',
    parents: ['4d2a6f9'], refs: [],
    files: [{ id: 'svn', name: 'SVNProvider.swift', path: 'Sources/RepHub/SVN/SVNProvider.swift', status: 'M', added: 41, removed: 2, before: 'func status() {}', after: 'func history(limit: Int) async throws -> [Commit] {}' }],
  },
  {
    id: '4d2a6f9', vcs: 'git', message: 'refactor: 统一版本控制接口', author: 'zym', date: '2026-10-10 12:41',
    parents: ['2f8d4c6'], refs: [],
    files: [{ id: 'provider', name: 'RepositoryProvider.swift', path: 'Sources/RepHub/Core/RepositoryProvider.swift', status: 'M', added: 28, removed: 21, before: 'protocol GitProvider {}', after: 'protocol RepositoryProvider {\n  func history() async throws -> [Commit]\n}' }],
  },
  {
    id: '3c9b7e1', vcs: 'git', message: 'feat: 新增 AI 审查场景', author: 'zym', date: '2026-10-09 21:33',
    parents: ['2f8d4c6'], refs: [],
    files: [{ id: 'review', name: 'ReviewScenario.swift', path: 'Sources/RepHub/AI/ReviewScenario.swift', status: 'A', added: 56, removed: 0, before: '', after: 'struct ReviewScenario {\n  let prompt: String\n}' }],
  },
  {
    id: '2f8d4c6', vcs: 'git', message: 'feat: 支持选择提交目标', author: 'zym', date: '2026-10-09 16:20',
    parents: ['1a6e3d9'], refs: [],
    files: [{ id: 'targets', name: 'CommitTargets.swift', path: 'Sources/RepHub/Core/CommitTargets.swift', status: 'A', added: 44, removed: 0, before: '', after: 'enum CommitTarget {\n  case git\n  case svn\n}' }],
  },
  {
    id: '1a6e3d9', vcs: 'git', message: 'chore: 初始化 macOS 工程', author: 'zym', date: '2026-10-09 11:08',
    parents: ['0d3f9b2'], refs: [],
    files: [{ id: 'app', name: 'RepHubApp.swift', path: 'Sources/RepHub/RepHubApp.swift', status: 'A', added: 18, removed: 0, before: '', after: '@main\nstruct RepHubApp: App {\n  var body: some Scene { WindowGroup {} }\n}' }],
  },
  {
    id: '0d3f9b2', vcs: 'git', message: 'docs: 整理产品需求', author: 'zym', date: '2026-10-09 09:15',
    parents: [], refs: ['v0.1.0'],
    files: [{ id: 'requirements', name: 'requirements.md', path: 'docs/requirements.md', status: 'A', added: 132, removed: 0, before: '', after: '# RepHub\n\n个人 macOS 代码管理客户端。' }],
  },
]

export const svnCommits = [
  { id: 'r5482', vcs: 'svn', message: 'feat: 支持历史提交窗口', author: 'zym', date: '2026-10-11 19:20', parents: ['r5481'], refs: [], files: [{ id: 'history', name: 'HistoryController.java', path: 'src/main/java/com/efb/HistoryController.java', status: 'M', added: 25, removed: 6, before: 'return null;', after: 'return historyService.query(request);' }] },
  { id: 'r5481', vcs: 'svn', message: 'fix: 调整差异编码识别', author: 'zym', date: '2026-10-11 15:48', parents: ['r5480'], refs: [], files: [{ id: 'encoding', name: 'SvnDiffParser.java', path: 'src/main/java/com/efb/SvnDiffParser.java', status: 'M', added: 9, removed: 3, before: 'Charset.defaultCharset()', after: 'StandardCharsets.UTF_8' }] },
  { id: 'r5480', vcs: 'svn', message: 'feat: 增加提交说明生成场景', author: 'zym', date: '2026-10-10 17:05', parents: ['r5479'], refs: [], files: [{ id: 'prompt', name: 'CommitPrompt.java', path: 'src/main/java/com/efb/CommitPrompt.java', status: 'A', added: 63, removed: 0, before: '', after: 'public class CommitPrompt {\n  private String template;\n}' }] },
  { id: 'r5479', vcs: 'svn', message: 'refactor: 提取仓库连接配置', author: 'zym', date: '2026-10-10 10:32', parents: ['r5478'], refs: [], files: [{ id: 'config', name: 'RepositoryConfig.java', path: 'src/main/java/com/efb/RepositoryConfig.java', status: 'M', added: 31, removed: 22, before: 'String url;', after: 'RepositoryEndpoint endpoint;' }] },
  { id: 'r5478', vcs: 'svn', message: 'chore: 初始化 SVN 工作区', author: 'zym', date: '2026-10-09 08:40', parents: [], refs: [], files: [{ id: 'pom', name: 'pom.xml', path: 'pom.xml', status: 'A', added: 54, removed: 0, before: '', after: '<project>\n  <modelVersion>4.0.0</modelVersion>\n</project>' }] },
]

const workspaceGitCommits = [
  { id: 'd27c19a', vcs: 'git', message: 'feat: 展示双端提交目标', author: 'zym', date: '2026-10-11 18:42', parents: ['8a14f6c'], refs: ['develop', 'origin/develop'], files: [{ id: 'target', name: 'CommitTargetPicker.swift', path: 'Sources/Workspace/CommitTargetPicker.swift', status: 'M', added: 19, removed: 2, before: 'Toggle("Git", isOn: $git)', after: 'Toggle("Git", isOn: $git)\nToggle("SVN", isOn: $svn)' }] },
  { id: '8a14f6c', vcs: 'git', message: 'fix: 统一工作区状态刷新', author: 'zym', date: '2026-10-10 16:14', parents: [], refs: ['v0.2.0'], files: [{ id: 'refresh', name: 'WorkspaceStore.swift', path: 'Sources/Workspace/WorkspaceStore.swift', status: 'M', added: 8, removed: 6, before: 'func refreshGit()', after: 'func refresh() async' }] },
]

const legacySvnCommits = [
  { id: 'r6214', vcs: 'svn', message: 'fix: 兼容旧 SVN 服务连接', author: 'zym', date: '2026-10-11 17:06', parents: ['r6213'], refs: [], files: [{ id: 'tls', name: 'LegacySvnConnection.java', path: 'src/main/java/LegacySvnConnection.java', status: 'M', added: 12, removed: 4, before: 'connect(url);', after: 'connect(endpoint, compatibility);' }] },
  { id: 'r6213', vcs: 'svn', message: 'feat: 增加工作副本状态读取', author: 'zym', date: '2026-10-10 11:32', parents: [], refs: [], files: [{ id: 'wc', name: 'WorkingCopyStatus.java', path: 'src/main/java/WorkingCopyStatus.java', status: 'A', added: 46, removed: 0, before: '', after: 'public final class WorkingCopyStatus {}' }] },
]

// 根据当前演示工作区切换不同的模拟历史；不读取或映射用户真实仓库。
export function getDemoHistory(repoKey, vcs) {
  const key = String(repoKey || '').toLowerCase()
  if (key.includes('legacy') || key.includes('old-svn')) return vcs === 'svn' ? legacySvnCommits : []
  if (key.includes('workspace') || key.includes('adapter')) return vcs === 'git' ? workspaceGitCommits : svnCommits.slice(0, 2)
  return vcs === 'svn' ? svnCommits : gitCommits
}

for (const commits of [gitCommits, svnCommits, workspaceGitCommits, legacySvnCommits]) {
  for (const commit of commits) {
    for (const file of commit.files) Object.assign(file, diffStats(file.before, file.after));
  }
}
