/*
 * Hanako 壳 · 分享桥
 * 分享内容跨进程传递：base64 写沙箱文件，Preferences 存路径元信息（跨进程安全、支持多文件、避免大字符串）
 * 主界面消费后清理文件与记录
 */
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';

const STORE: string = 'hanako_share';
const KEY_TEXT: string = 'share_text';
const KEY_FILES: string = 'share_files';
const KEY_SEQ: string = 'share_seq';
const KEY_TOO_MANY: string = 'share_too_many';
const MAX_SHARE_FILES: number = 5;

export class ShareFileItem {
  path: string = '';
  name: string = '';
  type: string = '';
  b64: string = '';
}

export class SharePayload {
  text: string = '';
  files: ShareFileItem[] = [];
  seq: number = 0;
  tooMany: boolean = false;
}

/** 写入文本分享 */
export async function writeShareText(context: Context, text: string): Promise<void> {
  try {
    const store = await preferences.getPreferences(context, { name: STORE });
    await store.put(KEY_TEXT, text);
    await store.put(KEY_FILES, '');
    await store.put(KEY_SEQ, Date.now());
    await store.flush();
    hilog.info(DOMAIN, TAG, 'share text written: %{public}s', text.slice(0, 50));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'writeShareText failed: %{public}s', JSON.stringify(e));
  }
}

/** 写入多文件分享（base64 落沙箱文件，Preferences 存路径） */
export async function writeShareFiles(context: Context, items: ShareFileItem[]): Promise<void> {
  try {
    const baseDir: string = context.filesDir;
    const saved: ShareFileItem[] = [];
    const ts: number = Date.now();
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const p: string = `${baseDir}/hanako_share_${ts}_${i}.txt`;
      const f = fileIo.openSync(p, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, it.b64);
      fileIo.closeSync(f);
      const savedItem: ShareFileItem = new ShareFileItem();
      savedItem.path = p;
      savedItem.name = it.name;
      savedItem.type = it.type;
      saved.push(savedItem);
    }
    const store = await preferences.getPreferences(context, { name: STORE });
    await store.put(KEY_TEXT, '');
    await store.put(KEY_FILES, JSON.stringify(saved));
    await store.put(KEY_SEQ, Date.now());
    await store.flush();
    hilog.info(DOMAIN, TAG, 'share files written: %{public}d', saved.length);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'writeShareFiles failed: %{public}s', JSON.stringify(e));
  }
}

/** 同步清空分享记录（putSync 立即生效，防轮询重复注入），flush 后台落盘 */
export function clearShareSync(context: Context): void {
  try {
    const store = preferences.getPreferencesSync(context, { name: STORE });
    const filesJson: string = store.getSync(KEY_FILES, '') as string;
    store.putSync(KEY_TEXT, '');
    store.putSync(KEY_FILES, '');
    store.putSync(KEY_SEQ, 0);
    store.putSync(KEY_TOO_MANY, 0);
    store.flush().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'clearShareSync flush failed: %{public}s', JSON.stringify(err));
    });
    if (filesJson.length > 0) {
      const list: ShareFileItem[] = JSON.parse(filesJson) as ShareFileItem[];
      for (const it of list) {
        try {
          fileIo.unlinkSync(it.path);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'unlink share file failed: %{public}s', JSON.stringify(e));
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'share cleared sync');
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'clearShareSync failed: %{public}s', JSON.stringify(e));
  }
}

/** 标记分享文件超限 */
export async function markTooMany(context: Context): Promise<void> {
  try {
    const store = await preferences.getPreferences(context, { name: STORE });
    await store.put(KEY_TOO_MANY, 1);
    await store.flush();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'markTooMany failed: %{public}s', JSON.stringify(e));
  }
}

/** 读取分享内容（只读不清理，注入成功后再 clearShare） */
export async function readShare(context: Context): Promise<SharePayload> {
  const payload: SharePayload = new SharePayload();
  try {
    const store = await preferences.getPreferences(context, { name: STORE });
    const text: string = (await store.get(KEY_TEXT, '')) as string;
    const filesJson: string = (await store.get(KEY_FILES, '')) as string;
    payload.seq = (await store.get(KEY_SEQ, 0)) as number;
    payload.tooMany = ((await store.get(KEY_TOO_MANY, 0)) as number) === 1;
    if (text.length > 0) {
      payload.text = text;
      hilog.info(DOMAIN, TAG, 'share read text');
    }
    if (filesJson.length > 0) {
      const list: ShareFileItem[] = JSON.parse(filesJson) as ShareFileItem[];
      for (const it of list) {
        try {
          const item: ShareFileItem = new ShareFileItem();
          item.path = it.path;
          item.name = it.name;
          item.type = it.type;
          item.b64 = fileIo.readTextSync(it.path);
          payload.files.push(item);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'read share file failed: %{public}s', JSON.stringify(e));
        }
      }
      hilog.info(DOMAIN, TAG, 'share read files: %{public}d', payload.files.length);
    }
    return payload;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'readShare failed: %{public}s', JSON.stringify(e));
    return payload;
  }
}

/** 清理分享记录与沙箱文件（注入成功后调用） */
export async function clearShare(context: Context): Promise<void> {
  try {
    const store = await preferences.getPreferences(context, { name: STORE });
    const filesJson: string = (await store.get(KEY_FILES, '')) as string;
    await store.put(KEY_TEXT, '');
    await store.put(KEY_FILES, '');
    await store.flush();
    if (filesJson.length > 0) {
      const list: ShareFileItem[] = JSON.parse(filesJson) as ShareFileItem[];
      for (const it of list) {
        try {
          fileIo.unlinkSync(it.path);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'unlink share file failed: %{public}s', JSON.stringify(e));
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'share cleared');
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'clearShare failed: %{public}s', JSON.stringify(e));
  }
}
