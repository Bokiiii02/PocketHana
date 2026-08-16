/*
 * Hanako 壳 · 后台推送提醒
 * 独立 WebSocket 连接，监听官方 notification 事件，触发系统本地通知
 * 说明：App 长时间后台时 WebSocket 可能被系统挂起（鸿蒙后台限制），前台/短后台有效
 */
import { webSocket, http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0007;
const TAG: string = 'HanakoNotify';

export class NotificationClient {
  private static ws: webSocket.WebSocket | null = null;
  private static connected: boolean = false;
  private static closedByUser: boolean = false;
  private static reconnectTimer: number = -1;
  private static reconnectAttempt: number = 0;
  private static notifySeq: number = 1;
  // 强制重连节流：10 秒内最多一次
  private static lastReconnectTs: number = 0;

  static get isConnected(): boolean {
    return NotificationClient.connected;
  }

  /** 建立通知 WS 连接（幂等） */
  static async connect(baseUrl: string): Promise<boolean> {
    NotificationClient.closedByUser = false;
    if (NotificationClient.connected) {
      return true;
    }
    try {
      // 拿 ws-ticket（需带登录 Cookie）
      const ticketUrl: string = baseUrl.replace(/\/mobile\/?$/, '') + '/api/ws-ticket';
      const cookie: string = webview.WebCookieManager.getCookie(baseUrl);
      const req = http.createHttp();
      const opt: http.HttpRequestOptions = { method: http.RequestMethod.POST, readTimeout: 10000, connectTimeout: 8000 };
      if (cookie.length > 0) {
        opt.header = { 'Cookie': cookie };
      }
      const resp = await req.request(ticketUrl, opt);
      req.destroy();
      if (resp.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'ws-ticket failed: %{public}d', resp.responseCode);
        return false;
      }
      const raw: string = resp.result as string;
      const j = JSON.parse(raw) as Record<string, Object>;
      const ticket: string = j['ticket'] !== undefined ? String(j['ticket']) : '';
      if (ticket.length === 0) {
        return false;
      }
      const wsBase: string = baseUrl.replace(/^http/, 'ws').replace(/\/mobile\/?$/, '');
      const wsUrl: string = `${wsBase}/ws?wsTicket=${ticket}`;
      const ws = webSocket.createWebSocket();
      NotificationClient.ws = ws;
      ws.on('open', () => {
        // 代际防护：强制重连后旧连接迟到的回调不得覆盖新连接状态
        if (NotificationClient.ws !== ws) {
          return;
        }
        NotificationClient.connected = true;
        NotificationClient.reconnectAttempt = 0;
        hilog.info(DOMAIN, TAG, 'notify ws open');
      });
      ws.on('message', (_err: BusinessError, data: string | ArrayBuffer) => {
        if (NotificationClient.ws !== ws) {
          return;
        }
        if (typeof data !== 'string') {
          return;
        }
        try {
          const ev = JSON.parse(data) as Record<string, Object>;
          if (ev['type'] === 'notification') {
            const title: string = ev['title'] !== undefined ? String(ev['title']) : 'Hanako';
            const body: string = ev['body'] !== undefined ? String(ev['body']) : '有新的消息';
            hilog.info(DOMAIN, TAG, 'notification event received: %{public}s', body.slice(0, 40));
            NotificationClient.publish(title, body);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'notify msg parse error: %{public}s', JSON.stringify(e));
        }
      });
      ws.on('close', () => {
        if (NotificationClient.ws !== ws) {
          return;
        }
        NotificationClient.connected = false;
        hilog.info(DOMAIN, TAG, 'notify ws close');
        if (!NotificationClient.closedByUser) {
          NotificationClient.scheduleReconnect(baseUrl);
        }
      });
      ws.on('error', (err: BusinessError) => {
        if (NotificationClient.ws !== ws) {
          return;
        }
        NotificationClient.connected = false;
        hilog.warn(DOMAIN, TAG, 'notify ws error: %{public}s', JSON.stringify(err));
      });
      await ws.connect(wsUrl);
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'notify ws connect error: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private static scheduleReconnect(baseUrl: string): void {
    if (NotificationClient.reconnectTimer !== -1 || NotificationClient.closedByUser) {
      return;
    }
    const delay: number = Math.min(3000 * Math.pow(2, NotificationClient.reconnectAttempt), 60000);
    NotificationClient.reconnectAttempt++;
    NotificationClient.reconnectTimer = setTimeout(() => {
      NotificationClient.reconnectTimer = -1;
      NotificationClient.connect(baseUrl).catch(() => {
      });
    }, delay);
  }

  /**
   * 前台恢复/页面显示时调用：强制重建 WS（10 秒节流）。
   * 应用长时间后台时 WebSocket 会被系统挂起且可能不触发 close，
   * connected 标志残留为 true 造成假活连接，回前台强制重连兜底。
   */
  static async reconnect(baseUrl: string): Promise<void> {
    if (baseUrl.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - NotificationClient.lastReconnectTs < 10000) {
      return;
    }
    NotificationClient.lastReconnectTs = now;
    hilog.info(DOMAIN, TAG, 'notify force reconnect');
    NotificationClient.disconnect();
    await NotificationClient.connect(baseUrl);
  }

  /** 发布本地通知 */
  private static publish(title: string, body: string): void {
    try {
      notificationManager.isNotificationEnabled().then((enabled: boolean) => {
        hilog.info(DOMAIN, TAG, 'notification enabled=%{public}s', String(enabled));
        if (!enabled) {
          hilog.warn(DOMAIN, TAG, 'notification disabled by user');
          return;
        }
        const request: notificationManager.NotificationRequest = {
          id: NotificationClient.notifySeq,
          notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title: title,
              text: body
            }
          }
        };
        NotificationClient.notifySeq++;
        notificationManager.publish(request).then(() => {
          hilog.info(DOMAIN, TAG, 'notification published: %{public}s', title);
        }).catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'publish failed: %{public}s', JSON.stringify(err));
        });
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'isNotificationEnabled failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish error: %{public}s', JSON.stringify(e));
    }
  }

  static disconnect(): void {
    NotificationClient.closedByUser = true;
    if (NotificationClient.reconnectTimer !== -1) {
      clearTimeout(NotificationClient.reconnectTimer);
      NotificationClient.reconnectTimer = -1;
    }
    if (NotificationClient.ws !== null) {
      NotificationClient.ws.close();
      NotificationClient.ws = null;
    }
    NotificationClient.connected = false;
  }
}
