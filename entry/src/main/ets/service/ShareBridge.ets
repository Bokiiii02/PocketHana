/*
 * Hanako 壳 · 分享桥
 * 用 Preferences 跨进程传递分享内容（UIExtension 可能与主界面不同进程，
 * 模块级静态变量在跨进程场景不可靠，Preferences 基于文件存储，跨进程安全）
 */
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';

const STORE: string = 'hanako_share';
const KEY_TEXT: string = 'share_text';
const KEY_B64: string = 'share_file_b64';
const KEY_NAME: string = 'share_file_name';
const KEY_TYPE: string = 'share_file_type';

export class ShareBridge {
  static pendingText: string = '';
  static pendingFileB64: string = '';
  static pendingFileName: string = '';
  static pendingFileType: string = '';
}

export async function writeShare(context: Context, text: string, b64: string, name: string, type: string): Promise<void> {
  try {
    const store = await preferences.getPreferences(context, { name: STORE });
    await store.put(KEY_TEXT, text);
    await store.put(KEY_B64, b64);
    await store.put(KEY_NAME, name);
    await store.put(KEY_TYPE, type);
    await store.flush();
    hilog.info(DOMAIN, TAG, 'share written to prefs: text=%{public}d b64=%{public}d name=%{public}s', text.length, b64.length, name);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'writeShare failed: %{public}s', JSON.stringify(e));
  }
}

export class SharePayload {
  text: string = '';
  b64: string = '';
  name: string = '';
  type: string = '';
}

export async function readAndClearShare(context: Context): Promise<SharePayload> {
  const empty: SharePayload = new SharePayload();
  try {
    const store = await preferences.getPreferences(context, { name: STORE });
    const text: string = (await store.get(KEY_TEXT, '')) as string;
    const b64: string = (await store.get(KEY_B64, '')) as string;
    const name: string = (await store.get(KEY_NAME, '')) as string;
    const type: string = (await store.get(KEY_TYPE, '')) as string;
    await store.put(KEY_TEXT, '');
    await store.put(KEY_B64, '');
    await store.put(KEY_NAME, '');
    await store.put(KEY_TYPE, '');
    await store.flush();
    if (text.length > 0 || b64.length > 0) {
      hilog.info(DOMAIN, TAG, 'share read from prefs: text=%{public}d b64=%{public}d name=%{public}s', text.length, b64.length, name);
      const p: SharePayload = new SharePayload();
      p.text = text;
      p.b64 = b64;
      p.name = name;
      p.type = type;
      return p;
    }
    return empty;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'readAndClearShare failed: %{public}s', JSON.stringify(e));
    return empty;
  }
}
