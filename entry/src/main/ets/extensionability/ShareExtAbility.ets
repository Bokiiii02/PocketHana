/*
 * Hanako 壳 · 系统分享扩展
 * 接收系统分享（图片/文件/文字转图），在扩展进程读文件转 base64，
 * 交由主界面注入对话附件（跨进程读分享 uri 会失去临时授权，故提前读好）
 */
import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ShareBridge, ShareFileData } from '../service/ShareBridge';
import { toBase64, guessMime } from '../service/ShareUtil';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';

const MAX_SHARE_BYTES: number = 20 * 1024 * 1024;

export default class ShareExtAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(DOMAIN, TAG, 'onSessionCreate, uri=%{public}s', want.uri ?? '');
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      // 先尝试按文本读（罕见的真文本分享）
      try {
        const t: string = fileIo.readTextSync(uri);
        if (t.length > 0) {
          ShareBridge.pendingText = t;
          hilog.info(DOMAIN, TAG, 'share text received: %{public}s', t.slice(0, 50));
        } else {
          this.readFileToBridge(uri);
        }
      } catch (e) {
        // 非文本：按文件读 base64
        this.readFileToBridge(uri);
      }
    } else {
      // 无 uri 兜底：parameters 里的文本
      if (want.parameters !== undefined) {
        const tryGet = (k: string): string => {
          const v = want.parameters?.[k];
          return typeof v === 'string' ? v : '';
        };
        let t: string = tryGet('shareMessages');
        if (t.length === 0) t = tryGet('share_text');
        if (t.length === 0) t = tryGet('text');
        if (t.length > 0) {
          ShareBridge.pendingText = t;
          hilog.info(DOMAIN, TAG, 'share text received (params): %{public}s', t.slice(0, 50));
        }
      }
    }
    // 加载中转页（UIExtension 必须加载 UI 会话），由页面拉起主界面并关闭扩展
    const storage = new LocalStorage();
    storage.setOrCreate('session', session);
    session.loadContent('pages/SharePage', storage);
  }

  private readFileToBridge(uri: string): void {
    try {
      const f = fileIo.openSync(uri);
      const stat = fileIo.statSync(f.fd);
      const size: number = stat.size;
      if (size <= 0 || size > MAX_SHARE_BYTES) {
        fileIo.closeSync(f);
        hilog.warn(DOMAIN, TAG, 'share file size invalid: %{public}d', size);
        return;
      }
      const buf = new ArrayBuffer(size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const b64: string = toBase64(new Uint8Array(buf));
      const name: string = uri.split('/').pop() || 'share';
      const data: ShareFileData = new ShareFileData();
      data.b64 = b64;
      data.name = name;
      data.type = guessMime(name);
      ShareBridge.pendingFile = data;
      hilog.info(DOMAIN, TAG, 'share file read ok: %{public}s (%{public}d bytes)', name, size);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'share file read failed: %{public}s', JSON.stringify(e));
    }
  }
}
