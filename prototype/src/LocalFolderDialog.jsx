import { useEffect, useMemo, useRef, useState } from 'react'
import { ArrowLeft, CheckCircle, CircleNotch, FolderOpen, GitBranch, Plus, Database, WarningCircle, X } from '@phosphor-icons/react'
import './repository-dialogs.css'
import './local-folder-dialog.css'

const examples = [
  { id: 'git', name: 'WorkspaceKit', path: '~/Projects/WorkspaceKit', kind: 'git', detail: 'Git 工作区 · develop' },
  { id: 'svn', name: 'LegacyService', path: '~/Projects/LegacyService', kind: 'svn', detail: '已检测 SVN 工作副本 · trunk' },
  { id: 'dual', name: 'RepHub', path: '~/Projects/RepHub', kind: 'dual', detail: '已检测 Git 与 SVN 共管目录' },
  { id: 'plain', name: 'NewService', path: '/Users/zym/Projects/NewService', kind: 'plain', detail: '尚未受版本控制管理' },
  { id: 'failed', name: 'Unreadable', path: '/Users/zym/Projects/Unreadable', kind: 'failed', detail: '演示：检测权限失败' },
]

function useDialogKeyboard(onClose, blocked) {
  const ref = useRef(null)
  const closeRef = useRef(onClose)
  closeRef.current = onClose
  useEffect(() => {
    const onKey = (event) => {
      if (event.key === 'Escape' && !blocked) { event.preventDefault(); closeRef.current?.() }
      if (event.key !== 'Tab') return
      const items = [...ref.current?.querySelectorAll('button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])') || []]
      if (!items.length) return
      if (event.shiftKey && document.activeElement === items[0]) { event.preventDefault(); items.at(-1).focus() }
      if (!event.shiftKey && document.activeElement === items.at(-1)) { event.preventDefault(); items[0].focus() }
    }
    const timer = window.setTimeout(() => ref.current?.querySelector('input,button')?.focus(), 0)
    document.addEventListener('keydown', onKey)
    return () => { window.clearTimeout(timer); document.removeEventListener('keydown', onKey) }
  }, [blocked])
  return ref
}

const folderName = (path) => path.replace(/\/$/, '').split('/').pop() || 'untitled'
function validSvnURL(value) { try { const url = new URL(value); return ['http:', 'https:', 'svn:', 'svn+ssh:', 'file:'].includes(url.protocol) && (url.protocol === 'file:' ? url.pathname.length > 1 : !!url.hostname); } catch { return false; } }
const normalizePath = (path) => path.trim().replace(/\/+$/, '') || '/'
const isLocalPath = (path) => path.startsWith('~/') || path.startsWith('/')

function FolderKind({ kind }) {
  if (kind === 'git') return <span className="local-kind git"><GitBranch size={13} weight="bold" />Git</span>
  if (kind === 'svn') return <span className="local-kind svn">SV SVN</span>
  if (kind === 'dual') return <span className="local-kind dual">Git + SVN</span>
  return <span className="local-kind plain">未管理</span>
}

export function LocalFolderDialog({ onClose, onOpen, repositories = [] }) {
  const [step, setStep] = useState('choose')
  const [path, setPath] = useState(examples[0].path)
  const [target, setTarget] = useState('git')
  const [svnURL, setSvnURL] = useState('')
  const [error, setError] = useState('')
  const [simulateDetectFailure, setSimulateDetectFailure] = useState(false)
  const [simulateInitFailure, setSimulateInitFailure] = useState(false)
  const timerRef = useRef(null)
  const dialogRef = useDialogKeyboard(close, false)
  const chosen = useMemo(() => examples.find((item) => normalizePath(item.path) === normalizePath(path)) || { name: folderName(path), path, kind: 'plain', detail: '自定义路径将按未管理目录演示' }, [path])
  const knownRepository = useMemo(() => repositories.find((repo) => normalizePath(repo.path || '') === normalizePath(path)), [repositories, path])

  function cancelTimer() { if (timerRef.current) { window.clearTimeout(timerRef.current); timerRef.current = null } }
  useEffect(() => () => cancelTimer(), [])
  function close() { cancelTimer(); onClose?.() }
  const choose = (item) => { setPath(item.path); setError('') }
  const detect = (recover = false) => {
    if (!path.trim()) { setError('请输入一个本地文件夹路径。'); return }
    if (!isLocalPath(path.trim())) { setError('请输入绝对路径或以 ~/ 开头的路径。'); return }
    setError(''); setStep('detecting'); cancelTimer()
    timerRef.current = window.setTimeout(() => {
      timerRef.current = null
      if (!recover && (simulateDetectFailure || chosen.kind === 'failed')) { setStep('detectFailed'); return }
      if (knownRepository) { onOpen?.(knownRepository); return }
      const detectedKind = chosen.kind === 'failed' ? 'plain' : chosen.kind
      if (detectedKind === 'plain') { setStep('initialize'); return }
      const vcs = detectedKind === 'dual' ? ['git', 'svn'] : [detectedKind]
      onOpen?.({ id: `local-${Date.now()}`, name: chosen.name, path: path.trim(), vcs, branch: detectedKind === 'svn' ? 'trunk' : 'main', initialized: false, localFolder: true })
    }, 760)
  }
  const initialize = (recover = false) => {
    if (!['git', 'svn'].includes(target)) { setError('请选择一种版本控制方式。'); return }
    const vcs = [target]
    if (vcs.includes('svn') && !validSvnURL(svnURL.trim())) { setError('SVN 需要带协议的目标服务 URL，例如 https:// 或 svn+ssh://。'); return }
    setError(''); setStep('initializing'); cancelTimer()
    timerRef.current = window.setTimeout(() => {
      timerRef.current = null
      if (simulateInitFailure && !recover) { setStep('initFailed'); return }
      onOpen?.({ id: `local-${Date.now()}`, name: folderName(path), path: path.trim(), vcs, branch: vcs.includes('git') ? 'main' : 'trunk', initialized: true, localFolder: true, ...(vcs.includes('svn') ? { remoteURL: svnURL.trim() } : {}) })
    }, 800)
  }
  const back = () => { cancelTimer(); setError(''); setStep('choose') }
  const chooseTarget = (type) => { setTarget(type); setError('') }

  return <div className="repo-modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !['detecting', 'initializing'].includes(step)) close() }}>
    <section className="repo-dialog local-folder-dialog modal" ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="local-folder-title">
      <header className="modal-header repo-dialog-header"><div><span className="repo-eyebrow"><FolderOpen size={14} weight="fill" />本地文件夹</span><h2 id="local-folder-title">{step === 'initialize' || step === 'initializing' || step === 'initFailed' ? '初始化版本控制' : '打开本地文件夹'}</h2></div><button className="repo-close-button" aria-label="关闭" onClick={close}><X size={18} /></button></header>
      <div className="modal-content repo-dialog-content local-folder-content">
        {step === 'choose' && <>
          <div className="repo-prototype-note"><FolderOpen size={15} /><span><strong>原型体验</strong>：不扫描本地磁盘。请从示例目录选择，或输入绝对路径、<code>~/</code> 路径体验检测流程。</span></div>
          <label className="repo-field local-path-field"><span className="form-label">文件夹路径</span><input value={path} onChange={(event) => { setPath(event.target.value) }} placeholder="/Users/zym/Projects/RepHub" autoComplete="off" />{error && <small className="repo-error">{error}</small>}{!knownRepository&&chosen.kind==='plain'&&<small className="inline-note">自定义路径在本原型中按未管控文件夹演示。</small>}</label>
          <div className="local-example-heading"><span>示例目录</span><small>模拟检测结果</small></div>
          <div className="local-example-list">{examples.slice(0, 4).map((item) => <button className={`local-example ${path === item.path ? 'is-selected' : ''}`} key={item.id} onClick={() => choose(item)}><span className="local-example-icon"><FolderOpen size={18} weight="duotone" /></span><span><strong>{item.name}</strong><small>{item.path}</small><em>{item.detail}</em></span><FolderKind kind={item.kind} /></button>)}</div>
          <details className="local-demo-options"><summary>演示选项</summary><label><input type="checkbox" checked={simulateDetectFailure} onChange={(event) => setSimulateDetectFailure(event.target.checked)} /> 模拟检测失败</label><label><input type="checkbox" checked={simulateInitFailure} onChange={(event) => setSimulateInitFailure(event.target.checked)} /> 模拟初始化失败</label></details>
        </>}
        {step === 'detecting' && <div className="local-progress"><CircleNotch size={28} className="local-spin" /><h3>正在检测文件夹</h3><p>{path}</p><small>正在识别 Git、SVN 与共管工作副本…</small></div>}
        {step === 'detectFailed' && <div className="local-result is-error"><WarningCircle size={30} weight="duotone" /><h3>无法完成检测</h3><p>这是模拟的检测失败，与“未管理文件夹”不同。重试将模拟恢复成功。</p><button className="secondary-button" onClick={() => detect(true)}>重试检测</button></div>}
        {step === 'initialize' && <>
          <div className="local-init-heading"><CheckCircle size={21} weight="fill" /><div><h3>此文件夹尚未受版本控制管理</h3><p><strong>{folderName(path)}</strong> · {path}</p><p>请选择一种版本控制方式，仅模拟初始化，不会修改任何文件。</p></div></div>
          <div className="local-targets" role="radiogroup" aria-label="初始化版本控制方式"><label className={target === 'git' ? 'is-active' : ''}><input type="radio" name="initialize-vcs" value="git" checked={target === 'git'} onChange={() => chooseTarget('git')} /><GitBranch size={16} weight="bold" /><strong>Git</strong></label><label className={target === 'svn' ? 'is-active' : ''}><input type="radio" name="initialize-vcs" value="svn" checked={target === 'svn'} onChange={() => chooseTarget('svn')} /><Database size={16} weight="bold" /><strong>SVN</strong></label></div>
          {target === 'svn' && <label className="repo-field"><span className="form-label">SVN 目标服务 URL</span><input value={svnURL} onChange={(event) => setSvnURL(event.target.value)} placeholder="https://svn.example.com/repos/project/trunk" autoComplete="off" /><small className="inline-note">仅模拟导入、检出，不修改真实仓库；Git 初始化不需要远程地址。</small></label>}
          <p className="local-init-note">更多版本控制方式将在后续提供。</p>{error && <small className="repo-error">{error}</small>}
        </>}
        {step === 'initializing' && <div className="local-progress"><CircleNotch size={28} className="local-spin" /><h3>正在模拟初始化</h3><p>{path}</p><small>仅模拟初始化；选择 SVN 时包含导入与检出，不修改真实仓库。</small></div>}
        {step === 'initFailed' && <div className="local-result is-error"><WarningCircle size={30} weight="duotone" /><h3>模拟初始化失败</h3><p>未对本地文件产生任何更改。重试将模拟恢复成功。</p><button className="secondary-button" onClick={() => setStep('initialize')}>返回调整</button><button className="primary-button" onClick={() => initialize(true)}>重试初始化</button></div>}
      </div>
      <footer className="modal-footer repo-dialog-footer"><span>模拟流程 · 不访问磁盘或网络</span><div>{['choose', 'initialize', 'detectFailed', 'initFailed'].includes(step) && step !== 'choose' && <button className="secondary-button" onClick={back}><ArrowLeft size={14} />返回</button>}<button className="secondary-button" onClick={close}>取消</button>{step === 'choose' && <button className="primary-button" onClick={() => detect()}><FolderOpen size={15} />打开并检测</button>}{step === 'initialize' && <button className="primary-button" onClick={() => initialize()}><Plus size={15} />创建并打开</button>}</div></footer>
    </section>
  </div>
}
