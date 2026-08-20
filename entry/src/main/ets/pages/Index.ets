/*
 * Hanako 移动端壳
 * ArkWeb 加载 HanaAgent 移动端页面，提供连接错误兜底、服务器地址配置、
 * 扫码连接、右缘白条菜单；背景色恒定取启动页/封面（hanako 标志）奶油色
 */
import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { connection, http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { scanBarcode } from '@kit.ScanKit';
import { url } from '@kit.ArkTS';
import { NotificationClient } from '../service/NotificationClient';
import { PushBridge } from '../service/PushBridge';
import { readShare, clearShareSync, SharePayload, ShareFileItem } from '../service/ShareBridge';
import { saveBase64ToLibrary, copyBase64ToClipboard, shareBase64 } from '../service/ImageActions';

const DOMAIN: number = 0x0001;
const TAG: string = 'HanakoShell';
// 默认服务器地址：空，首次打开引导用户自行设置
const DEFAULT_URL: string = '';
// 全局统一背景色：hanako 应用标志（startIcon）背景色，加载页/首页/错误页/窗口背景一致
const HANAKO_BG: string = '#F3ECDA';
// 加载标语（与电脑端启动画面同源：desktop/src/locales/zh.json splash.lines，{name}=Hanako）
const SPLASH_LINES: string[] = [
  'Hanako 想起了那天傍晚的光',
  '有些句子在记忆里发了芽',
  'Ta 在回忆里找到了你的轮廓',
  '风穿过那些旧对话',
  '那些文字泡在时间里，变得很软',
  'Hanako 记得你那天笑了很久',
  '有一段记忆被你折了角',
  'Ta 把散落的情绪重新收好',
  'Hanako 闻到了某个下午的橘子味',
  '那些对话还带着体温'
];
const PREFS_NAME: string = 'hanako_mobile';
const KEY_SERVER_URL: string = 'server_url';
// 白条位置记忆：吸附边（'L'/'R'）+ 高度比例
const KEY_BALL_EDGE: string = 'ball_edge';
const KEY_BALL_Y: string = 'ball_y_ratio';
// 白条/悬浮球吸附后中心距屏幕边缘的距离（vp：条宽 14 / 球径 52 的一半，完全贴边）
const BALL_EDGE_INSET: number = 7;
const BALL_EDGE_INSET_ROUND: number = 26;
// 白条手势热区（vp，视觉层居中，热区放大便于手指按住；条形态热区收窄避免遮挡页面右缘内容）
const BALL_HIT_W: number = 56;
const BALL_HIT_W_BAR: number = 28;
const BALL_HIT_H: number = 100;
const BALL_HIT_H_BAR: number = 110;
// 白条拖动判定阈值（vp）：超过视为拖拽，未超过视为点击打开菜单
const BALL_DRAG_DISTANCE: number = 5;
// 悬浮球静置时长（毫秒）：静置不动自动变形为细条吸附边缘
const BALL_IDLE_MS: number = 3000;
// onErrorReceive 的 ERR_ABORTED：页面导航被主动中断（如 SPA 路由），不算失败
const ERR_ABORTED: number = -3;
// 超时类错误码（ArkWeb 网络协议栈错误列表）：用于区分错误页文案
const ERR_TIMED_OUT: number = -7;
const ERR_CONNECTION_TIMED_OUT: number = -118;
// 页面加载超时（毫秒）：服务器不可达等场景 ArkWeb 可能长时间无回调（TCP 黑洞），
// 超时后强制进入错误页，避免一直停留在加载页
const LOAD_TIMEOUT_MS: number = 20000;
// 壳层例行检查间隔（毫秒）：登录态 / 分享 / 推送心跳 / 深色主题图标色
const WATCH_POLL_MS: number = 2500;

/**
 * show_card 原生卡片渲染注入脚本（runJavaScript 幂等注入，见 ensureCardHook）：
 * mobile PWA 前端没有实现 show_card（原生 HTML 卡片）渲染，工具块的 details.code
 * 没人消费，手机上只显示一个空壳。本脚本 hook 住 WebSocket，拦截 tool_end 事件，
 * 提取 show_card 工具的 details.code（卡片 HTML），找到工具块 DOM 锚点，在其后插入
 * srcdoc iframe 渲染；CSS 变量从父页面实时读取（深浅主题自适应），卡片高度由 iframe
 * 内 ResizeObserver + postMessage 上报回填。
 * 约束：仅覆盖实时流式（WS 通道）产生的卡片；历史消息（REST 加载，toolCalls 不含
 * details）暂不渲染。幂等：window.__hanakoCardHookInit 标志位防重复初始化。
 */
const CARD_HOOK_SCRIPT: string = `(function () {
  if (window.__hanakoCardHookInit) return;
  window.__hanakoCardHookInit = true;
  console.log('[hanako-card] injected');
  // 拦截 /api/cards 的 PUT（mobile 无 studio_owner scope 必 403）：
  // 伪造注册成功，把 code / varsCss 分片 console 输出，由壳层 onConsole 收集并接管 GET 渲染
  var origFetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (url.indexOf('/api/cards/') > -1) {
        var method = ((init && init.method) || 'GET').toUpperCase();
        if (method === 'PUT') {
          var body = (init && init.body) || '';
          var parsed = typeof body === 'string' ? JSON.parse(body) : body;
          if (parsed && typeof parsed.code === 'string') {
            var id = url.split('/api/cards/')[1].split('?')[0].split('/')[0];
            var code = parsed.code;
            var chunk = 6000;
            var total = Math.ceil(code.length / chunk);
            for (var i = 0; i < total; i++) {
              console.log('[hanako-card-code]' + id + '|' + i + '|' + total + '|' + code.substr(i * chunk, chunk));
            }
            if (typeof parsed.varsCss === 'string' && parsed.varsCss.length > 0) {
              var vc = parsed.varsCss;
              var vt = Math.ceil(vc.length / chunk);
              for (var j = 0; j < vt; j++) {
                console.log('[hanako-card-vars]' + id + '|' + j + '|' + vt + '|' + vc.substr(j * chunk, chunk));
              }
            }
            console.log('[hanako-card] fake put ok ' + id + ' chunks=' + total);
            return Promise.resolve(new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
          }
        }
      }
    } catch (e) {}
    return origFetch.apply(this, arguments);
  };
  console.log('[hanako-card] fetch hooked');
})();`;

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State currentUrl: string = DEFAULT_URL;
  @State isLoading: boolean = true;
  @State hasError: boolean = false;
  // 错误页提示文案（空串显示默认文案）
  @State errHint: string = '';
  @State isChatReady: boolean = false;
  @State showSettings: boolean = false;
  @State showImgMenu: boolean = false;
  private menuB64: string = '';
  private menuName: string = '';
  @State editUrl: string = DEFAULT_URL;
  // 壳层统一背景色（系统栏 / 窗口 / 封面 / 错误页）：恒定 = 启动页与封面取色，不随主界面变化
  @State bgColor: string = HANAKO_BG;
  // 加载页标语（电脑端 splash.lines 随机起始 + 3 秒轮播）
  @State splashText: string = SPLASH_LINES[0];
  private splashTimer: number = -1;
  // 状态栏高度（vp），用于注入 CSS 让顶部横栏避让状态栏
  @State statusBarHeightVp: number = 0;
  // 导航条高度（vp），用于白条拖拽纵向边界
  @State navBarHeightVp: number = 0;
  // 白条：固定位置（中心点 vp 坐标，吸附左/右缘，高度可拖拽）
  @State ballX: number = -1;
  @State ballY: number = -1;
  // 白条拖动中（用于视觉反馈）
  @State ballDragging: boolean = false;
  // 形态：true=悬浮球（启动默认球态/拖动中），false=细条（静置后自动变形）
  @State isBall: boolean = true;
  private screenW: number = 0;
  private screenH: number = 0;
  // 拖拽起点（白条中心点，vp）
  private dragOriginX: number = 0;
  private dragOriginY: number = 0;
  // 加载封面图标尺寸（vp）：与启动窗口图标视觉一致。
  // startWindowIcon 按图片像素显示（256px），vp 尺寸 = 256 / 屏幕密度
  @State iconSizeVp: number = 85;
  // 悬浮球静置计时器
  private idleTimer: number = -1;
  // 推送心跳节流时间戳
  private lastHeartbeatTs: number = 0;
  // App 是否在前台（后台时 WS 通知改为弹系统通知，前台只做页面内角标）
  private appVisible: boolean = true;
  // 服务器地址输入框控制器（面板出现时定位光标）
  private serverInputCtrl: TextInputController = new TextInputController();
  private watchTimer: number = -1;
  private loadTimer: number = -1;
  private lastThemeDark: boolean = false;
  private win: window.Window | null = null;
  private netConn: connection.NetConnection | null = null;
  // onInterceptRequest 文档级注入：预取 mobile HTML + 注入卡片 hook 后的缓存
  private cardHtmlCache: string = '';
  private cardPrefetching: boolean = false;
  // 卡片 code 收集：注入脚本伪造 PUT 成功后分片 console 输出，这里拼接存储，供 GET 拦截渲染
  private cardChunks: Map<string, string[]> = new Map();
  private cardTotals: Map<string, number> = new Map();
  private cardCodeStore: Map<string, string> = new Map();
  private cardVarsStore: Map<string, string> = new Map();
  private cardVarsChunks: Map<string, string[]> = new Map();
  private cardVarsTotals: Map<string, number> = new Map();

  aboutToAppear(): void {
    this.loadServerUrl();
    this.watchNetwork();
    this.acquireWindow();
    this.startWatchLoop();
    // 预取 mobile HTML 并注入卡片 hook（onInterceptRequest 拦截主文档时用，
    // 保证 hook 先于页面任何 JS 执行，彻底解决自动恢复会话的 WS 竞态）
    this.prefetchCardHtml();
    // 加载页标语：随机起始 + 3 秒轮播（电脑端启动画面同款文案）
    this.startSplashRotate();
    // 通知事件：前台刷新页面内未读角标；后台（App 不可见）弹系统通知
    NotificationClient.setListener((title: string, body: string, sp: string) => {
      hilog.info(DOMAIN, TAG, 'unread notify: %{public}s sp=%{public}s', body.slice(0, 30), sp);
      this.pushUnreadToPage(sp);
      if (!this.appVisible) {
        NotificationClient.publishLocal(title, body);
      }
    });
    // 前台收到华为推送（WS 遗漏时的兜底通道）：刷新未读角标
    PushBridge.setMessageListener((title: string, content: string) => {
      hilog.info(DOMAIN, TAG, 'push message foreground: %{public}s', content.slice(0, 30));
      this.pushUnreadToPage('');
    });
    // 兜底启动加载超时计时：即使 Web 组件的 onPageBegin 因异常未触发，
    // 20 秒后也能强制退出加载态进入错误页（onPageBegin 会正常重置计时）
    this.startLoadTimer();
  }

  /** 把未读通知推给页面注入逻辑（页面原生未读状态驱动角标，这里只做刷新 nudge） */
  private pushUnreadToPage(sp: string): void {
    if (!this.isChatReady) {
      return;
    }
    try {
      const script: string = `(()=>{try{if(window.__hanakoNudgeUnread)window.__hanakoNudgeUnread();}catch(e){}})()`;
      this.controller.runJavaScript(script).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'push unread failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pushUnreadToPage error: %{public}s', JSON.stringify(e));
    }
  }

  /** 加载标语轮播：随机打乱顺序后从第一条开始，每 3 秒切换（电脑端同款节奏） */
  private startSplashRotate(): void {
    this.stopSplashRotate();
    const lines: string[] = SPLASH_LINES.slice();
    lines.sort(() => Math.random() - 0.5);
    this.splashText = lines[0];
    let i: number = 0;
    this.splashTimer = setInterval(() => {
      i = (i + 1) % lines.length;
      this.splashText = lines[i];
    }, 3000);
  }

  private stopSplashRotate(): void {
    if (this.splashTimer !== -1) {
      clearInterval(this.splashTimer);
      this.splashTimer = -1;
    }
  }

  /** 页面每次显示（含从后台回前台、分享拉起）时立即消费分享数据 */
  onPageShow(): void {
    this.appVisible = true;
    this.checkShare();
    // 回前台：通知 WS 可能已被系统挂起（鸿蒙后台限制），强制重建（内部 10 秒节流）
    if (this.currentUrl.length > 0 && this.isChatReady) {
      NotificationClient.reconnect(this.currentUrl).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'notify reconnect failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  /** 页面隐藏（App 退后台/被覆盖）：后台通知改走系统通知栏 */
  onPageHide(): void {
    this.appVisible = false;
  }

  aboutToDisappear(): void {
    if (this.netConn !== null) {
      try {
        this.netConn.unregister((err: BusinessError) => {
          // AsyncCallback 成功时 err 为 undefined，必须先判空
          if (err && err.code) {
            hilog.warn(DOMAIN, TAG, 'net unregister failed: %{public}s', JSON.stringify(err));
          }
        });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'unwatch network failed: %{public}s', JSON.stringify(e));
      }
      this.netConn = null;
    }
    this.stopWatchLoop();
    this.stopLoadTimer();
    this.stopIdleTimer();
    this.stopSplashRotate();
    NotificationClient.setListener(null);
    NotificationClient.disconnect();
  }

  private loadServerUrl(): void {
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      const ctx = hostCtx as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: PREFS_NAME });
      const saved = store.getSync(KEY_SERVER_URL, DEFAULT_URL) as string;
      if (saved && saved.trim().length > 0) {
        this.currentUrl = saved.trim();
        this.editUrl = this.currentUrl;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadServerUrl failed: %{public}s', JSON.stringify(e));
    }
  }

  private acquireWindow(): void {
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      window.getLastWindow(hostCtx as common.UIAbilityContext).then((w: window.Window) => {
        this.win = w;
        this.updateStatusBarHeight();
        this.initBallPosition();
        this.applyBarIcons(this.lastThemeDark);
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'getLastWindow failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'acquireWindow error: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 初始化/适配白条位置。不依赖 onAreaChange，用窗口属性双保险。
   * 首次定位：恢复记忆的吸附边与高度比例（无记忆默认右缘 55%）；
   * 之后（旋转/窗口变化）：按原边缘与高度比例重算，保持用户拖拽的位置。
   */
  private initBallPosition(): void {
    let w: number = 0;
    let h: number = 0;
    try {
      if (this.win !== null) {
        const rect = this.win.getWindowProperties().windowRect;
        w = typeof rect.width === 'number' ? rect.width : 0;
        h = typeof rect.height === 'number' ? rect.height : 0;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'initBallPosition failed: %{public}s', JSON.stringify(e));
    }
    // 尺寸变化前记录原边缘与高度比例
    const wasInit: boolean = this.ballX >= 0 && this.ballY >= 0 && this.screenW > 0 && this.screenH > 0;
    const wasLeft: boolean = wasInit ? this.ballX < this.screenW / 2 : false;
    const yRatio: number = wasInit ? this.ballY / this.screenH : 0.55;
    if (w > 0 && h > 0) {
      this.screenW = this.getUIContext().px2vp(w);
      this.screenH = this.getUIContext().px2vp(h);
      // 屏幕密度（px/vp）：用于让加载封面图标与启动窗口图标（按 512px 像素显示）视觉一致
      if (this.screenW > 0) {
        const d: number = w / this.screenW;
        if (d > 0) {
          this.iconSizeVp = Math.round(512 / d);
        }
      }
    }
    if (this.screenW > 0 && this.screenH > 0) {
      if (wasInit) {
        this.ballX = wasLeft ? this.ballInset() : this.screenW - this.ballInset();
        this.ballY = this.clampBallY(yRatio * this.screenH);
      } else if (this.ballX < 0) {
        this.restoreBallPosition();
      }
    }
  }

  /** 首次恢复白条位置：记忆的吸附边 + 高度比例；无记忆时默认右缘 55% */
  private restoreBallPosition(): void {
    let edge: string = 'R';
    let ratio: number = 0.55;
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx !== undefined) {
        const ctx = hostCtx as common.UIAbilityContext;
        const store = preferences.getPreferencesSync(ctx, { name: PREFS_NAME });
        edge = store.getSync(KEY_BALL_EDGE, 'R') as string;
        const saved: number = store.getSync(KEY_BALL_Y, 0.55) as number;
        if (typeof saved === 'number' && saved > 0.05 && saved < 0.95) {
          ratio = saved;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'restore ball position failed: %{public}s', JSON.stringify(e));
    }
    if (edge !== 'L') {
      edge = 'R';
    }
    this.ballX = edge === 'L' ? this.ballInset() : this.screenW - this.ballInset();
    this.ballY = this.clampBallY(ratio * this.screenH);
    hilog.info(DOMAIN, TAG, 'ball restored: edge=%{public}s x=%{public}d y=%{public}d', edge, this.ballX, this.ballY);
  }

  /** 白条纵向边界钳制：不藏进状态栏与导航条 */
  private clampBallY(y: number): number {
    const half: number = 38;
    const minY: number = this.statusBarHeightVp + half + 8;
    const maxY: number = this.screenH - this.navBarHeightVp - half - 8;
    if (maxY <= minY) {
      return this.screenH / 2;
    }
    return Math.min(Math.max(y, minY), maxY);
  }

  /** 当前形态贴边距离（球半宽 26 / 条半宽 7） */
  private ballInset(): number {
    return this.isBall ? BALL_EDGE_INSET_ROUND : BALL_EDGE_INSET;
  }

  /** 拖拽松手：吸附到最近的屏幕边缘（按当前形态计算贴边距离）并记忆位置 */
  private snapBall(): void {
    if (this.screenW <= 0) {
      return;
    }
    const onLeft: boolean = this.ballX < this.screenW / 2;
    const inset: number = this.isBall ? BALL_EDGE_INSET_ROUND : BALL_EDGE_INSET;
    const tx: number = onLeft ? inset : this.screenW - inset;
    const ty: number = this.clampBallY(this.ballY);
    // 推荐写法：UIContext.animateTo（全局 animateTo 已废弃）
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.ballX = tx;
      this.ballY = ty;
    });
    this.saveBallPosition(onLeft, ty);
  }

  /**
   * 悬浮球静置计时：静置 BALL_IDLE_MS 后自动变形为细条并重新贴边。
   * 拖动中 / 设置菜单打开时跳过，由对应流程重新启动计时。
   */
  private restartIdleTimer(): void {
    this.stopIdleTimer();
    this.idleTimer = setTimeout(() => {
      this.idleTimer = -1;
      if (this.ballDragging || this.showSettings) {
        return;
      }
      if (this.isBall) {
        const onLeft: boolean = this.ballX < this.screenW / 2;
        const ty: number = this.clampBallY(this.ballY);
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          this.isBall = false;
          this.ballX = onLeft ? BALL_EDGE_INSET : this.screenW - BALL_EDGE_INSET;
          this.ballY = ty;
        });
        this.saveBallPosition(onLeft, ty);
      }
    }, BALL_IDLE_MS);
  }

  private stopIdleTimer(): void {
    if (this.idleTimer !== -1) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
  }

  /** 记忆白条位置：吸附边 + 高度比例（屏幕尺寸变化后按比例恢复） */
  private saveBallPosition(onLeft: boolean, y: number): void {
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      const ctx = hostCtx as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: PREFS_NAME });
      store.putSync(KEY_BALL_EDGE, onLeft ? 'L' : 'R');
      store.putSync(KEY_BALL_Y, this.screenH > 0 ? y / this.screenH : 0.55);
      store.flush().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'flush ball pos failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save ball position failed: %{public}s', JSON.stringify(e));
    }
  }

  private updateStatusBarHeight(): void {
    try {
      if (this.win === null) {
        return;
      }
      const area: window.AvoidArea = this.win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusBarHeightVp = this.getUIContext().px2vp(area.topRect.height);
      this.navBarHeightVp = this.getUIContext().px2vp(area.bottomRect.height);
      hilog.info(DOMAIN, TAG, 'statusBarHeight=%{public}d vp, navBarHeight=%{public}d vp', this.statusBarHeightVp, this.navBarHeightVp);
      // 页面已就绪时，用最新状态栏高度刷新注入样式（顶部横栏避让）
      if (this.isChatReady) {
        this.injectUiFixes();
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'updateStatusBarHeight failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 系统栏图标颜色：仅按页面是否深色主题切换（亮底深图标 / 暗底浅图标）。
   * 背景色不跟随主界面——系统栏/窗口/壳层 UI 一律保持启动页与封面的奶油色 HANAKO_BG。
   */
  private applyBarIcons(dark: boolean): void {
    try {
      if (this.win === null) {
        return;
      }
      this.lastThemeDark = dark;
      const iconColor: string = dark ? '#FFFFFFFF' : '#00000000';
      hilog.info(DOMAIN, TAG, 'applyBarIcons dark=%{public}s', String(dark));
      // 系统栏背景保持透明，状态栏区域透出底下内容（ArkWeb 页面或窗口背景）
      this.win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: iconColor,
        navigationBarContentColor: iconColor
      });
      // 窗口背景恒定 = hanako 标志背景（启动页/封面同色），不随主界面变化
      this.win.setWindowBackgroundColor(HANAKO_BG);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'applyBarIcons failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 读取页面主题模式：仅用于系统栏图标深浅色，不参与背景色。
   * 页面注入逻辑会按 --bg 亮度给 <html> 加/去 hanako-dark 类（见 injectUiFixes）。
   */
  private readThemeDark(): void {
    try {
      const expr: string =
        `(function(){try{return document.documentElement.classList.contains('hanako-dark')?'1':'0';}` +
        `catch(e){return '0';}})()`;
      this.controller.runJavaScript(expr).then((res: string) => {
        const dark: boolean = res !== null && res.trim() === '1';
        if (dark !== this.lastThemeDark) {
          this.applyBarIcons(dark);
        }
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'readThemeDark failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'readThemeDark error: %{public}s', JSON.stringify(e));
    }
  }

  private startWatchLoop(): void {
    this.stopWatchLoop();
    this.watchTimer = setInterval(() => {
      this.readThemeDark();
      this.checkLoggedIn();
      this.checkShare();
      this.beatPushHeartbeat();
      this.ensureCardHook();
    }, WATCH_POLL_MS);
  }

  /** 前台推送心跳（20 秒节流）：告知服务端手机在线，插件跳过推送避免与 WS 通知重复 */
  private beatPushHeartbeat(): void {
    const now: number = Date.now();
    if (now - this.lastHeartbeatTs < 20000) {
      return;
    }
    this.lastHeartbeatTs = now;
    if (this.currentUrl.length > 0 && this.isChatReady) {
      PushBridge.heartbeat(this.currentUrl).catch(() => {
      });
    }
  }

  private stopWatchLoop(): void {
    if (this.watchTimer !== -1) {
      clearInterval(this.watchTimer);
      this.watchTimer = -1;
    }
  }

  private watchNetwork(): void {
    try {
      this.netConn = connection.createNetConnection();
      this.netConn.on('netAvailable', () => {
        hilog.info(DOMAIN, TAG, 'network available, hasError=%{public}s', String(this.hasError));
        if (this.hasError) {
          this.reloadPage();
        }
      });
      this.netConn.register((err: BusinessError) => {
        // AsyncCallback 成功时 err 为 undefined，必须先判空
        if (err && err.code) {
          hilog.warn(DOMAIN, TAG, 'net register failed: %{public}s', JSON.stringify(err));
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'watchNetwork failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 注入移动端适配修正脚本（页面是桌面端设计，个别元素在手机上需要覆盖）：
   * 1. CSS：下拉弹层防超界、模型名字号收小、输入框字号行高
   * 2. 顶部横栏避让状态栏（--titlebar-h 变量覆写，浏览器卡/toast/预览面板同步偏移）
   * 3. 两侧侧边栏避让横栏；全局隐藏滚动条；工作台菜单分隔线隐藏
   * 4. 隐藏工作台「选择其他文件夹」「额外文件夹」「添加工作台以外的文件夹」选项（文本匹配）
   * 5. 输入框高度随内容/提示文字自适应（textarea scrollHeight）
   * CSS 每次注入都更新（状态栏高度变化后重刷）；hide/fit 只初始化一次（window 标志）。
   * 返回注入完成 Promise：加载封面在注入完成后才隐藏，避免页面白屏闪现。
   */
  private injectUiFixes(): Promise<void> {
    let p: Promise<void> = Promise.resolve();
    try {
      const sbh: number = this.statusBarHeightVp;
      const css: string =
        '._thinking-dropdown_04e00,._model-dropdown_720b5{max-width:min(92vw,340px)!important;overflow-wrap:break-word!important}' +
        '._thinking-dropdown_04e00._plan-mode-dropdown_02d8c{left:8px!important;right:auto!important;width:max-content!important;max-width:calc(100vw - 16px)!important}' +
        '._model-pill_5fa8e,._thinking-pill_02c66{font-size:0.75rem!important}' +
        '._input-box_e4684{font-size:0.9375rem!important;line-height:1.5!important}' +
        `.titlebar{padding-top:${sbh}px!important;height:var(--titlebar-h)!important;box-sizing:border-box!important;background-color:var(--bg-card)!important}` +
        `.titlebar .tb-center-title{top:${sbh}px!important}` +
        `:root{--titlebar-h:calc(44px + ${sbh}px)!important}` +
        `.jian-sidebar{padding-top:var(--titlebar-h)!important}` +
        `.sidebar{padding-top:var(--titlebar-h)!important}` +
        `*::-webkit-scrollbar{width:0!important;height:0!important;display:none!important;background:transparent!important}` +
        `*::-webkit-scrollbar-thumb{background:transparent!important}` +
        `*{scrollbar-width:none!important}` +
        `._folderHistoryDivider_737c7{display:none!important}` +
        `._workspaceHeader ._workspaceTitle{flex:1 1 auto!important;min-width:0!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important}` +
        `._workspaceHeader{padding-right:16px!important}` +
        // 归档功能已取消：隐藏官方归档按钮（移动端无 hover 不可靠），不再注入替代按钮
        `[class*="sessionArchiveBtn"]{display:none!important}` +
        // 未读红点（左上角展开按钮右上角）：用属性 + 伪元素实现，避免向 React 管理的按钮插入节点。
        // 有未读且侧栏收起时 JS 设置 data-hanako-badge=计数，CSS 伪元素渲染；空串则隐藏
        `#tbToggleLeft[data-hanako-badge]:not([data-hanako-badge=""]):not([data-hanako-badge="0"]){position:relative!important}` +
        `#tbToggleLeft[data-hanako-badge]:not([data-hanako-badge=""]):not([data-hanako-badge="0"])::after{content:attr(data-hanako-badge);position:absolute!important;top:2px!important;right:2px!important;min-width:15px!important;height:15px!important;padding:0 4px!important;border-radius:8px!important;background:#e5484d!important;color:#ffffff!important;font-size:9px!important;line-height:15px!important;text-align:center!important;box-sizing:border-box!important;z-index:30!important;pointer-events:none!important;font-family:sans-serif!important}` +
        // 会话条目未读绿灯（右侧圆点）：同样用 data-hanako-unread 属性 + 伪元素，零节点插入
        `[data-session-path][data-hanako-unread]::after{content:'';position:absolute!important;top:50%!important;right:10px!important;width:9px!important;height:9px!important;border-radius:5px!important;background:#3dbf6e!important;transform:translateY(-50%)!important;z-index:2!important;pointer-events:none!important;box-shadow:0 0 0 2px rgba(61,191,110,0.25)!important}` +
        // 注意：不再强制 body 背景（对话界面背景随主题，仅系统栏/窗口由壳层保持封面奶油色）
        ``;
      const script: string =
        `(()=>{` +
        `try{var st=document.querySelector('style[data-hanako-shell="ui-fixes"]');if(!st){st=document.createElement('style');st.setAttribute('data-hanako-shell','ui-fixes');document.head.appendChild(st);}st.textContent=${JSON.stringify(css)};}catch(e){}` +
        `if(!window.__hanakoHideInit){window.__hanakoHideInit=true;` +
        `const hideTexts=['选择其他文件夹','额外文件夹','添加工作台以外的文件夹','项目技能'];` +
        `const hide=()=>{const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);const targets=[];while(w.nextNode()){const t=w.currentNode.textContent||'';const tt=t.trim();if(tt.length>0&&hideTexts.some(function(k){return tt.indexOf(k)>-1})){let el=w.currentNode.parentElement;let btn=null;let c=el;while(c&&c!==document.body){if(c.tagName.toLowerCase()==='button'){btn=c;break;}c=c.parentElement;}if(btn){if(btn.style.display!=='none')targets.push(btn);continue;}if(el.tagName.toLowerCase()==='span'){el=el.parentElement;}if(el&&el!==document.body&&el.style.display!=='none'&&(el.offsetHeight||0)<120){targets.push(el);}}}for(const el of targets){el.style.display='none';}};` +
        `try{hide();new MutationObserver(hide).observe(document.body,{childList:true,subtree:true});}catch(e){}` +
        `const fixMeta=()=>{const ms=document.querySelectorAll('[class*="_sessionItemMeta"]');for(const m of ms){if(m.getAttribute('data-hanako-meta'))continue;m.setAttribute('data-hanako-meta','1');m.style.display='none';}};` +
        `try{fixMeta();new MutationObserver(fixMeta).observe(document.body,{childList:true,subtree:true});}catch(e){}` +
        `const fixHdr=()=>{const hs=document.querySelectorAll('[class*="_workspaceHeader"]');for(const h of hs){if(h.getAttribute('data-hanako-hdr'))continue;h.setAttribute('data-hanako-hdr','1');h.style.setProperty('padding-right','16px','important');}};` +
        `try{fixHdr();new MutationObserver(fixHdr).observe(document.body,{childList:true,subtree:true});}catch(e){}` +
        `const fixPanel=()=>{const ps=document.querySelectorAll('[class*="_sessionPanel"]');for(const p of ps){if(p.getAttribute('data-hanako-panel'))continue;p.setAttribute('data-hanako-panel','1');p.style.setProperty('padding-top',(44+${sbh}+8)+'px','important');}};` +
        `try{fixPanel();new MutationObserver(fixPanel).observe(document.body,{childList:true,subtree:true});}catch(e){}` +
        `}` +
        `if(!window.__hanakoFitInit){window.__hanakoFitInit=true;` +
        `const fitInput=()=>{const els=document.querySelectorAll('textarea');for(const el of els){if(el.__hanakoFit)continue;el.__hanakoFit=true;const up=()=>{el.style.height='auto';const h=el.scrollHeight;el.style.height=(h>0?h+2:44)+'px';};el.addEventListener('input',up);el.addEventListener('focus',up);up();}};` +
        `try{fitInput();new MutationObserver(fitInput).observe(document.body,{childList:true,subtree:true});}catch(e){}` +
        `}` +
        `if(!window.__hanakoBgInit){window.__hanakoBgInit=true;` +
        // 背景统一：亮主题强制 body 背景 = hanako 标志背景；深色主题（--bg 亮度 <120）豁免
        `var updBg=function(){var cs=getComputedStyle(document.documentElement);var v=(cs.getPropertyValue('--bg')||'').trim();var m=null;` +
        `if(v.indexOf('rgb')===0){m=v.match(/rgba?\\(\\s*(\\d+)[,\\s]+(\\d+)[,\\s]+(\\d+)/);}` +
        `var lum=255;if(m){lum=(parseInt(m[1])*299+parseInt(m[2])*587+parseInt(m[3])*114)/1000;}` +
        `var root=document.documentElement;if(lum<120){root.classList.add('hanako-dark');}else{root.classList.remove('hanako-dark');}};` +
        `updBg();setInterval(updBg,2500);` +
        `}` +
        `if(!window.__hanakoUnreadInit){window.__hanakoUnreadInit=true;` +
        // 未读红点/绿灯以页面自身的未读状态为准（data-unread-output="true"）。
        // 只读写属性（data-hanako-badge / data-hanako-unread），CSS 伪元素渲染，
        // 不向 React 管理的 DOM 插入节点，避免干扰页面渲染与交互。
        `var sidebarOpen=function(){var s=document.getElementById('sidebar');return !!s&&s.className.indexOf('collapsed')===-1;};` +
        `var refreshUnread=function(){var n=0;` +
        `var items=document.querySelectorAll('[data-session-path]');` +
        `for(var i=0;i<items.length;i++){var it=items[i];` +
        `if(it.getAttribute('data-unread-output')==='true'){n++;` +
        `if(!it.hasAttribute('data-hanako-unread')){it.setAttribute('data-hanako-unread','');}}` +
        `else if(it.hasAttribute('data-hanako-unread')){it.removeAttribute('data-hanako-unread');}}` +
        `var btn=document.getElementById('tbToggleLeft')||document.querySelector('.tb-toggle-left');` +
        `if(btn){var show=n>0&&!sidebarOpen();` +
        `btn.setAttribute('data-hanako-badge',show?(n>99?'99+':String(n)):'');}};` +
        `window.__hanakoNudgeUnread=function(){try{refreshUnread();}catch(e){}};` +
        `try{refreshUnread();setInterval(refreshUnread,2000);}catch(e){}` +
        `}` +
        `if(!window.__hanakoDropHandler){window.__hanakoDropHandler=true;` +
        `window.addEventListener('drop',function(e){try{var dt=e.dataTransfer;if(!dt){return;}` +
        `var txt='';try{txt=dt.getData('text/plain')||'';}catch(x){}` +
        `if(txt.length>0){e.preventDefault();var el=document.querySelector('[contenteditable="true"]');` +
        `if(el){el.focus();var ok=false;try{ok=document.execCommand('insertText',false,txt);}catch(xx){ok=false;}` +
        `console.log('[hanako-drop] text len='+txt.length+' exec='+ok);}else{console.log('[hanako-drop] text no editor');}return;}` +
        `if(!dt.files||!dt.files.length){return;}e.preventDefault();` +
        `var file=dt.files[0];console.log('[hanako-drop] handle '+file.name);` +
        `file.arrayBuffer().then(function(ab){` +
        `var arr=new Uint8Array(ab);` +
        `var input=document.querySelector('input[type="file"][class*="browser-file-input"]')` +
        `||document.querySelector('input[type="file"][accept*="image"]')` +
        `||document.querySelector('input[type="file"]');` +
        `if(!input){console.log('[hanako-drop] no file input');return;}` +
        `var f2=new File([arr],file.name,{type:file.type});var dt2=new DataTransfer();dt2.items.add(f2);` +
        `input.files=dt2.files;input.dispatchEvent(new Event('change',{bubbles:true}));` +
        `console.log('[hanako-drop] injected ok');` +
        `}).catch(function(err){console.log('[hanako-drop] read fail '+String(err));});` +
        `}catch(x){}},true);` +
        `}` +
        `if(!window.__hanakoImageInit){window.__hanakoImageInit=true;` +
        `document.addEventListener('click',function(e){try{var el=e.target;var a=el&&el.closest?el.closest('a[download]'):null;var url='';` +
        `if(a&&a.href){url=a.href;}else{var dl=el&&el.closest?el.closest('[class*="download"],[class*="Download"],[class*="save"],[class*="Save"]'):null;` +
        `if(dl){var card=dl.closest('[class*="message"],[class*="card"],[class*="image"],[class*="bubble"]');` +
        `var img=card?card.querySelector('img'):null;if(img&&img.src){url=img.src;}}}` +
        `var fname=a&&a.download?a.download:new URL(url).pathname.split('/').pop().split('?')[0];if(!fname)fname='hanako_download_'+Date.now();` +
        `if(!url)return;var p=url.indexOf('blob:')===0?fetch(url):fetch(url,{credentials:'include'});` +
        `p.then(function(r){return r.blob();}).then(function(b){return new Promise(function(res){var fr=new FileReader();fr.onload=function(){res(fr.result);};fr.readAsDataURL(b);});})` +
        `.then(function(d){var c=d.indexOf(',');var b64=c>=0?d.slice(c+1):d;window.__hanakoImageB64=b64;` +
        `window.__hanakoImageName=fname;console.log('[hanako-img] ready save '+fname);}).catch(function(){});` +
        `}catch(err){}},true);` +
        `var lp=null;` +
        `document.addEventListener('touchstart',function(e){try{var el=e.target;var img=el&&el.closest?el.closest('img'):null;` +
        `if(img&&img.src){lp={src:img.src,t:Date.now()};}}catch(err){}},true);` +
        `document.addEventListener('touchend',function(){if(lp&&Date.now()-lp.t>550){` +
        `var src=lp.src;var p=src.indexOf('blob:')===0?fetch(src):fetch(src,{credentials:'include'});` +
        `p.then(function(r){return r.blob();}).then(function(b){return new Promise(function(res){var fr=new FileReader();fr.onload=function(){res(fr.result);};fr.readAsDataURL(b);});})` +
        `.then(function(d){var c=d.indexOf(',');var b64=c>=0?d.slice(c+1):d;window.__hanakoImageB64=b64;` +
        `window.__hanakoImageName='hanako_image_'+Date.now()+'.png';console.log('[hanako-img] ready menu');}).catch(function(){});` +
        `}lp=null;},true);` +
        `}` +
        `if(!window.__hanakoPasteHandler){window.__hanakoPasteHandler=true;` +
        `document.addEventListener('paste',function(e){try{` +
        `console.log('[hanako-paste] event, copyLen='+(window.__hanakoImageCopyB64||'').length);` +
        `var copy=window.__hanakoImageCopyB64;if(!copy){console.log('[hanako-paste] no copy, pass');return;}` +
        `var ext=((window.__hanakoImageCopyName||'')+'').split('.').pop()||'png';` +
        `var mime=ext==='jpg'||ext==='jpeg'?'jpeg':ext==='gif'?'gif':ext==='webp'?'webp':'png';` +
        `var html='<img src=\"data:image/'+mime+';base64,'+copy+'\" />';` +
        `e.preventDefault();` +
        `var ed=document.querySelector('[contenteditable=\"true\"]');` +
        `if(ed){ed.focus();document.execCommand('insertHTML',false,html);}` +
        `window.__hanakoImageCopyB64='';console.log('[hanako-paste] image inserted');` +
        `}catch(err){console.log('[hanako-paste] err '+String(err));}});}` +
        `})()`;
      p = this.controller.runJavaScript(script).then(() => {
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'injectUiFixes failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'injectUiFixes error: %{public}s', JSON.stringify(e));
    }
    return p;
  }

  /** 打开居中的设置菜单 */
  private openSettingsPanel(): void {
    this.editUrl = this.currentUrl;
    this.showSettings = true;
  }

  /** 关闭设置菜单（白条留在原位；悬浮球恢复静置计时，稍后自动变形为条） */
  private closeSettingsPanel(): void {
    this.showSettings = false;
    this.restartIdleTimer();
  }

  /** 系统分享：从 Preferences 读取分享内容注入页面（文本填入输入框 / 文件走 base64 注入通道） */
  private shareBusy: boolean = false;
  private lastShareSeq: number = 0;

  private checkShare(): void {
    if (!this.isChatReady || this.shareBusy) {
      return;
    }
    this.shareBusy = true;
    readShare(this.getUIContext().getHostContext() as common.UIAbilityContext).then((data: SharePayload) => {
      if (data.seq === 0 || data.seq === this.lastShareSeq) {
        this.shareBusy = false;
        return;
      }
      this.lastShareSeq = data.seq;
      // 同步清空（防重复）+ 注入，失败写回重试
      clearShareSync(this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (data.text.length > 0) {
        hilog.info(DOMAIN, TAG, 'share text inject seq=%{public}d', data.seq);
        this.injectTextToEditor(data.text);
      } else if (data.files.length > 0) {
        hilog.info(DOMAIN, TAG, 'share files inject seq=%{public}d n=%{public}d', data.seq, data.files.length);
        this.injectFilesToPage(data.files);
      }
      this.shareBusy = false;
    }).catch((err: BusinessError) => {
      this.shareBusy = false;
      hilog.warn(DOMAIN, TAG, 'readShare error: %{public}s', JSON.stringify(err));
    });
  }

  /** 注入文本到页面输入框（输入框未就绪时挂 window 定时重试） */
  private injectTextToEditor(text: string): void {
    try {
      const script: string =
        `(()=>{const doInject=()=>{const el=document.querySelector('[contenteditable="true"]');` +
        `if(!el)return false;el.focus();document.execCommand('insertText',false,${JSON.stringify(text)});return true;};` +
        `if(doInject())return;window.__hanakoPendingText=${JSON.stringify(text)};` +
        `if(!window.__hanakoPendingTextTimer){window.__hanakoPendingTextTimer=setInterval(()=>{` +
        `if(window.__hanakoPendingText&&doInject()){window.__hanakoPendingText=null;` +
        `clearInterval(window.__hanakoPendingTextTimer);window.__hanakoPendingTextTimer=null;}},1000);}})()`;
      this.controller.runJavaScript(script).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'inject share text failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'injectTextToEditor error: %{public}s', JSON.stringify(e));
    }
  }

  /** 多文件注入页面附件输入框（逐文件单独注入避免超大脚本 OOM；输入框未就绪挂 window 队列定时重试） */
  private injectFilesToPage(files: ShareFileItem[]): void {
    try {
      for (let i = 0; i < files.length; i++) {
        const f: ShareFileItem = files[i];
        const itemObj: string =
          `{b64:${JSON.stringify(f.b64)},name:${JSON.stringify(f.name)},type:${JSON.stringify(f.type)}}`;
        const script: string =
          `(()=>{window.__hanakoPendingFiles=window.__hanakoPendingFiles||[];` +
          `window.__hanakoPendingFiles.push(${itemObj});` +
          `var findInput=function(){var i=document.querySelector('input[type="file"][class*="browser-file-input"]');` +
          `if(i)return i;i=document.querySelector('input[type="file"][accept*="image"]');` +
          `if(i)return i;return document.querySelector('input[type="file"]');};` +
          `var tryInject=function(){var q=window.__hanakoPendingFiles;if(!q||!q.length)return false;` +
          `var input=findInput();if(!input)return false;` +
          `var dt=new DataTransfer();for(var k=0;k<q.length;k++){` +
          `var bin=atob(q[k].b64);var arr=new Uint8Array(bin.length);` +
          `for(var j=0;j<bin.length;j++){arr[j]=bin.charCodeAt(j);}` +
          `dt.items.add(new File([arr],q[k].name,{type:q[k].type}));}` +
          `input.files=dt.files;input.dispatchEvent(new Event('change',{bubbles:true}));` +
          `window.__hanakoPendingFiles=[];return true;};` +
          `if(tryInject())return;` +
          `if(!window.__hanakoPendingTimer){window.__hanakoPendingTimer=setInterval(function(){` +
          `if(window.__hanakoPendingFiles&&window.__hanakoPendingFiles.length&&tryInject()){` +
          `clearInterval(window.__hanakoPendingTimer);window.__hanakoPendingTimer=null;}},1000);}})()`;
        this.controller.runJavaScript(script).catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'inject file %{public}d failed: %{public}s', i, JSON.stringify(err));
        });
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'injectFilesToPage error: %{public}s', JSON.stringify(e));
    }
  }

  /** 读取页面注入的图片数据（base64）并按动作处理 */
  private handleImageData(isMenu: boolean): void {
    try {
      this.controller.runJavaScript('window.__hanakoImageB64||""').then((b64: string) => {
        this.controller.runJavaScript('window.__hanakoImageName||""').then((name: string) => {
          this.controller.runJavaScript('window.__hanakoImageB64=""');
          if (b64.length === 0) {
            return;
          }
          const fname: string = name.length > 0 ? name : `hanako_image_${Date.now()}.png`;
          if (!isMenu) {
            saveBase64ToLibrary(this.getUIContext().getHostContext() as common.UIAbilityContext, b64, fname);
          } else {
            this.showImageMenu(b64, fname);
          }
        });
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'handleImageData error: %{public}s', JSON.stringify(e));
    }
  }

  /** 长按图片弹出操作菜单（复制/分享，自定义样式） */
  private showImageMenu(b64: string, name: string): void {
    this.menuB64 = b64;
    this.menuName = name;
    this.showImgMenu = true;
  }

  private closeImageMenu(): void {
    this.showImgMenu = false;
  }

  /** skill 推荐：getPromptAction().showToast（promptAction.showToast 已废弃） */
  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 启动加载超时计时：服务器不可达（TCP 黑洞）等场景 ArkWeb 可能长时间无任何回调，
   * 超时后强制进入错误页，引导用户重试或修改服务器地址，避免永远停留在加载页。
   */
  private startLoadTimer(): void {
    this.stopLoadTimer();
    this.loadTimer = setTimeout(() => {
      this.loadTimer = -1;
      // 已结束加载或已进入错误页：不重复处理
      if (!this.isLoading || this.hasError) {
        return;
      }
      hilog.warn(DOMAIN, TAG, 'load timeout after %{public}d ms, force error page', LOAD_TIMEOUT_MS);
      this.stopSplashRotate();
      if (this.currentUrl.length === 0) {
        // 未配置地址：退出加载态，让首次引导层接管
        this.isLoading = false;
        return;
      }
      // 中止无响应的加载，避免后台空转
      try {
        this.controller.stop();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'stop load failed: %{public}s', JSON.stringify(e));
      }
      this.isLoading = false;
      this.hasError = true;
      this.isChatReady = false;
      this.errHint = '连接超时，请确认服务器已启动且手机与电脑在同一网络，稍后重试';
    }, LOAD_TIMEOUT_MS);
  }

  private stopLoadTimer(): void {
    if (this.loadTimer !== -1) {
      clearTimeout(this.loadTimer);
      this.loadTimer = -1;
    }
  }

  /** 注入卡片 fetch hook（幂等：脚本自身带初始化标志，重复执行无害）。
   * 注入时机三保险：onPageBegin（最早尝试）、onPageEnd（页面就绪后第一时间）、
   * watchLoop（2.5s 周期兜底）。外置同源脚本（assets/hanako-card-hook.js）由
   * onInterceptRequest 拦截返回，随页面加载自动执行，早于页面 bundle。 */
  private ensureCardHook(force: boolean = false): void {
    if (!force && !this.isChatReady) {
      return;
    }
    try {
      this.controller.runJavaScript(CARD_HOOK_SCRIPT).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'ensureCardHook failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ensureCardHook error: %{public}s', JSON.stringify(e));
    }
  }

  /** 预取 mobile 页面 HTML，把卡片 hook 脚本注入 <head> 后缓存，供 onInterceptRequest 使用。
   * 文档级注入的时序保证：页面 HTML 到达 ArkWeb 前脚本已就位，任何页面 JS（含 WebSocket
   * 创建）都晚于 hook。失败静默：onPageEnd / watchLoop 的 runJavaScript 注入仍会兜底 */
  /** 收集注入脚本分片输出的卡片数据：[hanako-card-code|vars]{id}|{index}|{total}|{chunk} */
  private collectCardChunks(msg: string, isVars: boolean): void {
    try {
      const prefix: string = isVars ? '[hanako-card-vars]' : '[hanako-card-code]';
      const body: string = msg.substring(prefix.length);
      const sep: number = body.indexOf('|');
      if (sep <= 0) return;
      const id: string = body.substring(0, sep);
      const rest: string = body.substring(sep + 1);
      const parts: string[] = rest.split('|');
      if (parts.length < 3) return;
      const idx: number = parseInt(parts[0], 10);
      const total: number = parseInt(parts[1], 10);
      if (isNaN(idx) || isNaN(total) || total <= 0 || idx < 0 || idx >= total) return;
      // 内容可能含 |，从第三段起全部还原
      const chunk: string = parts.slice(2).join('|');
      const chunksMap: Map<string, string[]> = isVars ? this.cardVarsChunks : this.cardChunks;
      const totalsMap: Map<string, number> = isVars ? this.cardVarsTotals : this.cardTotals;
      let arr: string[] | undefined = chunksMap.get(id);
      if (arr === undefined) {
        arr = new Array<string>(total);
        chunksMap.set(id, arr);
      }
      arr[idx] = chunk;
      let complete: boolean = true;
      for (let i = 0; i < total; i++) {
        if (arr[i] === undefined) {
          complete = false;
          break;
        }
      }
      if (complete) {
        const full: string = arr.join('');
        if (isVars) {
          this.cardVarsStore.set(id, full);
        } else {
          this.cardCodeStore.set(id, full);
        }
        chunksMap.delete(id);
        totalsMap.delete(id);
        hilog.info(DOMAIN, TAG, 'card %{public}s complete id=%{public}s len=%{public}d', isVars ? 'vars' : 'code', id, full.length);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'collectCardChunks error: %{public}s', JSON.stringify(e));
    }
  }

  /** 构建卡片 HTML（模仿 server/cards/card-document.ts）：http iframe 无 CSP 继承，内联脚本才能执行 */
  private buildCardHtml(cardId: string): string {
    const code: string = this.cardCodeStore.get(cardId) || '';
    if (code.length === 0) {
      return '';
    }
    const varsCss: string = this.cardVarsStore.get(cardId) || '';
    // 防注入：剥掉尖括号，杜绝 </style> 逃逸（与服务端 sanitizeVarsCss 一致）
    const safeVars: string = varsCss.replace(/[<>]/g, '');
    const rsc: string = "(function(){var NS='hana.card-resize';var last=0;function report(){var h=document.documentElement.scrollHeight;if(h!==last){last=h;window.parent.postMessage({type:NS,height:h},'*');}}if(document.readyState==='complete')report();else window.addEventListener('load',report);new ResizeObserver(function(){report();}).observe(document.body);window.addEventListener('message',function(e){if(e.data==='hana.card-ping'){last=0;report();}});})();";
    return '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>:root{' + safeVars + '--font-serif:\'EB Garamond\',\'Noto Serif SC\',serif;--font-ui:system-ui,sans-serif;--font-mono:\'JetBrains Mono\',monospace}*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}html{background:var(--bg-card,#FBF7EE);color:var(--text,#2A2622)}body{padding:12px 16px;font-family:var(--font-serif);font-size:14px;line-height:1.65}h1{font-size:1.35rem;font-weight:500;line-height:1.25;margin:0 0 0.6em}h2{font-size:1.1rem;font-weight:500;line-height:1.3;margin:0.8em 0 0.4em;border-left:2px solid var(--accent,#537D96);padding-left:8px}h3{font-size:0.95rem;font-weight:500;line-height:1.35;margin:0.6em 0 0.3em}p{margin:0.4em 0}strong{font-weight:500;color:var(--accent,#537D96)}a{color:var(--accent,#537D96);text-decoration:none}table{width:100%;border-collapse:collapse;font-size:0.85rem;margin:0.6em 0}th{text-align:left;font-weight:500;color:var(--text-light,#4A433C);padding:6px 8px;border-bottom:1px solid var(--border,#D8CFBE)}td{padding:5px 8px;border-bottom:0.5px solid rgba(0,0,0,0.06);color:var(--text,#2A2622)}pre{background:var(--bg,#F5EFE4);border:0.5px solid var(--border,#D8CFBE);border-radius:4px;padding:8px 12px;overflow-x:auto}code{font-family:var(--font-mono);font-size:0.82rem}blockquote{border-left:2px solid var(--accent,#537D96);padding:4px 0 4px 12px;color:var(--text-muted,#6B6158);font-style:italic;margin:0.5em 0}svg{display:block;width:100%;max-width:100%}.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap}</style></head><body>' + code + '<script>' + rsc + '</script></body></html>';
  }

  private prefetchCardHtml(): void {
    if (this.currentUrl.length === 0 || this.cardPrefetching) {
      return;
    }
    const m = /^(https?:\/\/[^/]+)/i.exec(this.currentUrl);
    if (m === null || m.length < 2) {
      return;
    }
    const target: string = m[1] + '/mobile/';
    this.cardPrefetching = true;
    const req = http.createHttp();
    const hdr: Record<string, string> = {
      'Accept': 'text/html,application/xhtml+xml',
      'Accept-Encoding': 'identity'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: 5000,
      readTimeout: 5000,
      header: hdr
    };
    req.request(target, options).then((resp: http.HttpResponse) => {
      if (resp.responseCode === 200 && typeof resp.result === 'string') {
        const html: string = resp.result;
        if (html.length > 0) {
          // CSP script-src 'self' 禁止内联脚本，改为外置同源脚本引用（由 onInterceptRequest 拦截返回）
          this.cardHtmlCache = html.replace(/<\/head>/i,
            () => '<script src="./assets/hanako-card-hook.js"></script></head>');
          hilog.info(DOMAIN, TAG, 'card html prefetched len=%{public}d', this.cardHtmlCache.length);
        }
      }
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'card html prefetch failed: %{public}s', JSON.stringify(err));
    }).finally(() => {
      this.cardPrefetching = false;
      req.destroy();
    });
  }

  private reloadPage(): void {
    this.stopLoadTimer();
    this.hasError = false;
    this.isLoading = true;
    this.isChatReady = false;
    this.errHint = '';
    this.startSplashRotate();
    try {
      this.prefetchCardHtml();
      this.controller.loadUrl(this.currentUrl);
      this.startLoadTimer();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'reload failed: %{public}s', JSON.stringify(e));
      this.isLoading = false;
    }
  }

  private saveSettings(): void {
    let u: string = this.editUrl.trim();
    if (u.length === 0) {
      this.toast('请输入服务器地址');
      return;
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://' + u;
    }
    // 地址未带 /mobile/ 路径时自动补全（服务端移动端页面路径），避免误加载根路径
    // 撞上 403 missing_credential 裸 JSON 错误
    try {
      const parsed: url.URL = new url.URL(u);
      const p: string = parsed.pathname;
      if (p === '' || p === '/') {
        u = u.replace(/\/+$/, '') + '/mobile/';
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse url for mobile path failed: %{public}s', JSON.stringify(e));
    }
    // 地址 origin 变化（且已有地址）：清 cookie，提示重新验证，自动回登录页
    if (this.currentUrl.length > 0 && !this.isSameOrigin(this.currentUrl, u)) {
      this.clearCookies();
      this.toast('检测到地址改变，需要重新验证');
    }
    this.currentUrl = u;
    this.editUrl = u;
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      const ctx = hostCtx as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: PREFS_NAME });
      store.putSync(KEY_SERVER_URL, u);
      store.flush().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'flush prefs failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save prefs failed: %{public}s', JSON.stringify(e));
    }
    this.closeSettingsPanel();
    // 地址可能变化：断开旧通知连接，新页面加载成功后重建
    NotificationClient.disconnect();
    this.reloadPage();
  }

  /** 扫码连接：扫描电脑端 Hanako 的连接二维码，识别出服务器地址后自动保存并连接
   *  若新地址与原地址不同（换了 PC），清除会话 cookie 并提示重新验证 */
  private startScan(): void {
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      scanBarcode.startScanForResult(hostCtx).then((data: scanBarcode.ScanResult) => {
        const v: string = data.originalValue ?? '';
        hilog.info(DOMAIN, TAG, 'scan result: %{public}s', v);
        let target: string = '';
        if (v.startsWith('http://') || v.startsWith('https://')) {
          target = v;
        } else if (v.startsWith('hanako://')) {
          // 预留 scheme：hanako://connect?url=<encoded server url>
          try {
            const u: url.URL = new url.URL(v);
            const params: url.URLParams = new url.URLParams(u.search);
            const t: string | null = params.get('url');
            if (t !== null) {
              target = t;
            }
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'parse hanako scheme failed: %{public}s', JSON.stringify(e));
          }
        }
        if (target.length === 0) {
          hilog.warn(DOMAIN, TAG, 'unrecognized scan content');
          return;
        }
        // 地址 origin 变化（且已有地址）：清 cookie，提示重新验证，自动回登录页
        if (this.currentUrl.length > 0 && !this.isSameOrigin(this.currentUrl, target)) {
          this.clearCookies();
          this.toast('检测到地址改变，需要重新验证');
        }
        this.editUrl = target;
        this.saveSettings();
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'scan failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'startScan error: %{public}s', JSON.stringify(e));
    }
  }

  /** 比较两个 URL 的 origin（协议+主机+端口）是否相同 */
  private isSameOrigin(a: string, b: string): boolean {
    const originOf = (u: string): string => {
      const m = /^(https?:\/\/[^\/]+)/i.exec(u);
      return m !== null && m.length > 1 ? m[1].toLowerCase() : u;
    };
    return originOf(a) === originOf(b);
  }

  /** 清除全部 Cookie（换服务器/重新验证时调用） */
  private clearCookies(): void {
    try {
      webview.WebCookieManager.clearAllCookiesSync();
      hilog.info(DOMAIN, TAG, 'cookies cleared');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'clearCookies failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 检测登录状态：有会话 cookie 视为已登录；未登录时隐藏白条 */
  private checkLoggedIn(): void {
    try {
      const cookie: string = webview.WebCookieManager.getCookie(this.currentUrl);
      const loggedIn: boolean = cookie.length > 0;
      if (loggedIn !== this.isChatReady) {
        hilog.info(DOMAIN, TAG, 'login state changed: loggedIn=%{public}s', String(loggedIn));
        this.isChatReady = loggedIn;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'checkLoggedIn failed: %{public}s', JSON.stringify(e));
    }
  }

  onBackPress(): boolean {
    if (this.showImgMenu) {
      this.closeImageMenu();
      return true;
    }
    if (this.showSettings) {
      this.closeSettingsPanel();
      return true;
    }
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        // 兜底：错误页（HTTP 403 JSON 等）按返回可能退到 about:blank / 空页，
        // 检测到后自动恢复加载真实地址，避免白屏卡死
        setTimeout(() => {
          try {
            const u: string = this.controller.getUrl();
            if (u === 'about:blank' || u.length === 0) {
              hilog.warn(DOMAIN, TAG, 'backward landed on blank page, reloading');
              this.reloadPage();
            }
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'check url after backward failed: %{public}s', JSON.stringify(e));
          }
        }, 400);
        return true;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'backward failed: %{public}s', JSON.stringify(e));
    }
    return false;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // Web 内容层：全屏渲染，顶部横栏由注入 CSS 自行避让状态栏（背景延伸，视觉一体）
      Web({ src: this.currentUrl.length > 0 ? this.currentUrl : 'about:blank', controller: this.controller })
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .cacheMode(CacheMode.Default)
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          try {
            const u: string = event.request.getRequestUrl();
            // 外置卡片 hook 脚本（同源，满足 CSP script-src 'self'）
            if (u.indexOf('/assets/hanako-card-hook.js') > -1) {
              const r0 = new WebResourceResponse();
              r0.setResponseData(CARD_HOOK_SCRIPT);
              r0.setResponseEncoding('utf-8');
              r0.setResponseMimeType('application/javascript');
              return r0;
            }
            // 卡片 GET：iframe 子 frame 导航（不能要求 isMainFrame）。
            // 注入脚本已伪造 PUT 成功并把 code 分片送过来，这里本地渲染官方卡片文档
            if (u.indexOf('/api/cards/') > -1) {
              const mc = /\/api\/cards\/([A-Za-z0-9_-]+)/.exec(u);
              if (mc !== null && mc.length > 1) {
                const cid: string = mc[1];
                const html: string = this.buildCardHtml(cid);
                if (html.length > 0) {
                  const r1 = new WebResourceResponse();
                  r1.setResponseData(html);
                  r1.setResponseEncoding('utf-8');
                  r1.setResponseMimeType('text/html');
                  hilog.info(DOMAIN, TAG, 'card html served locally id=%{public}s', cid);
                  return r1;
                }
              }
            }
            if (this.cardHtmlCache.length === 0 || !event.request.isMainFrame() || u.indexOf('/mobile/') === -1) {
              return null;
            }
            const resp = new WebResourceResponse();
            resp.setResponseData(this.cardHtmlCache);
            resp.setResponseEncoding('utf-8');
            resp.setResponseMimeType('text/html');
            hilog.info(DOMAIN, TAG, 'card html injected via intercept url=%{public}s', u.slice(0, 60));
            return resp;
          } catch (e) {
            return null;
          }
        })
        .onPageBegin(() => {
          hilog.info(DOMAIN, TAG, 'onPageBegin url=%{public}s', this.currentUrl);
          // 尽早注入卡片 hook（页面刚加载就尝试，赶在 bundle 执行/WS 建立之前；
          // 失败无害，onPageEnd 与 watchLoop 会兜底）
          this.ensureCardHook(true);
          // 仅在非错误态下重启超时计时。
          // 注意：不在此清除 hasError——连接失败后 ArkWeb 可能触发内部导航
          // （内置错误页/自动重试），若清掉错误态会把用户留在白屏且无法操作。
          if (!this.hasError) {
            this.startLoadTimer();
          }
        })
        .onConsole((event: OnConsoleEvent) => {
          const msg: string = event.message.getMessage();
          if (msg.startsWith('[hanako-card-code]')) {
            this.collectCardChunks(msg, false);
          }
          if (msg.startsWith('[hanako-card-vars]')) {
            this.collectCardChunks(msg, true);
          }
          if (msg.startsWith('[hanako-card]')) {
            hilog.info(DOMAIN, TAG, 'card diag: %{public}s', msg);
          }
          if (msg.startsWith('[hanako-img]')) {
            hilog.info(DOMAIN, TAG, 'img event: %{public}s', msg);
            const isMenu: boolean = msg.indexOf('menu') > -1;
            this.handleImageData(isMenu);
          } else if (msg.startsWith('[hanako-drop]')) {
            hilog.info(DOMAIN, TAG, 'web drop probe: %{public}s', msg);
          } else if (msg.startsWith('[hanako')) {
            hilog.info(DOMAIN, TAG, 'hanako: %{public}s', msg);
          } else {
            const lvl: string = String(event.message.getMessageLevel());
            const low: string = msg.toLowerCase();
            if (lvl.indexOf('Error') > -1 || lvl.indexOf('Warn') > -1 ||
              low.indexOf('fail') > -1 || low.indexOf('error') > -1 ||
              low.indexOf('文件') > -1 || low.indexOf('附件') > -1 ||
              low.indexOf('upload') > -1 || low.indexOf('attachment') > -1) {
              hilog.info(DOMAIN, TAG, 'web console: %{public}s', msg.slice(0, 300));
            }
          }
          return false;
        })
        .onPageEnd(() => {
          this.stopLoadTimer();
          this.stopSplashRotate();
          // 错误态锁定期间的内部导航结束（如 Chromium 内置错误页）不覆盖错误页
          if (this.hasError) {
            return;
          }
          this.isChatReady = true;
          // 白条出现后启动静置计时：默认球态静置 3 秒自动变形为细条
          this.restartIdleTimer();
          // 先注入移动端修正 CSS 再隐藏加载封面，避免页面以默认白底渲染造成
          // 「封面后白屏」闪烁；2 秒超时兜底，防止注入 Promise 挂起卡住封面
          const injectP: Promise<void> = this.injectUiFixes();
          this.ensureCardHook();
          const timeoutP: Promise<void> = new Promise<void>((resolve: () => void) => {
            setTimeout(() => {
              resolve();
            }, 2000);
          });
          Promise.race([injectP, timeoutP]).then(() => {
            this.isLoading = false;
          }).catch(() => {
            this.isLoading = false;
          });
          this.checkLoggedIn();
          // 服务器可达：建立通知 WS（后台推送提醒）
          if (this.currentUrl.length > 0) {
            NotificationClient.connect(this.currentUrl).then((ok: boolean) => {
              hilog.info(DOMAIN, TAG, 'notify ws connect: %{public}s', String(ok));
            });
            // 上报华为推送 Token（服务端 huawei-push 插件经系统通道下发，后台冻结也能收到）
            PushBridge.register(this.currentUrl).catch((err: BusinessError) => {
              hilog.warn(DOMAIN, TAG, 'push register failed: %{public}s', JSON.stringify(err));
            });
          }
          this.checkShare();
        })
        .onErrorReceive((event) => {
          let code: number = -1;
          try {
            code = event.error?.getErrorCode() ?? -1;
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'read error code failed: %{public}s', JSON.stringify(e));
          }
          // 子资源错误（页面内图片/接口失败）不触发整页错误页，只记日志
          let mainFrame: boolean = true;
          try {
            mainFrame = event.request.isMainFrame();
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'read isMainFrame failed: %{public}s', JSON.stringify(e));
          }
          hilog.error(DOMAIN, TAG, 'onErrorReceive code=%{public}d main=%{public}s', code, String(mainFrame));
          if (!mainFrame) {
            return;
          }
          // ERR_ABORTED：导航被新导航/主动中止打断，保持加载态，
          // 由随后到来的 onPageBegin 或超时兜底接管（避免提前关掉加载页导致白屏）
          if (code === ERR_ABORTED) {
            return;
          }
          this.stopLoadTimer();
          this.stopSplashRotate();
          this.isLoading = false;
          this.hasError = true;
          this.isChatReady = false;
          if (code === ERR_TIMED_OUT || code === ERR_CONNECTION_TIMED_OUT) {
            this.errHint = '连接超时，请确认服务器地址无误且手机与电脑在同一网络，稍后重试';
          } else {
            this.errHint = '';
          }
        })
        .onHttpErrorReceive((event) => {
          const code: number = event.response?.getResponseCode() ?? 0;
          let mainFrame: boolean = true;
          try {
            mainFrame = event.request.isMainFrame();
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'read http isMainFrame failed: %{public}s', JSON.stringify(e));
          }
          hilog.warn(DOMAIN, TAG, 'onHttpErrorReceive code=%{public}d main=%{public}s', code, String(mainFrame));
          // 仅主文档 HTTP 错误进入错误页。主文档 401/403/404 等（地址配置错误、
          // 登录失效访问受保护路径等）页面自身无法渲染登录流程，必须由壳接管，
          // 否则会裸显示服务端 JSON 且返回键退到 about:blank 白屏卡死；
          // 页面内子资源（接口）HTTP 错误不覆盖整页（页面自会跳转登录等处理）
          if (mainFrame && code >= 400) {
            this.stopLoadTimer();
            this.stopSplashRotate();
            this.isLoading = false;
            this.hasError = true;
            this.isChatReady = false;
            if (code === 401 || code === 403) {
              this.errHint = '服务器拒绝了访问（登录已失效或地址有误），\n请检查服务器地址，必要时重新验证';
            } else if (code === 404) {
              this.errHint = '找不到该页面（404），请确认地址以 /mobile/ 结尾';
            } else {
              this.errHint = '';
            }
          }
        })
        .onSslErrorEventReceive((event) => {
          hilog.warn(DOMAIN, TAG, 'onSslErrorEventReceive ssl check failed');
          // 官方建议：SSL 校验失败时取消请求，避免中间人风险继续加载
          try {
            event.handler.handleCancel();
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'ssl handleCancel failed: %{public}s', JSON.stringify(e));
          }
          this.stopLoadTimer();
          this.stopSplashRotate();
          this.isLoading = false;
          this.hasError = true;
          this.isChatReady = false;
          this.errHint = 'SSL 证书校验失败，请确认服务器地址（https 需使用受信任证书）';
        })

      // 首次引导层：未设置服务器地址时显示
      if (this.currentUrl.length === 0 && !this.hasError) {
        Column() {
          Image($r('app.media.startIcon'))
            .width(this.iconSizeVp)
            .height(this.iconSizeVp)
          Text('欢迎使用 Hanako')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#3a3226')
            .margin({ top: 22 })
          Text('请先设置你的 Hanako 服务器地址')
            .fontSize(14)
            .fontColor('#8a7a5c')
            .margin({ top: 10, bottom: 28 })
          Button('设置服务器地址')
            .width(200)
            .height(46)
            .fontSize(16)
            .fontColor('#ffffff')
            .backgroundColor('#c9a06c')
            .borderRadius(12)
            .onClick(() => {
              this.openSettingsPanel();
            })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .backgroundColor(this.bgColor)
      }

      // 加载封面（与系统启动窗口同一图标同一背景同一尺寸，视觉无缝衔接为一个封面；
      // 页面 onPageEnd 后自然消失。图标下方轮播加载标语，与电脑端启动画面同款文案）
      if (this.isLoading && !this.hasError) {
        Stack() {
          // 背景层
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.bgColor)
          // 图标 + 标语：屏幕正中心（图标尺寸按密度匹配启动窗口 256px 图标）
          Column({ space: 18 }) {
            Image($r('app.media.startIcon'))
              .width(this.iconSizeVp)
              .height(this.iconSizeVp)
            Text(this.splashText)
              .fontSize(14)
              .fontColor('#8E9196')
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 32, right: 32 })
          }
          .position({ x: '50%', y: '50%' })
          .markAnchor({ x: '50%', y: '50%' })
        }
        .width('100%')
        .height('100%')
      }

      // 连接失败兜底页（固定不透明 hanako 标志背景，确保完全覆盖对话页）
      if (this.hasError) {
        Column() {
          Text('🌙')
            .fontSize(64)
          Text('无法连接到 Hanako')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#3a3226')
            .margin({ top: 22 })
          Text(this.errHint.length > 0 ? this.errHint :
            '请确认电脑已开机、Hanako 正在运行，\n且手机与电脑在同一局域网内')
            .fontSize(15)
            .fontColor('#8a7a5c')
            .textAlign(TextAlign.Center)
            .lineHeight(22)
            .margin({ top: 14, bottom: 30 })
          Button('重新连接')
            .width(200)
            .height(46)
            .fontSize(16)
            .fontColor('#ffffff')
            .backgroundColor('#c9a06c')
            .onClick(() => {
              this.reloadPage();
            })
          Button('修改服务器地址')
            .width(200)
            .height(46)
            .fontSize(15)
            .fontColor('#8a7a5c')
            .backgroundColor('#f1e8d8')
            .margin({ top: 12 })
            .onClick(() => {
              this.editUrl = this.currentUrl;
              this.openSettingsPanel();
            })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .padding({ left: 48, right: 48 })
        .backgroundColor(HANAKO_BG)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // 悬浮球：拖动时为光感球，静置 3 秒自动变形为细条吸附边缘；点击打开设置菜单；菜单打开时隐藏。
      // 仅在已连接服务器（已配置地址）时显示，欢迎/首次引导界面不出现
      if (this.isChatReady && !this.hasError && !this.showSettings && this.currentUrl.length > 0) {
        Stack() {
          // 视觉层：球/条变形（属性动画过渡）
          Stack() {
            // 顶部高光（玻璃光感，球形态可见）
            Row()
              .width(52)
              .height(52)
              .borderRadius(26)
              .linearGradient({
                angle: 160,
                colors: [['#B3FFFFFF', 0.0], ['#00FFFFFF', 0.45], ['#00FFFFFF', 1.0]]
              })
              .opacity(this.isBall ? 1 : 0)
            // 暖色光晕（球形态可见）
            Row()
              .width(52)
              .height(52)
              .borderRadius(26)
              .linearGradient({
                angle: 315,
                colors: [['#33F0C08A', 0.0], ['#00F0C08A', 0.55], ['#00F0C08A', 1.0]]
              })
              .opacity(this.isBall ? 1 : 0)
            // 球内设置图标（球形态可见）
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(24)
              .fontColor(['#8a7a5c'])
              .opacity(this.isBall ? 1 : 0)
              .scale({ x: this.isBall ? 1 : 0.3, y: this.isBall ? 1 : 0.3 })
          }
          .width(this.isBall ? 52 : 14)
          .height(this.isBall ? 52 : 76)
          .borderRadius(this.isBall ? 26 : 7)
          .backgroundColor(this.isBall ? '#99FCF8F1' : '#FBF6EC')
          .opacity(this.ballDragging ? 1 : 0.92)
          .border({ width: 1, color: this.isBall ? '#80FFFFFF' : '#00000000' })
          .shadow({
            radius: this.isBall ? 16 : 6,
            color: this.isBall ? '#40C9A06C' : '#22000000',
            offsetY: this.isBall ? 4 : 2
          })
          .clip(true)
          // 拖动中动画时长归零：位置即时跟手；松手后恢复 280ms 做球/条变形过渡
          .animation({ duration: this.ballDragging ? 0 : 280, curve: Curve.EaseInOut })
        }
        .width(this.isBall ? BALL_HIT_W : BALL_HIT_W_BAR)
        .height(this.isBall ? BALL_HIT_H : BALL_HIT_H_BAR)
        .position({ x: this.ballX, y: this.ballY })
        .markAnchor({ x: '50%', y: '50%' })
        // 拖动中动画时长归零：热区跟随手指不滞后
        .animation({ duration: this.ballDragging ? 0 : 280, curve: Curve.EaseInOut })
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 1 })
              .onAction(() => {
                this.stopIdleTimer();
                this.openSettingsPanel();
              }),
            PanGesture({ direction: PanDirection.All, distance: BALL_DRAG_DISTANCE })
              .onActionStart(() => {
                hilog.info(DOMAIN, TAG, 'ball drag start x=%{public}d y=%{public}d', this.ballX, this.ballY);
                this.stopIdleTimer();
                this.isBall = true;
                this.ballDragging = true;
                this.dragOriginX = this.ballX;
                this.dragOriginY = this.ballY;
              })
              .onActionUpdate((event) => {
                this.ballX = this.dragOriginX + event.offsetX;
                this.ballY = this.dragOriginY + event.offsetY;
              })
              .onActionEnd(() => {
                hilog.info(DOMAIN, TAG, 'ball drag end x=%{public}d y=%{public}d', this.ballX, this.ballY);
                this.ballDragging = false;
                this.snapBall();
                this.restartIdleTimer();
              })
              .onActionCancel(() => {
                hilog.info(DOMAIN, TAG, 'ball drag cancel');
                this.ballDragging = false;
                this.snapBall();
                this.restartIdleTimer();
              })
          )
        )
      }

      // 设置菜单遮罩：点击空白关闭
      if (this.showSettings) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#22000000')
          .onClick(() => {
            this.closeSettingsPanel();
          })
      }

      // 设置菜单：屏幕正中间，淡入缩放
      if (this.showSettings) {
        Column() {
          Text('服务器设置')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#3a3226')
            .margin({ bottom: 18 })
          Button() {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.qrcode'))
                .fontSize(18)
                .fontColor(['#ffffff'])
              Text('扫码连接')
                .fontSize(16)
                .fontColor('#ffffff')
            }
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height(46)
          .backgroundColor('#c9a06c')
          .margin({ bottom: 12 })
          .onClick(() => {
            this.startScan();
          })
          TextInput({ text: this.editUrl, placeholder: 'http://主机IP:端口/mobile/', controller: this.serverInputCtrl })
            .width('100%')
            .height(48)
            .backgroundColor('#ffffff')
            .fontSize(16)
            .textAlign(TextAlign.Start)
            .defaultFocus(true)
            // 输入期间不重置光标；仅在面板出现时定位一次：空地址归左（默认），非空地址到末尾
            .onAppear(() => {
              this.serverInputCtrl.caretPosition(this.editUrl.length === 0 ? 0 : this.editUrl.length);
            })
            .onChange((value: string) => {
              this.editUrl = value;
            })
          Text('扫码电脑端 Hanako 的连接二维码自动识别地址，\n或手动输入 http://主机IP:端口/mobile/')
            .fontSize(13)
            .fontColor('#8a7a5c')
            .lineHeight(19)
            .margin({ top: 10 })
            .width('100%')
          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(46)
              .fontSize(16)
              .fontColor('#8a7a5c')
              .backgroundColor('#f1e8d8')
              .onClick(() => {
                this.closeSettingsPanel();
              })
            Button('保存并连接')
              .layoutWeight(1)
              .height(46)
              .fontSize(16)
              .fontColor('#ffffff')
              .backgroundColor('#c9a06c')
              .onClick(() => {
                this.saveSettings();
              })
          }
          .margin({ top: 22 })
          .width('100%')
        }
        .padding(22)
        .borderRadius(18)
        .backgroundColor('#FBF6EC')
        .shadow({ radius: 20, color: '#33000000', offsetY: 4 })
        .width(Math.min(320, this.screenW * 0.88))
        .position({ x: this.screenW / 2, y: this.screenH / 2 })
        .markAnchor({ x: '50%', y: '50%' })
        .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 200, curve: Curve.EaseOut }))
      }

      // 图片操作菜单：底部弹出卡片（复制/分享）
      if (this.showImgMenu) {
        Column() {
          Column() {
            Text('图片操作')
              .fontSize(13)
              .fontColor('#a8977e')
              .margin({ top: 16, bottom: 4 })
            Row() {
              Text('📋')
                .fontSize(20)
              Text('复制图片（测试中）')
                .fontSize(17)
                .fontColor('#3a3226')
                .margin({ left: 14 })
              Blank()
              Text('›')
                .fontSize(18)
                .fontColor('#d8cdb8')
            }
            .width('100%')
            .height(60)
            .padding({ left: 26, right: 24 })
            .onClick(() => {
              const b: string = this.menuB64;
              const n: string = String(this.menuName || '');
              this.closeImageMenu();
              copyBase64ToClipboard(b);
              this.controller.runJavaScript(`window.__hanakoImageCopyB64='${b}';window.__hanakoImageCopyName='${n}';console.log('[hanako] copy injected len='+window.__hanakoImageCopyB64.length);`)
                .catch((err: BusinessError) => {
                  hilog.warn(DOMAIN, TAG, '[copy] runJavaScript failed: %{public}s', JSON.stringify(err));
                });
              this.toast('图片已复制');
            })
            Divider()
              .strokeWidth(0.5)
              .color('#eee4d0')
              .margin({ left: 60, right: 0 })
            Row() {
              Text('📤')
                .fontSize(20)
              Text('分享')
                .fontSize(17)
                .fontColor('#3a3226')
                .margin({ left: 14 })
              Blank()
              Text('›')
                .fontSize(18)
                .fontColor('#d8cdb8')
            }
            .width('100%')
            .height(60)
            .padding({ left: 26, right: 24 })
            .onClick(() => {
              const b: string = this.menuB64;
              const n: string = this.menuName;
              // 必须在 closeImageMenu 之前捕获 UIContext，否则菜单销毁后 UIContext 可能失效
              const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
              this.closeImageMenu();
              this.toast(`正在分享 ${n}`);
              const p: Promise<void> = shareBase64(hostCtx, b, n);
              p.catch((err: BusinessError) => {
                hilog.warn(DOMAIN, TAG, 'share promise err: %{public}s', JSON.stringify(err));
                this.toast('分享失败：' + (err.message || '未知错误'));
              });
            })
            Divider()
              .strokeWidth(0.5)
              .color('#eee4d0')
              .margin({ top: 4 })
            Text('取消')
              .fontSize(17)
              .fontColor('#8a7a5c')
              .width('100%')
              .height(52)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.closeImageMenu();
              })
          }
          .width('100%')
          .backgroundColor('#FFFDF8')
          .borderRadius({ topLeft: 26, topRight: 26 })
          .padding({ bottom: 22 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .backgroundColor('#55000000')
        .onClick(() => {
          this.closeImageMenu();
        })
        .transition(TransitionEffect.translate({ y: 60 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 220, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bgColor)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      // Area 的 width/height 单位已是 vp，直接使用，不再 px2vp
      const w: number = typeof newArea.width === 'number' ? newArea.width : parseFloat(String(newArea.width));
      const h: number = typeof newArea.height === 'number' ? newArea.height : parseFloat(String(newArea.height));
      // 尺寸变化前记录白条吸附边与高度比例，变化后按比例重算，保持用户拖拽的位置
      const wasInit: boolean = this.ballX >= 0 && this.ballY >= 0 && this.screenW > 0 && this.screenH > 0;
      const wasLeft: boolean = wasInit ? this.ballX < this.screenW / 2 : false;
      const yRatio: number = wasInit ? this.ballY / this.screenH : 0.55;
      this.screenW = w;
      this.screenH = h;
      // 旋转/窗口尺寸变化：横屏状态栏高度不同，重算避让值并重注入
      this.updateStatusBarHeight();
      if (w > 0 && h > 0) {
        if (wasInit) {
          this.ballX = wasLeft ? this.ballInset() : w - this.ballInset();
          this.ballY = this.clampBallY(yRatio * h);
        } else if (this.ballX < 0 || this.ballY < 0) {
          // 窗口属性也未能定位：首次恢复（记忆位置或默认右缘 55%）
          this.restoreBallPosition();
        }
      }
    })
  }
}
