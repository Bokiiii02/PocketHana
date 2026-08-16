/*
 * Hanako 壳 · 华为推送（Push Kit）桥接
 * 获取 Push Token 并上报到 Hana 服务端的 huawei-push 插件路由。
 * 服务端插件收到 Hanako 通知后经华为推送通道下发，应用后台被冻结/被杀也能收到。
 */
import { pushService } from '@kit.PushKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0009;
const TAG: string = 'HanakoPush';

export class PushBridge {
  /** 获取 Push Token 并上报（带登录 Cookie）。连接成功（onPageEnd）后调用。 */
  static async register(baseUrl: string): Promise<void> {
    if (baseUrl.length === 0) {
      return;
    }
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
}
