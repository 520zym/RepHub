import { diffStats } from './diff-utils';
export const initialRepositories = [
  { id: 'rephub', name: 'RepHub', path: '~/Projects/RepHub', vcs: ['git', 'svn'], branch: 'main', description: 'Git 与 SVN 共管', updated: '刚刚' },
  { id: 'workspace', name: 'WorkspaceKit', path: '~/Projects/WorkspaceKit', vcs: ['git'], branch: 'develop', description: 'Git 仓库', updated: '昨天' },
  { id: 'legacy', name: 'LegacyService', path: '~/Projects/LegacyService', vcs: ['svn'], branch: 'trunk', description: 'SVN 工作副本', updated: '10 月 9 日' },
];

export const workspaceFiles = [
  {
    id: 'targets', name: 'CommitTargets.swift', path: 'Sources/RepHub/Core/CommitTargets.swift', status: 'M', added: 12, removed: 2,
    before: `import Foundation

enum CommitTarget: String, CaseIterable {
    case git
    case svn
}

struct CommitService {
    private let settings: UserSettings

    init(settings: UserSettings) {
        self.settings = settings
    }

    // 根据工作区配置选择提交目标
    func selectedTargets() -> [CommitTarget] {
        return [.git]
    }

    func canCommit() -> Bool {
        return true
    }
}`,
    after: `import Foundation

enum CommitTarget: String, CaseIterable {
    case git
    case svn
}

struct CommitService {
    private let settings: UserSettings

    init(settings: UserSettings) {
        self.settings = settings
    }

    // 根据工作区配置选择提交目标
    func selectedTargets() -> [CommitTarget] {
        var targets: [CommitTarget] = []

        if settings.submitToGit {
            targets.append(.git)
        }
        if settings.submitToSVN {
            targets.append(.svn)
        }

        return targets
    }

    func canCommit() -> Bool {
        return !selectedTargets().isEmpty
    }
}`,
  },
  {
    id: 'repository', name: 'Repository.swift', path: 'Sources/RepHub/Core/Repository.swift', status: 'M', added: 7, removed: 1,
    before: `import Foundation

struct Repository: Identifiable {
    let id: UUID
    let name: String
    let workingDirectory: URL
    let provider: GitProvider

    var displayName: String {
        name.isEmpty ? workingDirectory.lastPathComponent : name
    }
}`,
    after: `import Foundation

struct Repository: Identifiable {
    let id: UUID
    let name: String
    let workingDirectory: URL
    let bindings: [VersionControlBinding]

    var availableTargets: [CommitTarget] {
        bindings.map(\.target)
    }

    var isSharedWorkingCopy: Bool {
        bindings.count > 1
    }

    var displayName: String {
        name.isEmpty ? workingDirectory.lastPathComponent : name
    }
}`,
  },
  {
    id: 'readme', name: 'README.md', path: 'README.md', status: 'M', added: 5, removed: 1,
    before: `# RepHub

一个为 macOS 开发者设计的代码管理客户端。

## 基本功能

- 查看 Git 提交历史
- 阅读代码差异
- 提交本地改动

## 技术方向

Swift · SwiftUI · macOS`,
    after: `# RepHub

一个为 macOS 开发者设计的代码管理客户端。

## 基本功能

- 在同一个工作区管理 Git 与 SVN
- 查看提交历史与 Git 分支图
- 阅读代码差异
- 选择提交到 Git、SVN 或两个目标
- 使用 AI 审查代码、生成提交说明
- 自定义 AI 场景与提示词

## 技术方向

Swift · SwiftUI · macOS`,
  },
];

export function prepareLocalRepository(repo) {
  if (!repo.initialized) return { ...repo, updated: '刚刚', description: '自动识别的本地目录（模拟）' };
  const after = `# ${repo.name}\n\n本地项目的示例说明文件。\n\n这是交互原型中的示例内容，不来自本地磁盘。`;
  const files = [{ id: 'readme', name: 'README.md', path: 'README.md', status: 'A', before: '', after, ...diffStats('', after) }];
  return { ...repo, files, updated: '刚刚', description: '新建版本控制（模拟）' };
}

export function newWorkingState(repo) {
  const files = repo.files || workspaceFiles;
  const pending = {};
  repo.vcs.forEach(vcs => { pending[vcs] = repo.initialized && vcs === 'svn' ? [] : files.map(f => f.id); });
  const commits = repo.initialized && repo.vcs.includes('svn')
    ? [{ id: 'r1', vcs: 'svn', message: `初始导入 ${repo.name}`, author: 'zym', date: '刚刚', parents: [], refs: [], files }]
    : [];
  const message = repo.initialized
    ? `${repo.name} 已建立 ${repo.vcs.map(v => v.toUpperCase()).join(' + ')} 管理${repo.vcs.includes('git') ? '；Git 文件等待首次提交' : ''}${repo.vcs.includes('svn') ? '；SVN 已导入并检出' : ''}（模拟）`
    : `已打开 ${repo.name}，识别到 ${repo.vcs.map(v => v.toUpperCase()).join(' + ')}（模拟）`;
  return { pending, commits, logs: [{ time: new Date().toLocaleTimeString('zh-CN', { hour12: false }), message, status: 'success' }] };
}

workspaceFiles.forEach(file => Object.assign(file, diffStats(file.before, file.after)));
