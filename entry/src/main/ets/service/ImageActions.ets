/*
 * Hanako 壳 · 图片操作
 * base64 图片：保存到相册（系统保存对话框）、复制到剪贴板、系统分享
 */
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0009;
const TAG: string = 'HanakoImage';

const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** base64 → 字节（ArkTS 无全局 atob） */
export function base64ToBytes(b64: string): Uint8Array {
  const len: number = b64.length;
  const cap: number = Math.floor(len * 3 / 4) + 3;
  const out = new Uint8Array(cap);
  let n: number = 0;
  let bits: number = 0;
  let oi: number = 0;
  for (let i = 0; i < len; i++) {
    const c: number = B64_CHARS.indexOf(b64[i]);
    if (c < 0) {
      continue;
    }
    n = (n << 6) | c;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[oi] = (n >> bits) & 0xFF;
      oi++;
    }
  }
  return out.subarray(0, oi);
}

/** 写沙箱临时文件，返回路径 */
export function writeTempFile(context: Context, name: string, bytes: Uint8Array): string {
  const p: string = `${context.filesDir}/${name}`;
  const f = fileIo.openSync(p, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  fileIo.closeSync(f);
  return p;
}

/** 保存图片到图库（PhotoViewPicker 系统图库保存框，无需权限） */
export async function saveBase64ToLibrary(context: Context, b64: string, name: string): Promise<void> {
  try {
    const bytes: Uint8Array = base64ToBytes(b64);
    const photoPicker = new picker.PhotoViewPicker();
    const uris: string[] = await photoPicker.save({ newFileNames: [name] });
    if (uris.length > 0) {
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
      fileIo.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'saved to library: %{public}s', name);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'saveBase64ToLibrary failed: %{public}s', JSON.stringify(e));
  }
}

/** 保存图片（系统保存对话框选择位置，写入目标文件，无需权限；用于附件类保存） */
export async function saveBase64ToGallery(context: Context, b64: string, name: string): Promise<void> {
  try {
    const bytes: Uint8Array = base64ToBytes(b64);
    const docPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await docPicker.save({ newFileNames: [name] });
    if (uris.length > 0) {
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
      fileIo.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'save dialog shown: %{public}s', name);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'saveBase64ToGallery failed: %{public}s', JSON.stringify(e));
  }
}

/** 复制图片到剪贴板 */
export async function copyBase64ToClipboard(b64: string): Promise<void> {
  try {
    const bytes: Uint8Array = base64ToBytes(b64);
    const src = image.createImageSource(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    const pixelMap: image.PixelMap = await src.createPixelMap();
    const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
    await pasteboard.getSystemPasteboard().setData(data);
    hilog.info(DOMAIN, TAG, 'copied to clipboard');
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'copyBase64ToClipboard failed: %{public}s', JSON.stringify(e));
  }
}

/** 系统分享图片 */
export async function shareBase64(context: Context, b64: string, name: string): Promise<void> {
  hilog.info(DOMAIN, TAG, 'share called: %{public}s', name);
  try {
    const bytes: Uint8Array = base64ToBytes(b64);
    const path: string = writeTempFile(context, name, bytes);
    const uri: string = `file://${path}`;
    const ext: string = name.includes('.') ? `.${name.split('.').pop()}` : '.png';
    const utdId: string = utd.getUniformDataTypeByFilenameExtension(ext, utd.UniformDataType.IMAGE);
    const data = new systemShare.SharedData({
      utd: utdId,
      uri: uri,
      title: name
    });
    const controller = new systemShare.ShareController(data);
    await controller.show(context as common.UIAbilityContext, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT
    });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'shareBase64 failed: %{public}s', JSON.stringify(e));
  }
}
