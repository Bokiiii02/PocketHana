/*
 * Hanako 壳 · 系统分享扩展
 * 接收系统分享（图片/文件/文字转图），传递给主界面加入对话
 * 鸿蒙分享文字会转为图片，因此主流路径是文件 uri
 */
import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ShareBridge } from '../service/ShareBridge';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';

export default class ShareExtAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(DOMAIN, TAG, 'onSessionCreate, uri=%{public}s, abilityName=%{public}s', want.uri ?? '', want.abilityName ?? '');
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      // 主路径：分享的 uri（图片/文件/文字转图）
      try {
        const t: string = fileIo.readTextSync(uri);
        if (t.length > 0) {
          ShareBridge.pendingText = t;
          hilog.info(DOMAIN, TAG, 'share text received: %{public}s', t.slice(0, 50));
        } else {
          ShareBridge.pendingFileUri = uri;
          hilog.info(DOMAIN, TAG, 'share file uri: %{public}s', uri);
        }
      } catch (e) {
        // 非文本（图片/文件）：交给主界面按文件处理
        ShareBridge.pendingFileUri = uri;
        hilog.info(DOMAIN, TAG, 'share file uri: %{public}s', uri);
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
}
