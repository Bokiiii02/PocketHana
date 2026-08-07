/*
 * Hanako 壳 · 系统分享扩展
 * 从系统分享面板接收文本，填入对话输入框（拉起主界面）
 */
import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ShareBridge } from '../service/ShareBridge';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';

export default class ShareExtAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    let text: string = '';
    // 记录完整 want 便于排查
    hilog.info(DOMAIN, TAG, 'onSessionCreate, uri=%{public}s, abilityName=%{public}s', want.uri ?? '', want.abilityName ?? '');
    if (want.parameters !== undefined) {
      const keys: string[] = Object.keys(want.parameters);
      hilog.info(DOMAIN, TAG, 'parameters keys: %{public}s', keys.join(','));
      // 常见字段兜底：shareMessages / share_text / text
      const tryGet = (k: string): string => {
        const v = want.parameters?.[k];
        return typeof v === 'string' ? v : '';
      };
      let t: string = tryGet('shareMessages');
      if (t.length === 0) t = tryGet('share_text');
      if (t.length === 0) t = tryGet('text');
      if (t.length === 0) t = tryGet('description');
      if (t.length > 0) {
        text = t;
      }
    }
    // 尝试读取分享的文本（文本分享时 uri 指向临时文本文件）
    const uri: string = want.uri ?? '';
    if (uri.length > 0 && text.length === 0) {
      try {
        text = fileIo.readTextSync(uri);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'readTextSync failed, try openSync: %{public}s', JSON.stringify(e));
        try {
          const f = fileIo.openSync(uri);
          const buf = new ArrayBuffer(fileIo.statSync(f.fd).size);
          fileIo.readSync(f.fd, buf);
          fileIo.closeSync(f);
          const bytes = new Uint8Array(buf);
          let s: string = '';
          for (let i = 0; i < bytes.length; i++) {
            s += String.fromCharCode(bytes[i]);
          }
          text = s;
        } catch (e2) {
          hilog.warn(DOMAIN, TAG, 'openSync read failed: %{public}s', JSON.stringify(e2));
        }
      }
    }
    if (text.length > 0) {
      ShareBridge.pendingText = text;
      hilog.info(DOMAIN, TAG, 'share text received: %{public}s', text.slice(0, 50));
    }
    // 拉起主界面
    try {
      this.context.startAbility({
        bundleName: 'com.boki.hanako.mobile',
        abilityName: 'EntryAbility'
      }).then(() => {
        session.terminateSelf();
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'start main ability failed: %{public}s', JSON.stringify(err));
        session.terminateSelf();
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'start ability error: %{public}s', JSON.stringify(e));
      session.terminateSelf();
    }
  }
}
