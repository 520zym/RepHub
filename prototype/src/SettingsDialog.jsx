import { useEffect, useMemo, useRef, useState } from 'react';
import {
  BracketsCurly,
  CheckCircle,
  Code,
  Cpu,
  FloppyDisk,
  Key,
  Plus,
  ShieldCheck,
  Sparkle,
  TerminalWindow,
  Trash,
  X,
} from '@phosphor-icons/react';
import './settings.css';

const CONFIG_KEY = 'rephub-ai-config-v1';

export const defaultConfig = {
  connections: [
    {
      id: 'api-default',
      name: 'OpenAI 兼容 API',
      type: 'api',
      endpoint: 'https://api.example.com/v1',
      model: '请填写模型名称',
      path: '',
    },
    { id: 'codex-cli', name: 'Codex CLI', type: 'codex', endpoint: '', model: '', path: 'codex' },
    { id: 'claude-cli', name: 'Claude Code', type: 'claude', endpoint: '', model: '', path: 'claude' },
  ],
  scenes: [
    {
      id: 'review-default',
      name: '代码审查',
      kind: 'review',
      prompt: '请审查以下代码变更。优先指出可能的缺陷、边界条件和可维护性问题，并给出可执行的建议。\n\n变更：\n{{diff}}\n\n文件：{{files}}\n分支：{{branch}}',
      connectionId: 'api-default',
    },
    {
      id: 'commit-default',
      name: '生成提交说明',
      kind: 'commit',
      prompt: '根据以下变更生成简洁、准确的中文提交说明。使用 Conventional Commit 格式，只输出提交说明。\n\n{{diff}}',
      connectionId: 'api-default',
    },
  ],
};

const cloneConfig = (value) => JSON.parse(JSON.stringify(value));
const makeId = (prefix) => `${prefix}-${globalThis.crypto?.randomUUID?.() || Date.now().toString(36)}`;

function normalizeConfig(value) {
  if (!value || typeof value !== 'object') return cloneConfig(defaultConfig);
  const rawConnections = Array.isArray(value.connections) ? value.connections : [];
  const connections = rawConnections
    .filter((item) => item && typeof item === 'object' && typeof item.id === 'string')
    .map((item) => ({
      id: item.id,
      name: typeof item.name === 'string' ? item.name : '未命名连接',
      type: ['api', 'codex', 'claude', 'cli'].includes(item.type) ? item.type : 'api',
      endpoint: typeof item.endpoint === 'string' ? item.endpoint : '',
      model: typeof item.model === 'string' ? item.model : '',
      path: typeof item.path === 'string' ? item.path : '',
    }));
  const safeConnections = connections.length ? connections : cloneConfig(defaultConfig.connections);
  const knownIds = new Set(safeConnections.map((item) => item.id));
  const rawScenes = Array.isArray(value.scenes) ? value.scenes : [];
  const scenes = rawScenes
    .filter((item) => item && typeof item === 'object' && typeof item.id === 'string')
    .map((item) => ({
      id: item.id,
      name: typeof item.name === 'string' ? item.name : '未命名场景',
      kind: item.kind === 'commit' ? 'commit' : 'review',
      prompt: typeof item.prompt === 'string' ? item.prompt : '',
      connectionId: knownIds.has(item.connectionId) ? item.connectionId : safeConnections[0].id,
    }));
  const safeScenes = scenes.length ? scenes : cloneConfig(defaultConfig.scenes).map((scene) => ({
    ...scene,
    connectionId: knownIds.has(scene.connectionId) ? scene.connectionId : safeConnections[0].id,
  }));
  return { connections: safeConnections, scenes: safeScenes };
}

export function loadConfig() {
  try {
    const raw = localStorage.getItem(CONFIG_KEY);
    return normalizeConfig(raw ? JSON.parse(raw) : defaultConfig);
  } catch {
    return cloneConfig(defaultConfig);
  }
}

const typeLabel = { api: '模型 API', codex: 'Codex CLI', claude: 'Claude Code', cli: '本地命令' };

export function SettingsDialog({ config, onSave, onClose, onToast, initialTab = 'scenes' }) {
  const [draft, setDraft] = useState(() => normalizeConfig(config || loadConfig()));
  const [tab, setTab] = useState(initialTab === 'connections' ? 'connections' : 'scenes');
  const [sceneId, setSceneId] = useState(() => draft.scenes[0]?.id);
  const [connectionId, setConnectionId] = useState(() => draft.connections[0]?.id);
  const [errors, setErrors] = useState({});
  const [testResult, setTestResult] = useState('');
  const [apiKey, setApiKey] = useState('');
  const dialogRef = useRef(null);

  const currentScene = useMemo(() => draft.scenes.find((item) => item.id === sceneId) || draft.scenes[0], [draft.scenes, sceneId]);
  const currentConnection = useMemo(() => draft.connections.find((item) => item.id === connectionId) || draft.connections[0], [draft.connections, connectionId]);

  useEffect(() => {
    setTab(initialTab === 'connections' ? 'connections' : 'scenes');
  }, [initialTab]);

  useEffect(() => {
    const handleKeyDown = (event) => {
      if (event.key === 'Escape') onClose?.();
      if (event.key !== 'Tab' || !dialogRef.current) return;
      const focusable = dialogRef.current.querySelectorAll('button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled])');
      const items = [...focusable];
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  const changeScene = (key, value) => {
    setDraft((old) => ({ ...old, scenes: old.scenes.map((item) => item.id === currentScene.id ? { ...item, [key]: value } : item) }));
    setErrors((old) => ({ ...old, [key]: '' }));
  };
  const changeConnection = (key, value) => {
    setDraft((old) => ({ ...old, connections: old.connections.map((item) => item.id === currentConnection.id ? { ...item, [key]: value } : item) }));
    setTestResult('');
  };
  const addScene = () => {
    const next = { id: makeId('scene'), name: '新建 AI 场景', kind: 'review', prompt: '请根据以下变更完成分析：\n\n{{diff}}', connectionId: draft.connections[0].id };
    setDraft((old) => ({ ...old, scenes: [...old.scenes, next] }));
    setSceneId(next.id);
  };
  const addConnection = () => {
    const next = { id: makeId('connection'), name: '新模型连接', type: 'api', endpoint: '', model: '', path: '' };
    setDraft((old) => ({ ...old, connections: [...old.connections, next] }));
    setConnectionId(next.id);
  };
  const deleteScene = () => {
    if (draft.scenes.length < 2) return;
    const next = draft.scenes.filter((item) => item.id !== currentScene.id);
    setDraft((old) => ({ ...old, scenes: next }));
    setSceneId(next[0].id);
  };
  const deleteConnection = () => {
    if (draft.connections.length < 2) return;
    const next = draft.connections.filter((item) => item.id !== currentConnection.id);
    const fallbackId = next[0].id;
    setDraft((old) => ({
      connections: next,
      scenes: old.scenes.map((scene) => scene.connectionId === currentConnection.id ? { ...scene, connectionId: fallbackId } : scene),
    }));
    setConnectionId(fallbackId);
  };
  const save = () => {
    const connectionIds = new Set(draft.connections.map((connection) => connection.id));
    const invalidConnection = draft.connections.find((connection) => {
      if (!connection.name.trim()) return true;
      if (!['api', 'codex', 'claude', 'cli'].includes(connection.type)) return true;
      return connection.type === 'api'
        ? !connection.endpoint.trim() || !connection.model.trim()
        : !connection.path.trim();
    });
    if (invalidConnection) {
      const fields = {};
      if (!invalidConnection.name.trim()) fields.connectionName = '请填写连接名称';
      if (!['api', 'codex', 'claude', 'cli'].includes(invalidConnection.type)) fields.type = '请选择连接类型';
      if (invalidConnection.type === 'api') {
        if (!invalidConnection.endpoint.trim()) fields.endpoint = '请填写 API 地址';
        if (!invalidConnection.model.trim()) fields.model = '请填写模型名称';
      } else if (!invalidConnection.path.trim()) fields.path = '请填写本地命令';
      setTab('connections');
      setConnectionId(invalidConnection.id);
      setErrors(fields);
      return;
    }
    const invalidScene = draft.scenes.find((scene) => !scene.name.trim() || !scene.prompt.trim() || !connectionIds.has(scene.connectionId));
    if (invalidScene) {
      setTab('scenes');
      setSceneId(invalidScene.id);
      setErrors({
        name: !invalidScene.name.trim() ? '请填写场景名称' : '',
        prompt: !invalidScene.prompt.trim() ? '请填写提示词' : '',
        connectionId: !connectionIds.has(invalidScene.connectionId) ? '请选择一个有效的默认连接' : '',
      });
      return;
    }
    onSave?.(draft);
    onToast?.('AI 设置已保存');
    onClose?.();
  };
  const simulateConnection = () => {
    const command = currentConnection.type === 'api' ? currentConnection.endpoint : currentConnection.path;
    setTestResult(command ? '演示结果：配置格式正常。原型没有联网，也没有检测本机是否安装此命令。' : '请先填写 API 地址或本地命令路径，再进行演示检测。');
  };

  return (
    <div className="settings-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose?.()}>
      <section className="settings-dialog" ref={dialogRef} role="dialog" aria-modal="true" aria-labelledby="settings-title">
        <header className="settings-header">
          <div><span className="settings-eyebrow">RepHub 偏好设置</span><h2 id="settings-title">AI 工作流</h2></div>
          <button className="settings-icon-button" type="button" aria-label="关闭设置" onClick={onClose}><X size={18} /></button>
        </header>
        <div className="settings-body">
          <nav className="settings-nav" aria-label="AI 设置分类">
            <button type="button" className={tab === 'scenes' ? 'is-active' : ''} onClick={() => setTab('scenes')}><Sparkle size={18} />AI 场景</button>
            <button type="button" className={tab === 'connections' ? 'is-active' : ''} onClick={() => setTab('connections')}><Cpu size={18} />AI 连接</button>
            <p><ShieldCheck size={16} /> 密钥仅在本次输入期间保留于内存。</p>
          </nav>
          {tab === 'scenes' ? (
            <div className="settings-content settings-scene-layout">
              <aside className="settings-list-pane">
                <div className="settings-pane-heading"><span>已配置场景</span><button type="button" aria-label="新建 AI 场景" onClick={addScene}><Plus size={16} /></button></div>
                <div className="settings-item-list">{draft.scenes.map((scene) => <button type="button" key={scene.id} className={scene.id === currentScene?.id ? 'is-selected' : ''} onClick={() => { setSceneId(scene.id); setErrors({}); }}><span>{scene.name}</span><small>{scene.kind === 'review' ? '代码审查' : '提交说明'}</small></button>)}</div>
              </aside>
              <div className="settings-form-pane">
                <div className="settings-form-title"><div><span className="settings-kicker">AI 场景</span><h3>{currentScene?.name || '新建场景'}</h3></div>{draft.scenes.length > 1 && <button className="settings-delete" type="button" onClick={deleteScene}><Trash size={15} />删除</button>}</div>
                <label className="settings-field"><span>场景名称</span><input value={currentScene?.name || ''} onChange={(e) => changeScene('name', e.target.value)} placeholder="例如：代码审查" autoFocus />{errors.name && <em>{errors.name}</em>}</label>
                <label className="settings-field"><span>用途</span><select value={currentScene?.kind || 'review'} onChange={(e) => changeScene('kind', e.target.value)}><option value="review">检查变更并给出审查建议</option><option value="commit">根据变更生成提交说明</option></select></label>
                <label className="settings-field"><span>默认连接</span><select value={currentScene?.connectionId || ''} onChange={(e) => changeScene('connectionId', e.target.value)}>{draft.connections.map((connection) => <option value={connection.id} key={connection.id}>{connection.name} · {typeLabel[connection.type]}</option>)}</select>{errors.connectionId && <em>{errors.connectionId}</em>}</label>
                <label className="settings-field settings-prompt-field"><span>提示词</span><textarea value={currentScene?.prompt || ''} onChange={(e) => changeScene('prompt', e.target.value)} placeholder="告诉 AI 如何处理当前变更" />{errors.prompt && <em>{errors.prompt}</em>}</label>
                <div className="settings-variable-note"><BracketsCurly size={16} /><div><strong>可用输入变量</strong><span><code>{'{{diff}}'}</code> 当前变更　<code>{'{{files}}'}</code> 文件列表　<code>{'{{branch}}'}</code> 当前分支</span></div></div>
              </div>
            </div>
          ) : (
            <div className="settings-content settings-connection-layout">
              <aside className="settings-list-pane">
                <div className="settings-pane-heading"><span>可用连接</span><button type="button" aria-label="新建 AI 连接" onClick={addConnection}><Plus size={16} /></button></div>
                <div className="settings-item-list">{draft.connections.map((connection) => <button type="button" key={connection.id} className={connection.id === currentConnection?.id ? 'is-selected' : ''} onClick={() => { setConnectionId(connection.id); setErrors({}); }}><span>{connection.name}</span><small>{typeLabel[connection.type]}</small></button>)}</div>
              </aside>
              <div className="settings-form-pane">
                <div className="settings-form-title"><div><span className="settings-kicker">AI 连接</span><h3>{currentConnection?.name || '新模型连接'}</h3></div>{draft.connections.length > 1 && <button className="settings-delete" type="button" onClick={deleteConnection}><Trash size={15} />删除</button>}</div>
                <label className="settings-field"><span>连接名称</span><input value={currentConnection?.name || ''} onChange={(e) => { changeConnection('name', e.target.value); setErrors({}); }} placeholder="例如：团队模型 API" autoFocus />{errors.connectionName && <em>{errors.connectionName}</em>}</label>
                <label className="settings-field"><span>连接类型</span><select value={currentConnection?.type || 'api'} onChange={(e) => { changeConnection('type', e.target.value); setErrors({}); }}><option value="api">模型 API</option><option value="codex">Codex CLI</option><option value="claude">Claude Code</option><option value="cli">其他本地命令</option></select>{errors.type && <em>{errors.type}</em>}</label>
                {currentConnection?.type === 'api' ? <>
                  <label className="settings-field"><span>API 地址</span><input value={currentConnection.endpoint} onChange={(e) => changeConnection('endpoint', e.target.value)} placeholder="https://api.example.com/v1" />{errors.endpoint && <em>{errors.endpoint}</em>}</label>
                  <label className="settings-field"><span>模型名称</span><input value={currentConnection.model} onChange={(e) => changeConnection('model', e.target.value)} placeholder="例如：gpt-5" />{errors.model && <em>{errors.model}</em>}</label>
                  <label className="settings-field"><span><Key size={15} />API 密钥 <small>仅本次输入</small></span><input type="password" value={apiKey} onChange={(e) => setApiKey(e.target.value)} placeholder="不会保存，也不会发送" autoComplete="off" /></label>
                </> : <>
                  <label className="settings-field"><span>本地命令</span><div className="settings-command-input"><TerminalWindow size={16} /><input value={currentConnection?.path || ''} onChange={(e) => changeConnection('path', e.target.value)} placeholder={currentConnection?.type === 'claude' ? 'claude' : 'codex'} /></div>{errors.path && <em>{errors.path}</em>}</label>
                  <label className="settings-field"><span>附加模型参数 <small>可选</small></span><input value={currentConnection?.model || ''} onChange={(e) => changeConnection('model', e.target.value)} placeholder="例如：--model …" /></label>
                </>}
                <div className="settings-test-row"><button type="button" className="settings-secondary-button" onClick={simulateConnection}><CheckCircle size={16} />演示检测</button>{testResult && <p>{testResult}</p>}</div>
                <div className="settings-security-note"><ShieldCheck size={17} /><span><strong>安全说明</strong> 原型不保存密钥，也不会发起请求。本地命令检测仅展示模拟结果。</span></div>
              </div>
            </div>
          )}
        </div>
        <footer className="settings-footer"><span>修改会在保存后应用到当前浏览器的原型配置。</span><div><button type="button" className="settings-cancel-button" onClick={onClose}>取消</button><button type="button" className="settings-save-button" onClick={save}><FloppyDisk size={16} />保存设置</button></div></footer>
      </section>
    </div>
  );
}
