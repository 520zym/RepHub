# 历史列表与代码行距验证

日期：2026-10-15。

## 修改结果

- 代码预览与冲突编辑器统一使用 13 点等宽字体、22 点行高；语法高亮、输入和主题更新保留段落样式，行号与中文、Emoji、空行和末尾空行对齐。
- 历史图谱宽度最多约 70 点，窄侧栏随可用宽度收缩；超出的真实轨道通过左右按钮查看，视口之外的节点用方向标识提示。
- 提交标题允许两行，作者、日期和版本号在窄侧栏分行显示；图谱在后台计算并缓存，取消或筛选时停止不需要的计算。

## 验证范围

全部仓库操作使用临时目录中的独立 Git 测试仓库，包含 658 条提交、24 条分支轨道和合并提交。没有对正式 EFB 仓库执行测试或写操作。原生界面使用独立 bundle ID 的测试应用，不修改正式应用偏好。

| 场景 | 结果 |
| --- | --- |
| 初始 150 条历史继续加载到全部 658 条 | 图谱没有继续挤占标题，页尾显示已到最早记录 |
| 历史侧栏缩小至 331 点 | 标题正常换行，作者与版本号一行、日期另起一行 |
| 查看第 20–24 条分支轨道 | 能看到对应节点；其他轨道的节点显示方向提示 |
| 最终构建重新打开历史 | 首批 150 条和窄侧栏布局正常 |
| 代码预览 | 原生截图核对行距和行号；空行、中文和 Emoji 显示正常 |
| 针对性测试 | 7 个 XCTest 和 13 个 Swift Testing 测试通过，共 20 个 |
| 应用打包与签名检查 | debug 应用构建成功，codesign 深度严格验证通过 |

测试命令：

```sh
swift test --filter 'GitGraphLayoutTests|LocalFileHighlightTests|CodeLineNumberRulerTests|CodeLineIndexTests|NumberedCodeEditorSynchronizerTests'
scripts/build-app.sh debug
codesign --verify --deep --strict build/RepHub.app
```

未执行全量测试或真实 SVN 服务联调。本次未修改版本控制适配器及历史分页查询；SVN 使用共同的历史行展示，不绘制 Git 分支图。

## 原生截图

- [最终历史布局](history-final.png)
- [加载全部 658 条历史](history-658.png)
- [窄侧栏](history-narrow.png)
- [查看后方轨道](history-later-lanes.png)
- [代码行距与行号](code-spacing.png)
