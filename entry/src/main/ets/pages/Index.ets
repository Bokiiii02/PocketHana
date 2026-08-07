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
import { window, promptAction } from '@kit.ArkUI';
import { scanBarcode } from '@kit.ScanKit';
import { url } from '@kit.ArkTS';
import { NotificationClient } from '../service/NotificationClient';
import { ShareBridge } from '../service/ShareBridge';

const DOMAIN: number = 0x0001;
const TAG: string = 'HanakoShell';
// 默认服务器地址：空，首次打开引导用户自行设置
const DEFAULT_URL: string = '';
const PREFS_NAME: string = 'hanako_mobile';
const KEY_SERVER_URL: string = 'server_url';
// onErrorReceive 的 ERR_ABORTED：页面导航被主动中断（如 SPA 路由），不算失败
const ERR_ABORTED: number = -3;
// 背景色轮询间隔（毫秒）
const COLOR_POLL_MS: number = 2500;

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State currentUrl: string = DEFAULT_URL;
  @State isLoading: boolean = true;
  @State hasError: boolean = false;
  @State isChatReady: boolean = false;
  @State showSettings: boolean = false;
  @State editUrl: string = DEFAULT_URL;
  // 页面主背景色（系统栏 / 窗口 / 壳层 UI 统一跟随）
  @State bgColor: string = '#F7F1E7';
  // 状态栏高度（vp），用于注入 CSS 让顶部横栏避让状态栏
  @State statusBarHeightVp: number = 0;
  // 白条：固定位置（中心点 vp 坐标，右缘垂直 55%）
  @State ballX: number = -1;
  @State ballY: number = -1;
  private screenW: number = 0;
  private screenH: number = 0;
  private colorTimer: number = -1;
  private lastBarColor: string = '';
  private pendingBarColor: string = '';
  private win: window.Window | null = null;
  private netConn: connection.NetConnection | null = null;

  aboutToAppear(): void {
    this.loadServerUrl();
    this.watchNetwork();
    this.acquireWindow();
    this.startColorWatcher();
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

  /** 初始化/重算白条位置（右缘垂直 55%）。不依赖 onAreaChange，用窗口属性双保险 */
  private initBallPosition(): void {
    try {
      if (this.win !== null) {
        const rect = this.win.getWindowProperties().windowRect;
        const w: number = typeof rect.width === 'number' ? rect.width : 0;
        const h: number = typeof rect.height === 'number' ? rect.height : 0;
        if (w > 0 && h > 0) {
          this.screenW = this.getUIContext().px2vp(w);
          this.screenH = this.getUIContext().px2vp(h);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'initBallPosition failed: %{public}s', JSON.stringify(e));
    }
    if (this.screenW > 0 && this.screenH > 0) {
      this.ballX = this.screenW - 8;
      this.ballY = this.screenH * 0.55;
    }
  }

  private updateStatusBarHeight(): void {
    try {
      if (this.win === null) {
        return;
      }
      const area: window.AvoidArea = this.win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusBarHeightVp = this.getUIContext().px2vp(area.topRect.height);
      hilog.info(DOMAIN, TAG, 'statusBarHeight=%{public}d vp', this.statusBarHeightVp);
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
        `._workspaceHeader{padding-right:16px!important}`;
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

  /** 关闭设置菜单（白条留在原位） */
  private closeSettingsPanel(): void {
    this.showSettings = false;
  }

  /** 系统分享：把待分享文本注入页面输入框 */
  private checkShare(): void {
    if (ShareBridge.pendingText.length === 0 || !this.isChatReady) {
      return;
    }
    const text: string = ShareBridge.pendingText;
    ShareBridge.pendingText = '';
    try {
      const script: string =
        `(()=>{const el=document.querySelector('[contenteditable="true"]');if(!el)return;el.focus();` +
        `document.execCommand('insertText',false,${JSON.stringify(text)});})()`;
      this.controller.runJavaScript(script).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'inject share text failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'checkShare error: %{public}s', JSON.stringify(e));
    }
  }

  private reloadPage(): void {
    this.hasError = false;
    this.isLoading = true;
    this.isChatReady = false;
    try {
      this.controller.loadUrl(this.currentUrl);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'reload failed: %{public}s', JSON.stringify(e));
      this.isLoading = false;
    }
  }

  private saveSettings(): void {
    let u: string = this.editUrl.trim();
    if (u.length === 0) {
      promptAction.showToast({ message: '请输入服务器地址' });
      return;
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://' + u;
    }
    // 地址 origin 变化（且已有地址）：清 cookie，提示重新验证，自动回登录页
    if (this.currentUrl.length > 0 && !this.isSameOrigin(this.currentUrl, u)) {
      this.clearCookies();
      promptAction.showToast({ message: '检测到地址改变，需要重新验证' });
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
          promptAction.showToast({ message: '检测到地址改变，需要重新验证' });
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
          // 页面开始加载：清错误态，避免 reload 后白条停留在错误状态
          this.hasError = false;
        })
        .onPageEnd(() => {
          this.isLoading = false;
          this.hasError = false;
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
          hilog.error(DOMAIN, TAG, 'onErrorReceive code=%{public}d', code);
          this.isLoading = false;
          if (code !== ERR_ABORTED) {
            this.hasError = true;
            this.isChatReady = false;
          }
        })
        .onHttpErrorReceive((event) => {
          const code: number = event.response?.getResponseCode() ?? 0;
          hilog.warn(DOMAIN, TAG, 'onHttpErrorReceive code=%{public}d', code);
          // 401/403 属于登录态问题，页面自带登录流程，交给页面自己渲染
          if (code >= 400 && code !== 401 && code !== 403) {
            this.isLoading = false;
            this.hasError = true;
            this.isChatReady = false;
          }
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

      // 首次连接加载页（图标严格居中，与启动窗口图标位置一致；加载指示固定在图标下方）
      if (this.isLoading && !this.hasError) {
        Stack() {
          // 背景层
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.bgColor)
          // 图标：屏幕正中心
          Image($r('app.media.startIcon'))
            .width(160)
            .height(160)
            .borderRadius(36)
            .position({ x: '50%', y: '50%' })
            .markAnchor({ x: '50%', y: '50%' })
          // 加载指示：图标下方固定位置
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color('#c9a06c')
            Text('Hana酱正在启动QwQ')
              .fontSize(14)
              .fontColor('#8a7a5c')
              .margin({ top: 10 })
          }
          .position({ x: '50%', y: '50%' })
          .markAnchor({ x: '50%', y: '50%' })
          .translate({ y: 118 })
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
          Text('请确认电脑已开机、Hanako 正在运行，\n且手机与电脑在同一局域网内')
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
        .backgroundColor('#F7F1E7')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // 右缘白条（固定）：点击打开居中的设置菜单；菜单打开时隐藏
      if (this.isChatReady && !this.hasError && !this.showSettings) {
        Button() {
          Text('')
            .width(1)
        }
        .width(14)
        .height(76)
        .borderRadius(7)
        .backgroundColor('#FBF6EC')
        .opacity(0.75)
        .position({ x: this.ballX, y: this.ballY })
        .markAnchor({ x: '50%', y: '50%' })
        .shadow({ radius: 6, color: '#22000000', offsetY: 2 })
        .onClick(() => {
          this.openSettingsPanel();
        })
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bgColor)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      // Area 的 width/height 单位已是 vp，直接使用，不再 px2vp
      const w: number = typeof newArea.width === 'number' ? newArea.width : parseFloat(String(newArea.width));
      const h: number = typeof newArea.height === 'number' ? newArea.height : parseFloat(String(newArea.height));
      this.screenW = w;
      this.screenH = h;
      // 固定位置：每次区域变化重算（白条右缘 55%）
      if (w > 0 && h > 0) {
        this.ballX = w - 8;
        this.ballY = h * 0.55;
      }
      // 旋转/窗口尺寸变化：横屏状态栏高度不同，重算避让值并重注入
      this.updateStatusBarHeight();
    })
  }
}
