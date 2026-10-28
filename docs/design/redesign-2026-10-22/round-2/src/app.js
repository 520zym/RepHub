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

  function titlebar(mode) {
    const tabs = `<nav class="tabs" aria-label="主视图">
      <button class="tab active">工作区</button>
      <button class="tab">提交历史</button>
    </nav>`;
    return `<header class="titlebar">
      ${traffic()}
      <div class="identity">
        <span class="app-mark">${icon("branch")}</span>
        <button class="repo-btn">efb-standard ${icon("chevron-down", "sm")}</button>
        <span class="slash">/</span>
        <button class="branch-btn"><span class="branch-glyph">${icon("branch")}</span> hotfix/request-timeout ${icon("chevron-down", "sm")}</button>
      </div>
      ${tabs}
      <div class="actions">
        <span class="sync">${icon("arrow-up")} 1</span>
        <button class="tool">${icon("refresh")}</button>
        <button class="tool">${icon("arrow-down")} 拉取</button>
        <button class="tool">${icon("arrow-up")} 推送</button>
        <button class="tool ai">${icon("sparkles")} AI 审查</button>
      </div>
    </header>`;
  }

  function filesPane(mode) {
    if (mode === "dual") {
      return `<aside class="files">
        <div class="eyebrow">Changes <span class="slash">/</span> 02 sources</div>
        <div class="files-title"><h1>变更</h1></div>
        <div class="files-sub">2 个来源 · 共享同一工作目录</div>
        <div class="source-tabs" aria-label="文件来源">
          <button class="source-tab active">${icon("git")} Git <b>6</b></button>
          <button class="source-tab">${icon("layers")} SVN <b>4</b></button>
        </div>
        <div class="file-tabs"><button class="ftab active">变更 6</button><button class="ftab">全部文件</button></div>
        <div class="search">${icon("search")} 筛选 Git 变更…</div>
        <div class="tree">${filesRows()}</div>
        <div class="files-foot"><span>Git 已选 <b>6</b> / 6</span><span>切换来源查看 SVN</span></div>
      </aside>`;
    }
    return `<aside class="files">
      <div class="eyebrow">Changes <span class="slash">/</span> 06</div>
      <div class="files-title"><h1>变更</h1></div>
      <div class="files-sub"><span class="ok">${icon("check-circle")}</span> 全部变更均已选择</div>
      <div class="file-tabs"><button class="ftab active">变更 6</button><button class="ftab">全部文件</button></div>
      <div class="search">${icon("search")} 筛选变更文件…</div>
      <div class="tree">${filesRows()}</div>
      <div class="files-foot"><span>已选 <b>6</b> / 6</span><span>全部展开</span></div>
    </aside>`;
  }

  function statusbar(mode) {
    return `<footer class="statusbar">
      <span class="st">${icon("branch")} Git · 本地工作副本</span>
      <span class="st">${icon("check-circle")} 就绪</span>
      <span class="right"><span class="st">UTF-8</span><span class="st">Java</span></span>
    </footer>`;
  }

  function modeToggle() {
    return `<div class="mode"><span>${icon("columns")} 并排</span><span class="active">${icon("rows")} 统一</span></div>`;
  }

  function fileNav() {
    return `<div class="file-nav">
      <span class="nav-label">当前文件</span>
      <button class="navbtn" aria-label="上一个文件">${icon("chevron-left")}</button>
      <span class="pos"><b>1</b> / 6</span>
      <button class="navbtn" aria-label="下一个文件">${icon("chevron-right")}</button>
    </div>`;
  }

  function diffPane(mode) {
    const source = mode === "dual" ? `<span class="source-chip">${icon("git")} Git</span>` : "";
    return `<section class="diff-panel">
      <div class="diff-head">
        <div class="file-main">
          <span class="file-chip">${icon("java")}</span>
          <div class="file-titles">
            <h2>HttpClient<span class="ext">.java</span></h2>
            <div class="file-path">src / main / java / network</div>
          </div>
        </div>
        <div class="diff-actions">
          <button class="textbtn">${icon("history")} 文件历史</button>
          ${modeToggle()}
        </div>
      </div>
      <div class="compare">
        <span class="cmp">${source}<b>HEAD</b><span class="arrow">→</span>工作区</span>
        <span class="diffstat"><span class="add">+38</span><span class="del">−12</span></span>
        ${fileNav()}
      </div>
      <div class="code-wrap"><div class="code">${codeRows()}</div><div class="code-fade"></div></div>
    </section>`;
  }

  const msg = `<p class="msg-title">fix: 优化请求超时与连接释放</p>
    <p class="msg-body">统一请求超时配置，补充异常处理，确保响应资源在请求完成后及时关闭。<span class="msg-caret"></span></p>`;

  function commitMain() {
    return `<aside class="commit">
      <div class="commit-head">
        <div>
          <div class="eyebrow">Commit</div>
          <h2>准备提交</h2>
        </div>
      </div>
      <div class="field-label"><span class="lab">提交说明</span><button class="ai-link">${icon("sparkles")} AI 生成</button></div>
      <div class="message">${msg}</div>
      <div class="message-foot"><span>草稿会保留</span><span>112 字</span></div>
      <div class="commit-target">
        <div class="field-label"><span class="lab">提交到</span></div>
        <div class="target-line">
          <span class="target-icon">${icon("git")}</span>
          <span class="target-name">Git</span>
          <span class="target-branch">hotfix/request-timeout</span>
        </div>
      </div>
      <div class="commit-spacer"></div>
      <div class="commit-summary">
        <span><b>6</b> 个文件</span>
        <span class="add">+38</span><span class="del">−12</span>
        <span class="ok">${icon("check")} 无冲突</span>
      </div>
      <button class="cta">检查并提交… ${icon("arrow-right")}</button>
      <div class="cta-note">${icon("lock")} 仅写入本地 Git · 不会自动推送</div>
    </aside>`;
  }

  function targetOption(provider, branch, count, kind, extraClass = "") {
    const iconName = provider === "Git" ? "git" : "layers";
    const detail = provider === "Git" ? `${count} 个文件 · 写入本地分支` : `${count} 个文件 · 直接写入服务器`;
    return `<div class="target-option ${extraClass}">
      <span class="ck on">${icon("check", "sm")}</span>
      <span class="target-icon">${icon(iconName)}</span>
      <div class="target-copy">
        <div class="target-top"><span class="provider">${provider}</span><span class="path">${branch}</span></div>
        <div class="target-sub">${detail}</div>
      </div>
      <span class="kind">${kind}</span>
    </div>`;
  }

  function commitDual() {
    return `<aside class="commit">
      <div class="commit-head">
        <div>
          <div class="eyebrow">Commit</div>
          <h2>准备提交</h2>
        </div>
      </div>
      <div class="field-label"><span class="lab">提交说明</span><button class="ai-link">${icon("sparkles")} AI 生成</button></div>
      <div class="message">${msg}</div>
      <div class="message-foot"><span>两个目标共用此说明</span><span>112 字</span></div>
      <div class="commit-target">
        <div class="field-label"><span class="lab">提交到 2 个目标</span></div>
        <div class="target-list">
          ${targetOption("Git", "hotfix/request-timeout", 6, "本地")}
          ${targetOption("SVN", "^/EfbServer-J/trunk", 4, "服务器", "svn")}
        </div>
      </div>
      <div class="commit-spacer"></div>
      <div class="dual-summary">
        <span><b>6</b> 个文件</span>
        <span>·</span>
        <span class="ok">${icon("check")} 无冲突</span>
      </div>
      <div class="dual-warning">
        ${icon("warning")} Git 只写入本地；SVN 会直接提交服务器。
      </div>
      <button class="cta">检查并提交 2 个目标 ${icon("arrow-right")}</button>
      <div class="cta-note">下一步分别核对文件与说明</div>
    </aside>`;
  }

  function commitDock() {
    return `<div class="commit-dock">
      <div class="dock-copy">
        <div class="dock-eyebrow"><span class="dot"></span> Commit / Git</div>
        <div class="dock-message">fix: 优化请求超时与连接释放</div>
        <div class="dock-meta">
          <span><b>6</b> 个文件</span><span class="add">+38</span><span class="del">−12</span>
          <span class="ok">${icon("check")} 无冲突</span>
        </div>
      </div>
      <div class="dock-target">
        <span class="target-icon">${icon("git")}</span>
        <div>
          <div class="target-name">Git</div>
          <div class="target-branch">hotfix/request-timeout</div>
        </div>
      </div>
      <div class="dock-actions">
        <button class="dock-expand">${icon("message")} 写说明</button>
        <button class="dock-cta">检查并提交 ${icon("arrow-right")}</button>
      </div>
    </div>`;
  }

  function appMain() {
    return `<div class="app v-a v-a2">
      ${titlebar("main")}
      <div class="body">
        <div class="grid">${filesPane("main")}${diffPane("main")}${commitMain()}</div>
      </div>
      ${statusbar("main")}
    </div>`;
  }

  function appNarrow() {
    return `<div class="app v-a v-a2 v-a2-narrow">
      ${titlebar("narrow")}
      <div class="body">
        <div class="grid">${filesPane("main")}${diffPane("narrow")}</div>
        ${commitDock()}
      </div>
      ${statusbar("narrow")}
    </div>`;
  }

  function appDual() {
    return `<div class="app v-a v-a2 v-a2-dual">
      ${titlebar("dual")}
      <div class="body">
        <div class="grid">${filesPane("dual")}${diffPane("dual")}${commitDual()}</div>
      </div>
      ${statusbar("dual")}
    </div>`;
  }

  document.getElementById("main").innerHTML = appMain();
  document.getElementById("narrow").innerHTML = appNarrow();
  document.getElementById("dual").innerHTML = appDual();
})();
