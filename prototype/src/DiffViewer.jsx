import { diffLines } from './diff-utils';
import React, { useEffect, useMemo, useRef } from 'react';
import { Columns, Rows, Code, CaretUp, CaretDown } from '@phosphor-icons/react';

function alignedRows(rows) {
  const paired = []; let i = 0;
  while (i < rows.length) {
    if (rows[i].type === 'same') { paired.push([rows[i], rows[i]]); i++; continue; }
    const del = [], add = [];
    while (i < rows.length && rows[i].type !== 'same') { (rows[i].type === 'del' ? del : add).push(rows[i++]); }
    for (let n = 0; n < Math.max(del.length, add.length); n++) paired.push([del[n], add[n]]);
  }
  return paired;
}
function Syntax({ text }) {
  if (text.trim().startsWith('//') || text.trim().startsWith('#')) return <span className="syntax-comment">{text}</span>;
  const tokens = text.split(/("[^"\n]*"|\b(?:import|enum|case|struct|private|let|var|init|func|return|if|else|true|false|public|async|await|throws|try)\b|\b(?:Foundation|SwiftUI|String|Bool|UUID|URL|CommitTarget|CommitService|UserSettings|Repository|VersionControlBinding|View|Text|Circle|ZStack|VStack|Color)\b|\b\d+\b)/g);
  return <>{tokens.map((t, i) => <span key={i} className={/^"/.test(t) ? 'syntax-string' : /^(import|enum|case|struct|private|let|var|init|func|return|if|else|true|false|public|async|await|throws|try)$/.test(t) ? 'syntax-keyword' : /^[A-Z]/.test(t) ? 'syntax-type' : /^\d+$/.test(t) ? 'syntax-number' : undefined}>{t}</span>)}</>;
}
export function DiffViewer({ file, mode='split', onModeChange, source='Git · HEAD → 工作区', compact=false }) {
  const scrollRef = useRef(null);
  const rows = useMemo(() => diffLines(file?.before, file?.after), [file]);
  const paired = useMemo(() => alignedRows(rows), [rows]);
  useEffect(() => {
    const scroll = scrollRef.current;
    const first = scroll?.querySelector('[data-change="true"]');
    if (scroll && first) scroll.scrollTop = Math.max(0, first.offsetTop - 66);
  }, [file, mode]);
  if (!file) return <div className="diff-empty"><Code size={36} weight="light"/><h3>选择一个文件查看差异</h3><p>文件的增删内容会显示在这里</p></div>;
  const counts = { add: rows.filter(r => r.type === 'add').length, del: rows.filter(r => r.type === 'del').length };
  const jump = direction => {
    const root = scrollRef.current;
    if (!root) return;
    const changes = [...root.querySelectorAll('[data-change="true"]')];
    const positions = changes.map(el => el.offsetTop - root.offsetTop);
    const target = direction > 0 ? positions.find(y => y > root.scrollTop + 28) : [...positions].reverse().find(y => y < root.scrollTop - 10);
    root.scrollTo({ top: target ?? (direction > 0 ? positions[0] || 0 : positions.at(-1) || 0), behavior: 'smooth' });
  };
  return <section className={`diff-viewer ${compact ? 'compact' : ''}`} aria-label={`${file.name} 代码差异`}>
    <div className="diff-toolbar"><div className="diff-breadcrumb"><Code size={15}/><span title={file.path}>{file.path || file.name}</span></div><div className="diff-tools"><span className="stat-add">+{counts.add}</span><span className="stat-del">−{counts.del}</span><span className="tool-divider"/><button className="icon-button small" title="上一处变更" onClick={() => jump(-1)}><CaretUp size={14}/></button><button className="icon-button small" title="下一处变更" onClick={() => jump(1)}><CaretDown size={14}/></button>{onModeChange && <div className="segmented small"><button aria-label="并排差异" title="并排差异" className={mode==='split'?'active':''} onClick={()=>onModeChange('split')}><Columns size={15}/></button><button aria-label="统一差异" title="统一差异" className={mode==='unified'?'active':''} onClick={()=>onModeChange('unified')}><Rows size={15}/></button></div>}</div></div>
    <div className="diff-column-labels">{mode==='split' ? <><span>修改前 <em>{source.includes('工作区') ? (source.includes('SVN')?'BASE':source.includes('空仓库')?'空仓库':'HEAD') : '父版本'}</em></span><span>修改后 <em>{source.includes('工作区') ? '工作区' : '所选版本'}</em></span></> : <span>{source}</span>}</div>
    <div className={`diff-scroll ${mode}`} ref={scrollRef}>
      {mode === 'split' ? <div className="diff-pairs">{paired.map(([l,r], n) => <div className="diff-pair" key={n} data-change={l?.type==='del'||r?.type==='add'}><div className={`code-line ${l?.type || 'gap'}`}><span className="line-number">{l?.old}</span><span className="line-sign">{l?.type==='del'?'−':''}</span><code>{l && <Syntax text={l.text}/>}</code></div><div className={`code-line ${r?.type || 'gap'}`}><span className="line-number">{r?.new}</span><span className="line-sign">{r?.type==='add'?'+':''}</span><code>{r && <Syntax text={r.text}/>}</code></div></div>)}</div> : <div className="diff-unified">{rows.map((r,n)=><div className={`code-line ${r.type}`} key={n} data-change={r.type!=='same'}><span className="line-number">{r.old}</span><span className="line-number">{r.new}</span><span className="line-sign">{r.type==='add'?'+':r.type==='del'?'−':''}</span><code><Syntax text={r.text}/></code></div>)}</div>}
    </div>
  </section>;
}
