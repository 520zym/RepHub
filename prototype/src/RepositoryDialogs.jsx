import { useEffect, useMemo, useRef, useState } from 'react'
import { CheckCircle, FolderOpen, GitBranch, LinkSimple, MagnifyingGlass, Plus, TerminalWindow, X } from '@phosphor-icons/react'
import './repository-dialogs.css'

export { LocalFolderDialog } from './LocalFolderDialog'

function useModalKeyboard(onClose) {
  const dialogRef = useRef(null)
  const closeRef = useRef(onClose)
  closeRef.current = onClose
  useEffect(() => {
    const previouslyFocused = document.activeElement
    const focusFirst = () => dialogRef.current?.querySelector('input, button, [tabindex]:not([tabindex="-1"])')?.focus()
    const onKeyDown = (event) => {
      if (event.key === 'Escape') { event.preventDefault(); closeRef.current?.(); return }
      if (event.key !== 'Tab') return
      const focusable = [...dialogRef.current.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')]
      if (!focusable.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
    }
    window.setTimeout(focusFirst, 0)
    document.addEventListener('keydown', onKeyDown)
    return () => { document.removeEventListener('keydown', onKeyDown); previouslyFocused?.focus?.() }
  }, [])
  return dialogRef
}

function VcsBadge({ vcs }) {
  return <span className={`repo-vcs-badge repo-vcs-${vcs}`}>{vcs === 'git' ? <GitBranch size={12} weight="bold" /> : <span>SV</span>}{vcs.toUpperCase()}</span>
}

export function OpenRepositoryDialog({ repositories = [], onClose, onOpen, onClone, onLocalFolder }) {
  const [query, setQuery] = useState('')
  const dialogRef = useModalKeyboard(onClose)
  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return !needle ? repositories : repositories.filter((repo) => `${repo.name} ${repo.path}`.toLowerCase().includes(needle))
  }, [repositories, query])

  return <div className="repo-modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose?.() }}>
    <section className="repo-dialog modal" ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="open-repository-title">
      <header className="modal-header repo-dialog-header">
        <div><span className="repo-eyebrow"><FolderOpen size={14} weight="fill" />仓库</span><h2 id="open-repository-title">打开仓库</h2></div>
        <button className="repo-close-button" aria-label="关闭" onClick={onClose}><X size={18} /></button>
      </header>
      <div className="modal-content repo-dialog-content">
        <label className="repo-search"><MagnifyingGlass size={17} /><input autoComplete="off" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="按名称或路径筛选示例仓库…" aria-label="搜索示例仓库" /></label>
        <div className="repo-prototype-note"><TerminalWindow size={15} /><span><strong>原型体验</strong>：不扫描本地磁盘，选择下方示例仓库体验流程。</span></div>
        <button className="repo-local-folder-action" onClick={onLocalFolder}><FolderOpen size={18} weight="duotone" /><span><strong>打开本地文件夹…</strong><small>检测 Git、SVN 或尚未管理的目录</small></span></button>
        <div className="repo-list" aria-label="示例仓库">
          {matches.map((repo) => <button key={repo.id} className="repo-list-item" onClick={() => onOpen?.(repo)}>
            <span className="repo-list-icon"><FolderOpen size={20} weight="duotone" /></span>
            <span className="repo-list-copy"><strong>{repo.name}</strong><small title={repo.path}>{repo.path}</small>{repo.description && <em>{repo.description}</em>}</span>
            <span className="repo-list-meta"><span>{repo.vcs.map((item) => <VcsBadge vcs={item} key={item} />)}</span><small>{repo.branch || '默认分支'} · {repo.updated}</small></span>
          </button>)}
          {!matches.length && <div className="repo-empty"><FolderOpen size={24} /><p>没有匹配的示例仓库</p><small>换个名称或路径试试。</small></div>}
        </div>
      </div>
      <footer className="modal-footer repo-dialog-footer"><span>示例数据 · 不访问本机目录</span><div><button className="secondary-button" onClick={onClose}>取消</button><button className="primary-button" onClick={onClone}><Plus size={15} weight="bold" />克隆或检出</button></div></footer>
    </section>
  </div>
}

function derivedName(url) {
  const normalized = url.trim().replace(/\/$/, '')
  const last = normalized.split(/[/:]/).filter(Boolean).pop() || ''
  return last.replace(/\.git$/i, '')
}

const protocolPattern = /^(https?|ssh|svn|svn\+ssh|file):\/\//i

export function CloneDialog({ onClose, onCreate }) {
  const [type, setType] = useState('git')
  const [repoURL, setRepoURL] = useState('')
  const [name, setName] = useState('')
  const [directory, setDirectory] = useState('/Users/zym/Projects')
  const [nameEdited, setNameEdited] = useState(false)
  const [errors, setErrors] = useState({})
  const [loading, setLoading] = useState(false)
  const dialogRef = useModalKeyboard(onClose)

  const updateURL = (value) => {
    setRepoURL(value)
    if (!nameEdited) setName(derivedName(value))
  }
  const validate = () => {
    const next = {}
    if (!repoURL.trim()) next.repoURL = '请输入仓库地址。'
    else if (!protocolPattern.test(repoURL.trim())) next.repoURL = '请输入带协议的地址，例如 https:// 或 svn+ssh://。'
    if (!name.trim()) next.name = '请输入本地文件夹名称。'
    if (!directory.trim()) next.directory = '请输入目标父目录。'
    setErrors(next)
    return !Object.keys(next).length
  }
  const submit = () => {
    if (!validate() || loading) return
    setLoading(true)
    window.setTimeout(() => {
      onCreate?.({ id: `demo-${Date.now()}`, name: name.trim(), path: `${directory.replace(/\/$/, '')}/${name.trim()}`, vcs: [type], branch: type === 'git' ? 'main' : 'trunk' })
      setLoading(false)
    }, 800)
  }

  return <div className="repo-modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !loading) onClose?.() }}>
    <section className="repo-dialog repo-clone-dialog modal" ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="clone-repository-title">
      <header className="modal-header repo-dialog-header">
        <div><span className="repo-eyebrow"><LinkSimple size={14} weight="bold" />添加仓库</span><h2 id="clone-repository-title">克隆或检出</h2></div>
        <button className="repo-close-button" aria-label="关闭" onClick={onClose} disabled={loading}><X size={18} /></button>
      </header>
      <div className="modal-content repo-dialog-content">
        <div className="repo-prototype-note"><TerminalWindow size={15} /><span><strong>原型体验</strong>：提交后仅创建演示记录，不请求网络也不写入文件。</span></div>
        <div className="repo-type-tabs" role="tablist" aria-label="版本控制类型"><button role="tab" aria-selected={type === 'git'} className={type === 'git' ? 'is-active' : ''} onClick={() => setType('git')}><GitBranch size={16} weight="bold" />Git</button><button role="tab" aria-selected={type === 'svn'} className={type === 'svn' ? 'is-active' : ''} onClick={() => setType('svn')}><span className="repo-svn-icon">SV</span>SVN</button></div>
        <label className="repo-field"><span className="form-label">仓库地址</span><input className={errors.repoURL ? 'has-error' : ''} value={repoURL} onChange={(event) => updateURL(event.target.value)} placeholder={type === 'git' ? 'https://example.com/team/rephub.git' : 'https://svn.example.com/repos/project/trunk'} autoComplete="off" />{errors.repoURL ? <small className="repo-error">{errors.repoURL}</small> : <small className="inline-note">支持 https://、ssh://、svn://、svn+ssh:// 或 file://。</small>}</label>
        <div className="repo-form-grid"><label className="repo-field"><span className="form-label">本地名称</span><input className={errors.name ? 'has-error' : ''} value={name} onChange={(event) => { setNameEdited(true); setName(event.target.value) }} placeholder="rephub" autoComplete="off" />{errors.name && <small className="repo-error">{errors.name}</small>}</label><label className="repo-field"><span className="form-label">目标父目录</span><input className={errors.directory ? 'has-error' : ''} value={directory} onChange={(event) => setDirectory(event.target.value)} placeholder="/Users/zym/Projects" autoComplete="off" />{errors.directory && <small className="repo-error">{errors.directory}</small>}</label></div>
        <div className="repo-result-path"><FolderOpen size={15} /><span>将创建演示工作区：</span><code>{directory.replace(/\/$/, '') || '…'}/{name || '…'}</code></div>
      </div>
      <footer className="modal-footer repo-dialog-footer"><span>模拟操作 · 不产生网络请求</span><div><button className="secondary-button" onClick={onClose} disabled={loading}>取消</button><button className="primary-button" onClick={submit} disabled={loading}>{loading ? <><span className="repo-spinner" />正在创建…</> : <><CheckCircle size={16} weight="fill" />创建演示工作区</>}</button></div></footer>
    </section>
  </div>
}
