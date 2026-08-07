/*
 * Hanako 壳 · 系统分享扩展
 * 接收系统分享（图片/文件/文字转图），在扩展进程读文件转 base64，
 * 经 Preferences 传递给主界面注入对话附件（跨进程安全）
 * 注意：onSessionCreate 必须同步返回（系统不支持 Promise 生命周期），
 * 数据用同步 API 写入，flush 落盘后再加载中转页
 */
import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { toBase64, guessMime } from '../service/ShareUtil';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';
const STORE: string = 'hanako_share';
const KEY_TEXT: string = 'share_text';
const KEY_B64: string = 'share_file_b64';
const KEY_NAME: string = 'share_file_name';
const KEY_TYPE: string = 'share_file_type';
const MAX_SHARE_BYTES: number = 20 * 1024 * 1024;

export default class ShareExtAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(DOMAIN, TAG, 'onSessionCreate, uri=%{public}s', want.uri ?? '');
    const finish = (): void => {
      const storage = new LocalStorage();
      storage.setOrCreate('session', session);
      session.loadContent('pages/SharePage', storage);
    };
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      // 先尝试按文本读（罕见的真文本分享）
      try {
        const t: string = fileIo.readTextSync(uri);
        if (t.length > 0) {
          this.writeSync(t, '', '', '').then(() => {
            hilog.info(DOMAIN, TAG, 'share text flushed');
            finish();
          }).catch(() => {
            finish();
          });
          return;
        }
      } catch (e) {
        // 非文本，走文件分支
      }
      this.writeFileSync(uri).then(() => {
        finish();
      }).catch(() => {
        finish();
      });
      return;
    }
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
        this.writeSync(t, '', '', '').then(() => {
          hilog.info(DOMAIN, TAG, 'share text flushed (params)');
          finish();
        }).catch(() => {
          finish();
        });
        return;
      }
    }
    finish();
  }

  /** 同步写入 Preferences，返回 flush Promise（落盘完成再放行） */
  private writeSync(text: string, b64: string, name: string, type: string): Promise<void> {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: STORE });
      store.putSync(KEY_TEXT, text);
      store.putSync(KEY_B64, b64);
      store.putSync(KEY_NAME, name);
      store.putSync(KEY_TYPE, type);
      return store.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'writeSync failed: %{public}s', JSON.stringify(e));
      return Promise.reject(e);
    }
  }

  private writeFileSync(uri: string): Promise<void> {
    try {
      const f = fileIo.openSync(uri);
      const stat = fileIo.statSync(f.fd);
      const size: number = stat.size;
      if (size <= 0 || size > MAX_SHARE_BYTES) {
        fileIo.closeSync(f);
        hilog.warn(DOMAIN, TAG, 'share file size invalid: %{public}d', size);
        return Promise.reject(new Error('size invalid'));
      }
      const buf = new ArrayBuffer(size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const b64: string = toBase64(new Uint8Array(buf));
      const name: string = uri.split('/').pop() || 'share';
      hilog.info(DOMAIN, TAG, 'share file read: %{public}s (%{public}d bytes)', name, size);
      return this.writeSync('', b64, name, guessMime(name)).then(() => {
        hilog.info(DOMAIN, TAG, 'share file flushed: %{public}s', name);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'share file read failed: %{public}s', JSON.stringify(e));
      return Promise.reject(e);
    }
  }
}
