# Hanako Mobile（鸿蒙壳）

把 HanaAgent 官方移动端页面（`/mobile/`）打包成鸿蒙 App 的壳工程。基于 ArkWeb，保留官方页面 100% 的交互与视觉，外层补上原生体验：可拖拽悬浮球、扫码连接、系统栏自动取色、连接失败兜底、网络恢复自愈、Cookie 免登录。

## 工程结构

```
HanakoMobile/
├── AppScope/                     # 应用级配置与图标
│   └── resources/base/media/     # 应用图标（取自官方 icon，warm-paper 背景）
└── entry/src/main/
    ├── module.json5              # 权限（INTERNET / GET_NETWORK_INFO）、竖屏锁定
    ├── ets/
    │   ├── entryability/EntryAbility.ets   # 系统栏同色填充（不启用全屏布局，内容留在安全区）
    │   └── pages/Index.ets       # 核心壳页面（ArkWeb + 悬浮球 + 扫码 + 注入修正）
    └── resources/                # 主题色对齐（#F7F1E7 warm-paper）
```

## 用 DevEco Studio 跑起来

1. 打开 DevEco Studio → File → Open → 选择本目录（`HanakoMobile`）
2. 首次打开会自动配置签名（Signing Configs），勾选自动签名即可
3. 连接手机（USB 调试）→ 点 Run，直接装到真机
4. 命令行方式：`devecocli run --device <serial>`（需先配置签名）

构建产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

## 首次使用

1. 打开 App，首次会显示「正在连接 Hanako…」加载遮罩
2. 电脑端 Hanako 里为这台设备生成**访问密钥**，在页面里输入并登录
3. 登录后会话 Cookie 由 ArkWeb 自动持久化，之后打开即免登录

## 已实现的能力

| 能力 | 说明 |
|---|---|
| 系统栏同色 | 全屏布局：系统栏背景透明，状态栏区域透出底下内容（ArkWeb 页面横栏或壳层取色背景），不产生独立色带；顶部横栏由注入 CSS 垫实测状态栏高度（同时覆写全局 `--titlebar-h` 变量，使浏览器卡/toast/预览面板等依赖该变量的元素同步偏移，避免被加高的横栏遮挡）；图标颜色按背景亮度自适应 |
| 系统栏自动取色 | 壳层每 2.5s 轮询页面主背景色，优先读 body 实际计算背景（主题无论切在 html 还是 body 都能取到），变化时同步系统栏；页面 reload 后立即重读 |
| 白条 ↔ 设置面板 | 右缘白条点击向左展开成设置面板（300ms 形态切换动画），点空白折叠回白条；面板宽高随屏幕自适应（窄屏收缩），注入字号用 rem 跟随系统字体缩放 |
| 输入框适配 | 注入脚本按 scrollHeight 自适应高度（提示文字一行矮、多行高） |
| 扫码连接 | 设置面板「扫码连接」调起系统扫码（Scan Kit 默认界面，相机权限预授权），识别出服务器链接后自动保存并连接 |
| 连接兜底 | 服务器不可达时显示暖色错误页（重新连接 / 修改地址） |
| 网络恢复自愈 | WiFi/数据切换后自动重新连接（`netAvailable` 监听） |
| Cookie 免登录 | ArkWeb 默认持久化会话 Cookie |
| 页面适配修正 | 注入 CSS：下拉弹层防超界、模型名 pill 字号收小；注入脚本隐藏工作台「选择其他文件夹」「额外文件夹」选项（文本匹配，不依赖哈希类名） |
| 返回键 | 页面内有历史则后退，否则退出；设置面板优先关闭 |
| 竖屏锁定 | 避免旋转导致布局跳动 |

## 扫码连接说明

- 二维码内容格式：`http://主机IP:端口/mobile/`（即服务器链接）
- App 同时预留 `hanako://connect?url=<encoded>` scheme 解析，桌面端若生成此类二维码可直接识别
- 依赖 Scan Kit（华为手机系统扫码服务，无需申请相机权限）；首次调用会弹隐私横幅，属正常现象

## 已知限制与后续方向

- **仅限局域网**：默认地址是内网 IP，出家门不可用。后续可接 frp / Tailscale / 零信任 VPN 暴露到公网，App 内改地址或扫码即可
- **无推送**：App 在后台时 WebSocket 会被系统挂起，收不到新消息提醒。后续可在壳层加原生 WebSocket 连接 + 本地通知（需要解析 Hanako 的事件协议，`/api/resource-io/events`）
- **注入样式脆弱性**：CSS 修正里的类名是官方构建哈希（如 `_model-pill_5fa8e`），官方页面更新版本后可能失效，改动集中在 `injectUiFixes()` 方法
- **图标**：已用官方 2048 icon 缩放适配分层图标，想换可以替换 `resources/base/media/foreground.png` / `background.png`
