/*
 * Hanako 移动端壳
 * ArkWeb 加载 HanaAgent 移动端页面，提供连接错误兜底、服务器地址配置、
 * 扫码连接、右缘白条菜单与系统栏自动取色
 */
import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { scanBarcode } from '@kit.ScanKit';
import { url } from '@kit.ArkTS';
import { NotificationClient } from '../service/NotificationClient';
import { readShare, clearShareSync, SharePayload, ShareFileItem } from '../service/ShareBridge';
import { saveBase64ToLibrary, copyBase64ToClipboard, shareBase64 } from '../service/ImageActions';

const DOMAIN: number = 0x0001;
const TAG: string = 'HanakoShell';
// 默认服务器地址：空，首次打开引导用户自行设置
const DEFAULT_URL: string = '';
const PREFS_NAME: string = 'hanako_mobile';
const KEY_SERVER_URL: string = 'server_url';
// 白条位置记忆：吸附边（'L'/'R'）+ 高度比例
const KEY_BALL_EDGE: string = 'ball_edge';
const KEY_BALL_Y: string = 'ball_y_ratio';
// 白条/悬浮球吸附后中心距屏幕边缘的距离（vp：条宽 14 / 球径 52 的一半，完全贴边）
const BALL_EDGE_INSET: number = 7;
const BALL_EDGE_INSET_ROUND: number = 26;
// 白条手势热区（vp，视觉层居中，热区放大便于手指按住）
const BALL_HIT_W: number = 56;
const BALL_HIT_H: number = 100;
// 白条拖动判定阈值（vp）：超过视为拖拽，未超过视为点击打开菜单
const BALL_DRAG_DISTANCE: number = 8;
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
// 背景色轮询间隔（毫秒）
const COLOR_POLL_MS: number = 2500;

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
  // 页面主背景色（系统栏 / 窗口 / 壳层 UI 统一跟随）
  @State bgColor: string = '#F7F1E7';
  // 状态栏高度（vp），用于注入 CSS 让顶部横栏避让状态栏
  @State statusBarHeightVp: number = 0;
  // 导航条高度（vp），用于白条拖拽纵向边界
  @State navBarHeightVp: number = 0;
  // 白条：固定位置（中心点 vp 坐标，吸附左/右缘，高度可拖拽）
  @State ballX: number = -1;
  @State ballY: number = -1;
  // 白条拖动中（用于视觉反馈）
  @State ballDragging: boolean = false;
  // 形态：true=悬浮球（拖动/静置初期），false=细条（静置后自动变形）
  @State isBall: boolean = false;
  private screenW: number = 0;
  private screenH: number = 0;
  // 拖拽起点（白条中心点，vp）
  private dragOriginX: number = 0;
  private dragOriginY: number = 0;
  // 悬浮球静置计时器
  private idleTimer: number = -1;
  private colorTimer: number = -1;
  private loadTimer: number = -1;
  private lastBarColor: string = '';
  private pendingBarColor: string = '';
  private win: window.Window | null = null;
  private netConn: connection.NetConnection | null = null;

  aboutToAppear(): void {
    this.loadServerUrl();
    this.watchNetwork();
    this.acquireWindow();
    this.startColorWatcher();
    // 兜底启动加载超时计时：即使 Web 组件的 onPageBegin 因异常未触发，
    // 20 秒后也能强制退出加载态进入错误页（onPageBegin 会正常重置计时）
    this.startLoadTimer();
  }

  /** 页面每次显示（含从后台回前台、分享拉起）时立即消费分享数据 */
  onPageShow(): void {
    this.checkShare();
    // 回前台：通知 WS 可能已被系统挂起（鸿蒙后台限制），强制重建（内部 10 秒节流）
    if (this.currentUrl.length > 0 && this.isChatReady) {
      NotificationClient.reconnect(this.currentUrl).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'notify reconnect failed: %{public}s', JSON.stringify(err));
      });
    }
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
    this.stopColorWatcher();
    this.stopLoadTimer();
    this.stopIdleTimer();
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
        if (this.pendingBarColor.length > 0) {
          const c: string = this.pendingBarColor;
          this.pendingBarColor = '';
          this.applyBarColors(c);
        }
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
   * 应用页面主背景色：系统栏（状态栏 + 导航条）、窗口背景、壳层 UI 统一同步。
   * 图标颜色根据背景亮度自适应（亮底深图标 / 暗底浅图标）。
   */
  private applyBarColors(color: string): void {
    try {
      if (this.win === null) {
        // 窗口尚未就绪，暂存待窗口获取成功后补发
        this.pendingBarColor = color;
        return;
      }
      this.bgColor = color;
      const iconColor: string = this.isLightColor(color) ? '#00000000' : '#FFFFFFFF';
      hilog.info(DOMAIN, TAG, 'applyBarColors color=%{public}s icon=%{public}s', color, iconColor);
      // 系统栏背景保持透明，状态栏区域透出底下内容（ArkWeb 页面或窗口背景）
      this.win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: iconColor,
        navigationBarContentColor: iconColor
      });
      this.win.setWindowBackgroundColor(color);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'applyBarColors failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 判断颜色是否偏亮（用于系统栏图标深浅色选择） */
  private isLightColor(color: string): boolean {
    let hex: string = color.trim();
    if (hex.startsWith('#')) {
      hex = hex.slice(1);
    }
    if (hex.length === 3) {
      hex = hex.split('').map((c: string) => c + c).join('');
    }
    if (hex.length >= 6) {
      const r: number = parseInt(hex.slice(0, 2), 16);
      const g: number = parseInt(hex.slice(2, 4), 16);
      const b: number = parseInt(hex.slice(4, 6), 16);
      return (r * 299 + g * 587 + b * 114) / 1000 >= 150;
    }
    return true;
  }

  /**
   * 轮询页面主背景色。
   * 优先取 body 实际计算背景色（浏览器已解析，主题无论切在 html 还是 body 都能取到）；
   * --bg 变量仅作兜底，并解析 var() 引用。
   */
  private readPageBackground(): void {
    try {
      const expr: string =
        `(function(){var b='';` +
        `var bc=getComputedStyle(document.body).backgroundColor;` +
        `if(bc&&bc.indexOf('0, 0, 0, 0')<0&&bc!=='transparent')b=bc;` +
        `if(!b||b==='transparent')b=getComputedStyle(document.documentElement).backgroundColor||'';` +
        `if(b&&b.indexOf('rgb')===0){var m=b.match(/rgba?\\(\\s*(\\d+)[,\\s]+(\\d+)[,\\s]+(\\d+)/);` +
        `if(m)b='#'+[m[1],m[2],m[3]].map(function(v){return parseInt(v).toString(16).padStart(2,'0')}).join('');}` +
        `if(!b||b.indexOf('0, 0, 0, 0')>-1){` +
        `var cs=getComputedStyle(document.documentElement);` +
        `var v=(cs.getPropertyValue('--bg')||'').trim();` +
        `if(v.indexOf('var(')===0){var nm=v.match(/var\\((--[\\w-]+)/);if(nm)v=(cs.getPropertyValue(nm[1])||'').trim();}` +
        `if(v&&v.indexOf('rgb')===0){var m2=v.match(/rgba?\\(\\s*(\\d+)[,\\s]+(\\d+)[,\\s]+(\\d+)/);` +
        `if(m2)v='#'+[m2[1],m2[2],m2[3]].map(function(x){return parseInt(x).toString(16).padStart(2,'0')}).join('');}` +
        `b=v||'#F8F4ED';}` +
        `return b;})()`;
      this.controller.runJavaScript(expr).then((res: string) => {
        const v: string = res ? res.trim() : '';
        if (v.length > 0 && v !== this.lastBarColor) {
          this.lastBarColor = v;
          hilog.info(DOMAIN, TAG, 'readPageBackground -> %{public}s', v);
          this.applyBarColors(v);
        }
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'readPageBackground failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'readPageBackground error: %{public}s', JSON.stringify(e));
    }
  }

  private startColorWatcher(): void {
    this.stopColorWatcher();
    this.colorTimer = setInterval(() => {
      this.readPageBackground();
      this.checkLoggedIn();
      this.checkShare();
    }, COLOR_POLL_MS);
  }

  private stopColorWatcher(): void {
    if (this.colorTimer !== -1) {
      clearInterval(this.colorTimer);
      this.colorTimer = -1;
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
   * CSS 每次注入都更新（状态栏高度变化后重刷）；hide/fit 只初始化一次（window 标志）
   */
  private injectUiFixes(): void {
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
        // 会话条目操作按钮常显（电脑端靠 hover 显示，移动端无 hover）：
        // 归档/重命名按钮放大到 24x24 并始终可见，标题区让位
        `[class*="sessionRenameBtn"],[class*="sessionArchiveBtn"]{opacity:0.75!important;width:24px!important;height:24px!important;bottom:6px!important}` +
        `[class*="sessionRenameBtn"]{right:32px!important}` +
        `[class*="sessionArchiveBtn"]{right:6px!important}` +
        `[class*="sessionRenameBtn"] svg,[class*="sessionArchiveBtn"] svg{width:15px!important;height:15px!important}` +
        `[class*="sessionItemHeader"]{padding-right:60px!important}`;
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
        `}` +
        `})()`;
      this.controller.runJavaScript(script).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'injectUiFixes failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'injectUiFixes error: %{public}s', JSON.stringify(e));
    }
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

  private reloadPage(): void {
    this.stopLoadTimer();
    this.hasError = false;
    this.isLoading = true;
    this.isChatReady = false;
    this.errHint = '';
    try {
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
        .onPageBegin(() => {
          hilog.info(DOMAIN, TAG, 'onPageBegin url=%{public}s', this.currentUrl);
          // 仅在非错误态下重启超时计时。
          // 注意：不在此清除 hasError——连接失败后 ArkWeb 可能触发内部导航
          // （内置错误页/自动重试），若清掉错误态会把用户留在白屏且无法操作。
          if (!this.hasError) {
            this.startLoadTimer();
          }
        })
        .onConsole((event: OnConsoleEvent) => {
          const msg: string = event.message.getMessage();
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
          this.isLoading = false;
          // 错误态锁定期间的内部导航结束（如 Chromium 内置错误页）不覆盖错误页
          if (this.hasError) {
            return;
          }
          this.isChatReady = true;
          this.injectUiFixes();
          this.readPageBackground();
          this.checkLoggedIn();
          // 服务器可达：建立通知 WS（后台推送提醒）
          if (this.currentUrl.length > 0) {
            NotificationClient.connect(this.currentUrl).then((ok: boolean) => {
              hilog.info(DOMAIN, TAG, 'notify ws connect: %{public}s', String(ok));
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
          // 仅主文档 HTTP 错误进入错误页；401/403 属于登录态问题，交给页面自身登录流程；
          // 子资源（接口）HTTP 错误不覆盖整页
          if (mainFrame && code >= 400 && code !== 401 && code !== 403) {
            this.stopLoadTimer();
            this.isLoading = false;
            this.hasError = true;
            this.isChatReady = false;
            this.errHint = '';
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
          this.isLoading = false;
          this.hasError = true;
          this.isChatReady = false;
          this.errHint = 'SSL 证书校验失败，请确认服务器地址（https 需使用受信任证书）';
        })

      // 首次引导层：未设置服务器地址时显示
      if (this.currentUrl.length === 0 && !this.hasError) {
        Column() {
          Image($r('app.media.startIcon'))
            .width(96)
            .height(96)
            .borderRadius(22)
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

      // 加载封面（与系统启动窗口同一图标同一背景，视觉无缝衔接为一个封面；
      // 页面 onPageEnd 后自然消失，不再叠加额外的加载指示与文字）
      if (this.isLoading && !this.hasError) {
        Stack() {
          // 背景层
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.bgColor)
          // 图标：屏幕正中心（与启动窗口图标一致）
          Image($r('app.media.startIcon'))
            .width(96)
            .height(96)
            .borderRadius(22)
            .position({ x: '50%', y: '50%' })
            .markAnchor({ x: '50%', y: '50%' })
        }
        .width('100%')
        .height('100%')
      }

      // 连接失败兜底页（固定不透明暖纸底，确保完全覆盖对话页）
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
        .backgroundColor('#F7F1E7')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // 悬浮球：拖动时为光感球，静置 3 秒自动变形为细条吸附边缘；点击打开设置菜单；菜单打开时隐藏。
      // 外层透明热区（56x100）绑手势；互斥手势组显式仲裁点击/拖拽
      if (this.isChatReady && !this.hasError && !this.showSettings) {
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
            // 球内图标（Hanako 头像，球形态可见）
            Image($r('app.media.startIcon'))
              .width(34)
              .height(34)
              .borderRadius(17)
              .opacity(this.isBall ? 1 : 0)
              .scale({ x: this.isBall ? 1 : 0.3, y: this.isBall ? 1 : 0.3 })
          }
          .width(this.isBall ? 52 : 14)
          .height(this.isBall ? 52 : 76)
          .borderRadius(this.isBall ? 26 : 7)
          .backgroundColor(this.isBall ? '#FCF8F1' : '#FBF6EC')
          .opacity(this.ballDragging ? 1 : 0.92)
          .border({ width: 1, color: this.isBall ? '#80FFFFFF' : '#00000000' })
          .shadow({
            radius: this.isBall ? 16 : 6,
            color: this.isBall ? '#40C9A06C' : '#22000000',
            offsetY: this.isBall ? 4 : 2
          })
          .clip(true)
          .animation({ duration: 280, curve: Curve.EaseInOut })
        }
        .width(BALL_HIT_W)
        .height(BALL_HIT_H)
        .position({ x: this.ballX, y: this.ballY })
        .markAnchor({ x: '50%', y: '50%' })
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
          TextInput({ text: this.editUrl, placeholder: 'http://主机IP:端口/mobile/' })
            .width('100%')
            .height(48)
            .backgroundColor('#ffffff')
            .fontSize(16)
            .textAlign(TextAlign.Start)
            .defaultFocus(true)
            .caretPosition(0)
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
