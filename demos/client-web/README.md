# PendingBot 客户端网页 demo

用 React 19 + TypeScript + Vite 复刻 PendingBot 客户端，独立于 admin 与 edge，不连接真实账号、API 或模型。

## 运行

需要 Node.js 20.19+ 或 22.12+。

```sh
cd demos/client-web
npm ci
npm run dev
```

本机预览地址： http://127.0.0.1:5188/ 。生产构建用 `npm run build`，静态产物在 `dist/`；`npm run preview` 可本机预览构建结果。项目不参与根目录 Bun workspace，避免把演示页混入正式产品构建或部署。

## 复刻依据

- `docs/screenshots/main.png`、`contacts.png`、`letter.png`：Mac 窗口结构、会话卡片、头像、好友列表和来信阅读版式。
- `apps/pendingbot/Sources/Components/Theme.swift`：深绿/暖白色板、深色主题、14/18px 圆角与 760px 阅读列。
- `Features/Root/WideRootView.swift`、`TopTab.swift`：56px 图标栏、360px 默认侧栏、五个导航入口。
- `Features/Message/ComposerView.swift`、`BubbleView.swift`：悬浮胶囊输入框、附件圆按钮、30px 消息头像与双向气泡。
- `Features/Crew/CrewTabView.swift`：沿用「待建设」，不把被摘下的旧机组 UI 当作现有产品。

桌面采用侧栏 + 详情；700px 及以下采用底部导航 + 列表/详情切换。原生毛玻璃、SF Symbols、New York/SF 系统字体分别用 CSS 渐变、SVG 和系统字体回退近似，并非所有浏览器均能逐像素一致。手机布局按客户端交互结构适配，未做 iPhone 截图差分。

## 可演示交互

- 选会话、新会话、好友资料进入聊天；Enter 发送，Shift+Enter 换行，中文输入法合成期间不发送。
- 预设本地回复、输入中动画、停止回复、文件名附件（不读取/上传文件内容）。
- 会话/消息搜索、⌘/Ctrl K、好友分类/排序、本地添加好友与创建演示群。
- 来信列表与正文；个人昵称、演示钱包/能力页、浅色/深色外观。
- 弹窗 Escape 关闭、焦点约束与返回原焦点；侧栏收起/展开。

演示群也使用预设回复，不模拟真实多人调度。二维码是图标占位；提醒开关仅演示状态。没有登录、实际支付、模型推理、语音/视频通话、上传、同步或后端功能。

对话、好友、昵称和主题仅写入浏览器 localStorage（`pendingbot-demo-*`），刷新后保留。若需恢复初始截图状态，可在浏览器站点数据中清除此本地预览的数据。

## 验证记录（2026-10-22）

- 独立安装依赖后的 TypeScript 检查与 Vite 生产构建通过。
- 浏览器验证：桌面消息/好友/来信/设置、发送与预设回复、好友分类、搜索定位、新建会话、停止回复、刷新保留对话、浅深主题。
- 390 × 844 手机列表与聊天页面可操作；实测文档宽度与滚动宽度均为 390，无页面横向溢出。
- 待人工 QA：与当前安装客户端逐屏对照；真实 iPhone/iPad 浏览器键盘、安全区、附件选择、VoiceOver。未运行原生客户端构建，未部署。
