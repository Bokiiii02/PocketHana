/*
 * Hanako 壳 · 华为推送（Push Kit）桥接
 * 获取 Push Token 并上报到 Hana 服务端的 huawei-push 插件路由。
 * 服务端插件收到 Hanako 通知后经华为推送通道下发，应用后台被冻结/被杀也能收到。
 * 前台收到推送消息（foregroundShow=false 的通知消息）时通过 messageListener 转发给页面刷新角标。
 */
import { pushService } from '@kit.PushKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0009;
const TAG: string = 'HanakoPush';

/** 前台推送消息回调（title/body，无会话路径字段） */
export type PushMessageListener = (title: string, content: string) => void;

export class PushBridge {
  private static msgListener: PushMessageListener | null = null;
  private static lastBaseUrl: string = '';

  /** 注册前台推送消息回调（EntryAbility 的 receiveMessage 转发） */
  static setMessageListener(l: PushMessageListener | null): void {
    PushBridge.msgListener = l;
  }

  /** EntryAbility 收到前台推送消息时调用：转发给页面刷新未读角标 */
  static handleForegroundMessage(title: string, content: string): void {
    if (PushBridge.msgListener !== null) {
      PushBridge.msgListener(title, content);
    }
  }

  /** Push Token 更新（设备跨境/重装等）时由 EntryAbility 调用：重新上报 */
  static reRegister(): void {
    if (PushBridge.lastBaseUrl.length > 0) {
      PushBridge.register(PushBridge.lastBaseUrl).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 're-register failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  /** 获取 Push Token 并上报（带登录 Cookie）。连接成功（onPageEnd）后调用。 */
  static async register(baseUrl: string): Promise<void> {
    if (baseUrl.length === 0) {
      return;
    }
    PushBridge.lastBaseUrl = baseUrl;
    let token: string = '';
    try {
      token = await pushService.getToken();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getToken failed: %{public}d %{public}s', err.code, err.message);
      return;
    }
    if (token.length === 0) {
      hilog.warn(DOMAIN, TAG, 'getToken empty, skip register');
      return;
    }
    hilog.info(DOMAIN, TAG, 'push token obtained len=%{public}d', token.length);
    try {
      const url: string = baseUrl.replace(/\/mobile\/?$/, '') + '/api/plugins/huawei-push/register';
      const cookie: string = webview.WebCookieManager.getCookie(baseUrl);
      const req = http.createHttp();
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        readTimeout: 10000,
        connectTimeout: 8000,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({ token: token }),
      };
      if (cookie.length > 0) {
        opt.header = { 'Content-Type': 'application/json', 'Cookie': cookie };
      }
      const resp = await req.request(url, opt);
      req.destroy();
      hilog.info(DOMAIN, TAG, 'token register resp=%{public}d', resp.responseCode);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'token register failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 前台存活心跳：告诉服务端「手机在线」，插件据此跳过推送（避免与 WS 即时通知重复）。失败静默。 */
  static async heartbeat(baseUrl: string): Promise<void> {
    if (baseUrl.length === 0) {
      return;
    }
    try {
      const url: string = baseUrl.replace(/\/mobile\/?$/, '') + '/api/plugins/huawei-push/heartbeat';
      const cookie: string = webview.WebCookieManager.getCookie(baseUrl);
      const req = http.createHttp();
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        readTimeout: 5000,
        connectTimeout: 5000,
        header: { 'Content-Type': 'application/json' },
      };
      if (cookie.length > 0) {
        opt.header = { 'Content-Type': 'application/json', 'Cookie': cookie };
      }
      const resp = await req.request(url, opt);
      req.destroy();
      if (resp.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'heartbeat resp=%{public}d', resp.responseCode);
      }
    } catch (e) {
      // 心跳失败静默（下次再试）
    }
  }
}
