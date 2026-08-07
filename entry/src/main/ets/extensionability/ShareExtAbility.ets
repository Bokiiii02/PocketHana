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
    // 尝试读取分享的文本（文本分享时 uri 指向临时文本文件）
    let text: string = '';
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      try {
        text = fileIo.readTextSync(uri);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'read share uri failed: %{public}s', JSON.stringify(e));
      }
    }
    if (text.length === 0) {
      // 兜底：parameters 里可能的文本
      const p = want.parameters;
      if (p !== undefined) {
        const t = p['share_text'];
        if (typeof t === 'string') {
          text = t;
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
