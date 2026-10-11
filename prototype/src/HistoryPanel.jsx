import { useEffect, useMemo, useState } from 'react'
import {
  ArrowsInSimple, ArrowsOutSimple, CaretDown, CaretRight, Check,
  Copy, File, GitBranch, GitCommit, MagnifyingGlass, Sparkle, Tag, X,
} from '@phosphor-icons/react'
import { getDemoHistory } from './historyData'
import './history.css'

function branchGroupsFor(repoKey) {
  const workspace = String(repoKey || '').toLowerCase().includes('workspace')
    || String(repoKey || '').toLowerCase().includes('adapter')
  const primary = workspace ? 'develop' : 'main'
  return { primary, groups: [
    { label: '本地', items: [{ name: primary, tone: 'green' }, ...(workspace ? [] : [{ name: 'feature', tone: 'purple', nested: 'history' }, { name: 'fix', tone: 'coral', nested: 'diff' }])] },
    { label: '远端', items: [{ name: 'origin', tone: 'slate', nested: primary }] },
  ] }
}

function makeGraph(commits) {
  const nodeIndex = new Map(commits.map((commit, index) => [commit.id, index]))
  const lanes = new Map()
  let nextLane = 0
  const nodeRows = commits.map((commit, index) => {
    if (!lanes.has(commit.id)) lanes.set(commit.id, nextLane++)
    const lane = lanes.get(commit.id)
    commit.parents.forEach((parent, parentIndex) => {
      if (nodeIndex.has(parent) && !lanes.has(parent)) lanes.set(parent, parentIndex === 0 ? lane : nextLane++)
    })
    return { commit, index, lane }
  })
  const edges = nodeRows.flatMap(({ commit, index, lane }) => commit.parents.flatMap((parent, parentIndex) => {
    const parentIndexInList = nodeIndex.get(parent)
    if (parentIndexInList === undefined) return []
    return [{ fromRow: index, toRow: parentIndexInList, fromLane: lane, toLane: lanes.get(parent), key: `${commit.id}-${parent}-${parentIndex}` }]
  }))
  return { nodeRows, edges, laneCount: nextLane }
}

function Graph({ graph }) {
  const width = 58
  const laneX = (lane) => 16 + lane * 12
  return <svg className="hist-graph" width={width} height={graph.nodeRows.length * 30} viewBox={`0 0 ${width} ${graph.nodeRows.length * 30}`} aria-label="Git 提交分支图">
    {graph.edges.map((edge) => {
      const y1 = edge.fromRow * 30 + 15
      const y2 = edge.toRow * 30 + 15
      const x1 = laneX(edge.fromLane)
      const x2 = laneX(edge.toLane)
      const bend = Math.max(14, (y2 - y1) * .35)
      return <path key={edge.key} d={`M ${x1} ${y1} C ${x1} ${y1 + bend}, ${x2} ${y2 - bend}, ${x2} ${y2}`} className={`hist-line hist-line-${edge.fromLane % 4}`} />
    })}
    {graph.nodeRows.map((node) => <circle key={node.commit.id} cx={laneX(node.lane)} cy={node.index * 30 + 15} r="5" className={`hist-node hist-node-${node.lane % 4}`} />)}
  </svg>
}

function Status({ value }) { return <span className={`hist-status hist-status-${value}`}>{value}</span> }

export function HistoryPanel({
  vcs = 'git', onVcsChange, expanded = false, onExpand, onClose, onOpenDiff, onReview,
  extraCommits = [], baseCommits, primaryBranch = 'main', repoKey = 'rephub', availableVcs = ['git', 'svn'], renderDiff,
}) {
  const [query, setQuery] = useState('')
  const [branch, setBranch] = useState('all')
  const [branchQuery, setBranchQuery] = useState('')
  const [selectedId, setSelectedId] = useState(null)
  const [selectedFileId, setSelectedFileId] = useState(null)
  const [copied, setCopied] = useState(false)
  const branchConfig = useMemo(() => baseCommits ? { primary: primaryBranch, groups: [{ label: '本地', items: [{ name: primaryBranch, tone: 'green' }] }] } : branchGroupsFor(repoKey), [repoKey, baseCommits, primaryBranch])
  const allCommits = useMemo(() => {
    const seenRefs = new Set()
    const extras = extraCommits.filter((commit) => commit.vcs === vcs).map(commit => ({...commit, refs: (commit.refs || []).filter(ref => { if (seenRefs.has(ref)) return false; seenRefs.add(ref); return true; })}))
    const advancedRefs = new Set(extras.flatMap((commit) => commit.refs || []))
    const standard = (baseCommits || getDemoHistory(repoKey, vcs))
      .map((commit) => advancedRefs.size ? { ...commit, refs: commit.refs.filter((ref) => !advancedRefs.has(ref)) } : commit)
    return [...extras, ...standard]
  }, [vcs, extraCommits, repoKey, baseCommits])
  const branchCommitIds = useMemo(() => {
    if (branch === 'all') return null
    const byId = new Map(allCommits.map((commit) => [commit.id, commit]))
    const tips = allCommits.filter((commit) => commit.refs.includes(branch)).map((commit) => commit.id)
    const allowed = new Set()
    const visit = (id) => {
      if (allowed.has(id) || !byId.has(id)) return
      allowed.add(id)
      byId.get(id).parents.forEach(visit)
    }
    tips.forEach(visit)
    return allowed
  }, [allCommits, branch])
  const filtered = useMemo(() => allCommits.filter((commit) => {
    const q = query.trim().toLowerCase()
    const matchesQuery = !q || [commit.message, commit.author, commit.id].some((item) => item.toLowerCase().includes(q))
    const matchesBranch = !branchCommitIds || branchCommitIds.has(commit.id)
    return matchesQuery && matchesBranch
  }), [allCommits, query, branchCommitIds])
  const graph = useMemo(() => makeGraph(filtered), [filtered])
  const selected = filtered.find((commit) => commit.id === selectedId) || filtered[0]
  const selectedFile = selected?.files.find((file) => file.id === selectedFileId) || selected?.files[0]

  useEffect(() => { setQuery(''); setBranch('all'); setBranchQuery(''); setSelectedId(null); setSelectedFileId(null); setCopied(false) }, [repoKey, vcs])
  useEffect(() => { if (selected && !selectedId) setSelectedId(selected.id) }, [selected, selectedId])

  const chooseCommit = (commit) => { setSelectedId(commit.id); setSelectedFileId(commit.files[0]?.id || null) }
  const canSwitch = (type) => availableVcs.includes(type)
  const branchVisible = (name) => name.toLowerCase().includes(branchQuery.trim().toLowerCase())
  const copyCommitId = async () => {
    if (!selected) return
    try { await navigator.clipboard?.writeText(selected.id) } catch { /* 演示稿中保持静默，仍提供视觉反馈 */ }
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1200)
  }

  return <section className={`history-panel ${expanded ? 'history-expanded' : 'history-compact'}`} aria-label="提交历史（设计稿模拟数据）">
    <header className="history-topbar">
      <div className="history-title"><GitCommit size={17} weight="duotone" /> <span>提交历史</span><small>模拟数据</small></div>
      <div className="history-vcs-tabs" role="tablist" aria-label="版本控制类型">
        {canSwitch('git') && <button className={vcs === 'git' ? 'is-active' : ''} onClick={() => onVcsChange?.('git')}><GitBranch size={15} weight="bold" /> Git</button>}
        {canSwitch('svn') && <button className={vcs === 'svn' ? 'is-active' : ''} onClick={() => onVcsChange?.('svn')}><span className="hist-svn-mark">SV</span> SVN</button>}
      </div>
      <div className="history-top-actions">
        <button className="hist-icon-button" title={expanded ? '收起历史' : '放大历史'} onClick={() => onExpand?.(!expanded)}>{expanded ? <ArrowsInSimple size={17} /> : <ArrowsOutSimple size={17} />}</button>
        {!expanded && <button className="hist-icon-button" title="关闭历史" onClick={onClose}><X size={17} /></button>}
      </div>
    </header>

    <div className="history-main">
      <aside className="history-branches">
        <div className="hist-branch-heading"><span>分支</span></div>
        <label className="hist-search hist-branch-search"><MagnifyingGlass size={15} /><input value={branchQuery} onChange={(event) => setBranchQuery(event.target.value)} placeholder="搜索分支或标签…" /></label>
        {vcs === 'git' ? <>
          {branchConfig.groups.map((group) => <div className="hist-branch-group" key={group.label}>
            <div className="hist-group-label"><CaretDown size={13} />{group.label}</div>
            {group.items.filter((item) => branchVisible(item.nested ? `${item.name}/${item.nested}` : item.name)).map((item) => { const filterKey = item.nested ? `${item.name}/${item.nested}` : item.name; return <button key={item.name} className={`hist-branch-item ${branch === filterKey ? 'is-selected' : ''}`} onClick={() => setBranch(branch === filterKey ? 'all' : filterKey)}>
              <GitBranch size={15} className={`hist-tone-${item.tone}`} weight="bold" /><span>{item.name}</span>{item.nested && <span className="hist-nested"><CaretRight size={12} />{item.nested}</span>}
            </button>})}
          </div>)}
          {!baseCommits && branchVisible('v0.1.0') && <div className="hist-branch-group"><div className="hist-group-label"><CaretDown size={13} />标签</div><button className={`hist-branch-item ${branch === 'v0.1.0' ? 'is-selected' : ''}`} onClick={() => setBranch(branch === 'v0.1.0' ? 'all' : 'v0.1.0')}><Tag size={15} weight="bold" /><span>v0.1.0</span></button></div>}
        </> : <div className="hist-empty-branches"><span className="hist-svn-mark">SV</span><p>SVN 以修订号展示历史，不含分支图。</p></div>}
      </aside>

      <div className="history-list-area">
        <div className="hist-list-toolbar">
          <label className="hist-search"><MagnifyingGlass size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索提交、作者、版本号…" /></label>
          {vcs === 'git' && <button className="hist-filter" onClick={() => setBranch(branch === 'all' ? branchConfig.primary : 'all')}><GitBranch size={15} />{branch === 'all' ? '所有分支' : branch}<CaretDown size={13} /></button>}
        </div>
        <div className="hist-table-head"><span className="hist-graph-header">{vcs === 'git' ? '图' : ''}</span><span>提交说明</span><span>作者</span><span>日期</span><span>{vcs === 'svn' ? '修订号' : '哈希'}</span></div>
        <div className="hist-commit-scroll">
          {filtered.length ? <div className="hist-commit-table">
            {vcs === 'git' && <Graph graph={graph} />}
            {filtered.map((commit) => <button key={commit.id} className={`hist-commit-row ${selected?.id === commit.id ? 'is-selected' : ''}`} onClick={() => chooseCommit(commit)}>
              {vcs === 'git' ? <span className="hist-graph-cell" aria-hidden="true" /> : <span className="hist-revision-dot">r</span>}
              <span className="hist-message">{commit.message}{commit.refs.map((ref) => <em key={ref} className={`hist-ref ${ref.includes('feature') ? 'is-feature' : ref.includes('fix') ? 'is-fix' : ''}`}>{ref}</em>)}</span>
              <span>{commit.author}</span><time>{commit.date.replace('2026-', '')}</time><code>{commit.id}</code>
            </button>)}
          </div> : <div className="hist-no-results">{!allCommits.length ? '尚无提交，完成首次提交后会显示在这里。' : '没有符合条件的模拟提交。'}</div>}
        </div>
      </div>

      <aside className="history-details">
        {selected && <>
          <div className="hist-detail-heading"><span>所选提交</span><button className="hist-icon-button" onClick={() => onExpand?.(true)}><ArrowsOutSimple size={16} /></button></div>
          <h2>{selected.message}</h2>
          <div className="hist-detail-refs">{selected.refs.map((ref) => <span key={ref} className="hist-ref">{ref}</span>)}</div>
          <div className="hist-commit-meta"><code>{selected.id}</code><button title="复制版本号" onClick={copyCommitId}>{copied ? <Check size={14} weight="bold" /> : <Copy size={14} />}</button><span>{copied ? '已复制' : selected.author}</span><time>{selected.date}</time></div>
          <p className="hist-summary">{vcs === 'git' ? '此处呈现选中 Git 提交的说明、引用和文件变更。' : '此处呈现选中 SVN 修订的说明和文件变更。'}</p>
          <button className="hist-review" onClick={() => onReview?.(selected)}><Sparkle size={17} weight="fill" />审查此提交 <CaretDown size={13} /></button>
          <div className="hist-divider" />
          <div className="hist-files-title">变更的文件 <span>{selected.files.length} 个文件</span></div>
          <div className="hist-files">{selected.files.map((file) => <button key={file.id} className={`hist-file ${selectedFile?.id === file.id ? 'is-selected' : ''}`} onClick={() => setSelectedFileId(file.id)}>
            <Status value={file.status} /><span><strong>{file.name}</strong><small>{file.added} + / {file.removed} −</small></span>
          </button>)}</div>
          <button className="hist-open-diff" onClick={() => selectedFile && onOpenDiff?.(selectedFile, selected)}><File size={16} />打开差异</button>
        </>}
      </aside>
    </div>
    {expanded && selectedFile && <div className="history-diff-area">{renderDiff?.(selectedFile, selected) || <div className="hist-diff-placeholder"><div><Status value={selectedFile.status} /> {selectedFile.path}</div><pre><span>- {selectedFile.before || '（新增文件）'}</span><b>+ {selectedFile.after}</b></pre></div>}</div>}
  </section>
}
