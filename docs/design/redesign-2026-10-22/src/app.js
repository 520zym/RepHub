(function () {
  const icon = (name, cls = "") => `<svg class="ic ${cls}" aria-hidden="true"><use href="#i-${name}"></use></svg>`;
  const traffic = () => `<div class="traffic"><span class="light red"></span><span class="light yellow"></span><span class="light green"></span></div>`;

  const FILE_ROWS = [
    { type: "folder", name: "src", depth: 0, open: true },
    { type: "folder", name: "main", depth: 1, open: true },
    { type: "folder", name: "java", depth: 2, open: true },
    { type: "folder", name: "network", depth: 3, open: true },
    { type: "file", name: "HttpClient.java", depth: 4, badge: "M", selected: true },
    { type: "file", name: "RequestOptions.java", depth: 4, badge: "M" },
    { type: "file", name: "ResponseHandler.java", depth: 4, badge: "M" },
    { type: "folder", name: "resources", depth: 2, open: true },
    { type: "file", name: "application.yml", depth: 3, badge: "A" },
    { type: "folder", name: "docs", depth: 0, open: true },
    { type: "file", name: "更新说明.md", depth: 1, badge: "M" },
    { type: "file", name: "README.md", depth: 0, badge: "M" }
  ];

  function filesRows() {
    return FILE_ROWS.map((row) => {
      const isFolder = row.type === "folder";
      const selected = row.selected ? " selected" : "";
      const tw = isFolder ? icon(row.open ? "chevron-down" : "chevron-right") : "";
      const typeIcon = isFolder
        ? `<span class="folder-ico">${icon("folder")}</span>`
        : `<span class="file-ico">${icon("file")}</span>`;
      const badge = row.badge ? `<span class="badge ${row.badge}">${row.badge}</span>` : "";
      return `<div class="tree-row${selected}" style="--d:${row.depth}">
        <span class="ck on ${isFolder ? "group" : ""}">${icon("check", "sm")}</span>
        <span class="tw">${tw}</span>
        ${typeIcon}
        <span class="fname">${row.name}</span>
        ${badge}
      </div>`;
    }).join("");
  }

  const CODE_ROWS = [
    { type: "ctx", old: 6, nu: 6, src: `<span class="k">public</span> <span class="k">final</span> <span class="k">class</span> <span class="t">HttpClient</span> {` },
    { type: "ctx", old: 7, nu: 7, src: `    <span class="k">private</span> <span class="k">final</span> <span class="t">HttpClient</span> client;` },
    { type: "ctx", old: 8, nu: 8, src: `    <span class="k">private</span> <span class="k">final</span> <span class="t">RequestOptions</span> options;` },
    { type: "ctx", old: 9, nu: 9, src: "" },
    { type: "ctx", old: 10, nu: 10, src: `    <span class="k">public</span> <span class="fn">HttpClient</span>(<span class="t">RequestOptions</span> options) {` },
    { type: "ctx", old: 11, nu: 11, src: `        <span class="k">this</span>.options = options;` },
    { type: "ctx", old: 12, nu: 12, src: `        <span class="k">this</span>.client = <span class="t">HttpClient</span>.newBuilder()` },
    { type: "ctx", old: 13, nu: 13, src: `            .version(<span class="t">HttpClient</span>.<span class="t">Version</span>.HTTP_2)` },
    { type: "ctx", old: 14, nu: 14, src: `            .connectTimeout(options.connectTimeout())` },
    { type: "ctx", old: 15, nu: 15, src: `            .build();` },
    { type: "ctx", old: 16, nu: 16, src: `    }` },
    { type: "ctx", old: 17, nu: 17, src: "" },
    { type: "ctx", old: 18, nu: 18, src: `    <span class="k">public</span> <span class="t">Response</span> <span class="fn">execute</span>(<span class="t">Request</span> request) <span class="k">throws</span> <span class="t">RequestException</span> {` },
    { type: "ctx", old: 19, nu: 19, src: `        <span class="t">Duration</span> timeout = options.timeout();` },
    { type: "ctx", old: 20, nu: 20, src: `        <span class="k">try</span> (<span class="t">Response</span> response = client.send(request)) {` },
    { type: "ctx", old: 21, nu: 21, src: `            <span class="k">if</span> (!response.isSuccessful()) {` },
    { type: "del", old: 22, nu: null, src: `                <span class="k">throw</span> <span class="k">new</span> <span class="t">RequestException</span>(response.code());` },
    { type: "add", old: null, nu: 22, src: `                <span class="k">throw</span> <span class="k">new</span> <span class="t">RequestException</span>(` },
    { type: "add", old: null, nu: 23, src: `                    <span class="s">"HTTP request failed: "</span> + response.code() + <span class="s">" "</span> + response.body()` },
    { type: "add", old: null, nu: 24, src: `                );` },
    { type: "ctx", old: 23, nu: 25, src: `            }` },
    { type: "ctx", old: 24, nu: 26, src: `            <span class="k">return</span> response;` },
    { type: "ctx", old: 25, nu: 27, src: `        } <span class="k">catch</span> (<span class="t">IOException</span> e) {` },
    { type: "del", old: 26, nu: null, src: `            <span class="k">throw</span> <span class="k">new</span> <span class="t">RequestException</span>(<span class="s">"Request failed"</span>, e);` },
    { type: "add", old: null, nu: 28, src: `            <span class="k">throw</span> <span class="k">new</span> <span class="t">RequestException</span>(<span class="s">"Request execution failed: "</span> + e.getMessage(), e);` },
    { type: "ctx", old: 27, nu: 29, src: `        }` },
    { type: "ctx", old: 28, nu: 30, src: `    }` },
    { type: "ctx", old: 29, nu: 31, src: "" },
    { type: "ctx", old: 30, nu: 32, src: `    <span class="k">private</span> <span class="t">HttpRequest</span> <span class="fn">buildRequest</span>(<span class="t">Request</span> request, <span class="t">Duration</span> timeout) {` },
    { type: "ctx", old: 31, nu: 33, src: `        <span class="k">return</span> <span class="t">HttpRequest</span>.newBuilder()` },
    { type: "ctx", old: 32, nu: 34, src: `            .uri(request.uri())` },
    { type: "ctx", old: 33, nu: 35, src: `            .timeout(timeout)` },
    { type: "ctx", old: 34, nu: 36, src: `            .GET()` },
    { type: "ctx", old: 35, nu: 37, src: `            .build();` },
    { type: "ctx", old: 36, nu: 38, src: `    }` },
    { type: "ctx", old: 37, nu: 39, src: `}` }
  ];

  function codeRows() {
    return CODE_ROWS.map((row) => {
      const oldNo = row.old == null ? "" : row.old;
      const newNo = row.nu == null ? "" : row.nu;
      const mark = row.type === "add" ? "+" : row.type === "del" ? "-" : "";
      return `<div class="code-row ${row.type}">
        <span class="ln old">${oldNo}</span><span class="ln new">${newNo}</span>
        <span class="mk">${mark}</span><span class="src">${row.src}</span>
      </div>`;
    }).join("");
  }

  function titlebar(v) {
    const tabs = `<nav class="tabs" aria-label="主视图">
      <button class="tab active">工作区</button>
      <button class="tab">提交历史</button>
    </nav>`;
    const acts = v === "b"
      ? `<div class="actions">
          <span class="sync">${icon("arrow-up")} 1</span>
          <button class="tool">${icon("refresh")}</button>
          <button class="tool">${icon("arrow-down")} 拉取</button>
          <button class="tool">${icon("arrow-up")} 推送</button>
          <button class="tool ai">${icon("sparkles")} AI 审查</button>
        </div>`
      : v === "c"
      ? `<div class="actions">
          <span class="sync">${icon("arrow-up")} 本地领先 1</span>
          <button class="tool">${icon("refresh")}</button>
          <button class="tool">${icon("arrow-down")} 拉取</button>
          <button class="tool">${icon("arrow-up")} 推送</button>
          <button class="tool ai">${icon("sparkles")} AI 审查</button>
        </div>`
      : `<div class="actions">
          <span class="sync">${icon("arrow-up")} 1</span>
          <button class="tool">${icon("refresh")}</button>
          <button class="tool">${icon("arrow-down")} 拉取</button>
          <button class="tool">${icon("arrow-up")} 推送</button>
          <button class="tool ai">${icon("sparkles")} AI 审查</button>
        </div>`;
    const repoLabel = v === "b"
      ? `<button class="repo-btn">${icon("git")} efb-standard ${icon("chevron-down", "sm")}</button>`
      : `<button class="repo-btn">efb-standard ${icon("chevron-down", "sm")}</button>`;
    return `<header class="titlebar">
      ${traffic()}
      <div class="identity">
        <span class="app-mark">${icon("branch")}</span>
        ${repoLabel}
        ${v === "c" ? "" : '<span class="slash">/</span>'}
        <button class="branch-btn"><span class="branch-glyph">${icon("branch")}</span> hotfix/request-timeout ${icon("chevron-down", "sm")}</button>
      </div>
      ${tabs}
      ${acts}
    </header>`;
  }

  function filesPane(v) {
    if (v === "a") {
      return `<aside class="files">
        <div class="eyebrow">Changes <span class="slash">/</span> 06</div>
        <div class="files-title"><h1>变更</h1><span class="count">6</span></div>
        <div class="files-sub"><span class="ok">${icon("check-circle")}</span> 全部变更均已选择</div>
        <div class="file-tabs"><button class="ftab active">变更 <b>6</b></button><button class="ftab">全部文件</button></div>
        <div class="search">${icon("search")} 筛选变更文件…</div>
        <div class="tree">${filesRows()}</div>
        <div class="files-foot"><span>已选 <b>6</b> / 6</span><span class="checkline"><span class="dot"></span>无冲突</span></div>
      </aside>`;
    }
    if (v === "b") {
      return `<aside class="files">
        <div class="eyebrow">Worktree <span class="slash">/</span> Local <span class="live">● Ready</span></div>
        <div class="files-title"><h2>6 项变更</h2><span class="count">06</span></div>
        <div class="files-sub"><span class="ok">${icon("check-circle")}</span> 无冲突 · 可提交</div>
        <div class="file-tabs"><button class="ftab active">变更 06</button><button class="ftab">全部文件</button></div>
        <div class="search">${icon("search")} 筛选变更文件…</div>
        <div class="tree">${filesRows()}</div>
        <div class="files-foot"><span><b>6</b> / 6 SELECTED</span><span>NO CONFLICTS</span></div>
      </aside>`;
    }
    return `<aside class="files">
      <div class="files-title"><h2>变更</h2><span class="count">6</span></div>
      <div class="files-sub">已选 6 / 6 <span class="sep">·</span> 无冲突</div>
      <div class="file-tabs"><button class="ftab active">变更 6</button><button class="ftab">全部文件</button></div>
      <div class="search">${icon("search")} 搜索文件…</div>
      <div class="tree">${filesRows()}</div>
      <div class="files-foot"><span><span class="dot"></span> 已选 6 / 6</span><span>全部展开</span></div>
    </aside>`;
  }

  function modeToggle(v) {
    if (v === "a") {
      return `<div class="mode"><span>${icon("columns")} 并排</span><span class="active">${icon("rows")} 统一</span></div>`;
    }
    if (v === "b") {
      return `<div class="mode"><span>${icon("columns")} SPLIT</span><span class="active">${icon("rows")} UNIFIED</span></div>`;
    }
    return `<div class="mode"><span>${icon("columns")} 并排</span><span class="active">${icon("rows")} 统一</span></div>`;
  }

  function diffPane(v) {
    const path = "src / main / java / network";
    if (v === "a") {
      return `<section class="diff-panel">
        <div class="diff-head">
          <div class="file-main">
            <span class="file-chip">${icon("java")}</span>
            <div class="file-titles"><h2>HttpClient.java</h2><div class="file-path">${path}</div></div>
          </div>
          <div class="diff-actions">
            <button class="textbtn">${icon("history")} 文件历史</button>
            ${modeToggle(v)}
          </div>
        </div>
        <div class="compare">
          <span class="cmp"><b>HEAD</b><span class="arrow">→</span>工作区</span>
          <span class="diffstat"><span class="add">+38</span><span class="del">−12</span></span>
          <span class="hunk-meta">第 22–30 行 · 2 处更改</span>
        </div>
        <div class="code-wrap"><div class="code">${codeRows()}</div><div class="code-fade"></div></div>
      </section>`;
    }
    if (v === "b") {
      return `<section class="diff-panel">
        <div class="diff-head">
          <div class="file-main">
            <span class="file-chip">${icon("java")}</span>
            <div class="file-titles"><h2>HttpClient.java</h2><div class="file-path">${path}</div></div>
          </div>
          <div class="diff-actions">
            <button class="textbtn">${icon("history")} HISTORY</button>
            ${modeToggle(v)}
          </div>
        </div>
        <div class="compare">
          <span class="cmp"><b>HEAD</b><span class="arrow">→</span>WORKTREE</span>
          <span class="diffstat"><span class="add">+38</span><span class="del">−12</span></span>
          <span class="hunk-meta">2 HUNKS · UTF-8 · LF</span>
        </div>
        <div class="code-wrap"><div class="code">${codeRows()}</div><div class="mini-rail"><i></i><i></i><i></i></div><div class="code-fade"></div></div>
      </section>`;
    }
    return `<section class="diff-panel">
      <div class="diff-head">
        <div class="file-main">
          <span class="file-chip">${icon("java")}</span>
          <div class="file-titles"><h2>HttpClient.java</h2><div class="file-path">${path}</div></div>
        </div>
        <div class="diff-actions">
          <button class="textbtn">${icon("history")} 文件历史</button>
          ${modeToggle(v)}
        </div>
      </div>
      <div class="compare">
        <span class="cmp"><b>HEAD</b><span class="arrow">→</span>工作区</span>
        <span class="diffstat"><span class="add">+38</span><span class="del">−12</span></span>
        <span class="hunk-meta">第 22–30 行</span>
        <div class="review-nav">
          <button class="navbtn">${icon("chevron-left")}</button>
          <span class="pos"><b>1</b> / 6</span>
          <button class="navbtn">${icon("chevron-right")}</button>
        </div>
      </div>
      <div class="code-wrap"><div class="code">${codeRows()}</div><div class="code-fade"></div></div>
    </section>`;
  }

  const msg = `<p class="msg-title">fix: 优化请求超时与连接释放</p>
    <p class="msg-body">统一请求超时配置，补充异常处理，确保响应资源在请求完成后及时关闭。<span class="msg-caret"></span></p>`;

  function targetLine(v) {
    const badge = v === "b" ? "LOCAL" : v === "c" ? "仅本地" : "本地";
    return `<div class="target-line">
      <span class="target-icon">${icon("git")}</span>
      <span class="target-name">Git</span>
      <span class="target-branch">hotfix/request-timeout</span>
      <span class="target-badge">${badge}</span>
    </div>`;
  }

  function commitA() {
    return `<aside class="commit">
      <div class="commit-head">
        <div>
          <div class="eyebrow">Commit <span class="slash">/</span> Local</div>
          <h2>准备提交</h2>
          <div class="commit-meta"><span class="dot"></span>6 个文件已选择 <span>·</span> Git</div>
        </div>
        <span class="commit-count">LOCAL</span>
      </div>
      <div class="field-label"><span class="lab">提交说明</span><button class="ai-link">${icon("sparkles")} AI 生成</button></div>
      <div class="message">${msg}</div>
      <div class="message-foot"><span>草稿会保留</span><span>112 字</span></div>
      <div class="commit-target">
        <div class="field-label"><span class="lab">提交到</span></div>
        ${targetLine("a")}
        <div class="target-note">写入本地分支，推送是单独操作。</div>
      </div>
      <div class="statline"><span class="add">+38 添加</span><span class="del">−12 删除</span><span class="spacer"></span><span class="mini">将提交 6 个文件</span></div>
      <div class="preflight">
        <div class="preflight-title">提交前</div>
        <div class="pf-row">${icon("check")} 6 个文件已勾选</div>
        <div class="pf-row">${icon("check")} 工作副本无冲突</div>
        <div class="pf-row">${icon("check")} 仅写入本地 Git <span class="muted">· 不自动推送</span></div>
      </div>
      <div class="commit-spacer"></div>
      <button class="cta">检查并提交 6 项变更 ${icon("arrow-right")}</button>
      <div class="cta-note">${icon("lock")} 不会自动推送 <span class="shortcut">⌘↵</span></div>
    </aside>`;
  }

  function commitB() {
    return `<aside class="commit">
      <div class="commit-head">
        <div>
          <div class="eyebrow">Commit <span class="slash">/</span> Local <span class="live">● Ready</span></div>
          <h2>准备提交</h2>
          <div class="commit-meta"><span class="dot"></span>Git · hotfix/request-timeout</div>
        </div>
        <span class="commit-count">06 FILES</span>
      </div>
      <div class="field-label"><span class="lab">Message</span><button class="ai-link">${icon("sparkles")} AI 生成</button></div>
      <div class="message">${msg}</div>
      <div class="message-foot"><span>DRAFT KEPT</span><span>112 CHARS</span></div>
      <div class="commit-target">
        <div class="field-label"><span class="lab">Target</span></div>
        ${targetLine("b")}
        <div class="target-note">本地提交 · 不自动推送</div>
      </div>
      <div class="statline"><span class="add">+38 ADD</span><span class="del">−12 DEL</span><span class="spacer"></span><span class="mini">06 FILES</span></div>
      <div class="preflight">
        <div class="preflight-title">Pre-flight</div>
        <div class="pf-row">${icon("check")} 06 FILES SELECTED</div>
        <div class="pf-row">${icon("check")} NO CONFLICTS</div>
        <div class="pf-row">${icon("check")} LOCAL COMMIT ONLY</div>
      </div>
      <div class="commit-spacer"></div>
      <button class="cta">检查并提交 6 项 ${icon("arrow-right")}</button>
      <div class="cta-note">${icon("lock")} LOCAL ONLY · 不自动推送 <span class="shortcut">⌘↵</span></div>
    </aside>`;
  }

  function commitC() {
    return `<aside class="commit">
      <div class="commit-head">
        <div>
          <div class="eyebrow">Commit</div>
          <h2>准备提交</h2>
          <div class="commit-meta"><span class="dot"></span>6 个文件已选择</div>
        </div>
        <span class="commit-count">草稿保留</span>
      </div>
      <div class="steps">
        <div class="step">
          <div class="stepno">1</div>
          <div class="step-content">
            <div class="step-label"><span class="lab">提交说明</span><button class="ai-link">${icon("sparkles")} AI 生成</button></div>
            <div class="message">${msg}</div>
            <div class="message-foot"><span>草稿保留</span><span>112 字</span></div>
          </div>
        </div>
        <div class="step">
          <div class="stepno">2</div>
          <div class="step-content">
            <div class="step-label"><span class="lab">提交到</span><span class="hint">Git</span></div>
            <div class="target-card">${targetLine("c")}</div>
            <div class="target-note">写入本地仓库，推送需要单独确认。</div>
          </div>
        </div>
        <div class="step">
          <div class="stepno">3</div>
          <div class="step-content">
            <div class="step-label"><span class="lab">提交范围</span><span class="hint">下一步核对</span></div>
            <div class="scope">
              <div class="scope-line"><span><b>6</b> 个文件</span><span class="nums"><span class="add">+38</span> <span class="del">−12</span></span></div>
              <div class="scope-note">仅包含左侧勾选的变更</div>
            </div>
          </div>
        </div>
      </div>
      <div class="preflight compact">
        <span class="pf-row">${icon("check")} 6 个文件</span>
        <span class="pf-row">${icon("check")} 无冲突</span>
        <span class="pf-row">${icon("check")} 仅本地 Git</span>
      </div>
      <button class="cta">检查并提交 6 项变更 ${icon("arrow-right")}</button>
      <div class="cta-note">${icon("lock")} 下一步核对文件与说明，不会自动推送</div>
    </aside>`;
  }

  function statusbar(v) {
    if (v === "a") {
      return `<footer class="statusbar">
        <span class="st">${icon("branch")} Git · 本地工作副本</span>
        <span class="st">${icon("check-circle")} 就绪</span>
        <span class="right"><span class="st">UTF-8</span><span class="st">Java</span></span>
      </footer>`;
    }
    if (v === "b") {
      return `<footer class="statusbar">
        <span class="st green">● GIT</span><span class="st">LOCAL WORKTREE</span><span class="st">UTF-8</span><span class="st">LF</span>
        <span class="right"><span class="st">origin/main</span><span class="st">↑ 1</span><span class="st green">●</span></span>
      </footer>`;
    }
    return `<footer class="statusbar">
      <span class="st"><span class="dot"></span> 就绪</span>
      <span class="st">Git · 本地工作副本</span>
      <span class="right"><span class="st">UTF-8</span><span class="st">Java</span></span>
    </footer>`;
  }

  function appA() {
    return `<div class="app v-a">
      ${titlebar("a")}
      <div class="body"><div class="grid">${filesPane("a")}${diffPane("a")}${commitA()}</div></div>
      ${statusbar("a")}
    </div>`;
  }

  function appB() {
    return `<div class="app v-b">
      ${titlebar("b")}
      <div class="body"><div class="grid">${filesPane("b")}${diffPane("b")}${commitB()}</div></div>
      ${statusbar("b")}
    </div>`;
  }

  function appC() {
    return `<div class="app v-c">
      ${titlebar("c")}
      <div class="body">
        <div class="pagehead">
          <div><h1>工作区</h1><div class="sub"><span class="ok"></span>6 项变更 <span class="sep">·</span> 无冲突</div></div>
          <div class="right">
            <div class="review"><span>审阅</span><b>1</b><span>/ 6 个文件</span><span class="track"><i style="width:16.7%"></i></span></div>
            <button class="ghost">${icon("expand")} 展开全部</button>
          </div>
        </div>
        <div class="grid">${filesPane("c")}${diffPane("c")}${commitC()}</div>
      </div>
      ${statusbar("c")}
    </div>`;
  }

  document.getElementById("atelier").innerHTML = appA();
  document.getElementById("nightshift").innerHTML = appB();
  document.getElementById("canvas").innerHTML = appC();
})();
