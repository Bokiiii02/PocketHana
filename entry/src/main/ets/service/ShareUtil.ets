/*
 * Hanako 壳 · 文件工具
 * base64 编码与 MIME 推断（ArkTS 无全局 btoa，手动实现）
 */

/** Uint8Array → base64 字符串 */
export function toBase64(bytes: Uint8Array): string {
  const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out: string = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0: number = bytes[i];
    const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const n: number = (b0 << 16) | (b1 << 8) | b2;
    out += chars[(n >> 18) & 63];
    out += chars[(n >> 12) & 63];
    out += chars[(n >> 6) & 63];
    out += chars[n & 63];
  }
  const pad: number = bytes.length % 3;
  if (pad === 1) {
    out = out.slice(0, -2) + '==';
  } else if (pad === 2) {
    out = out.slice(0, -1) + '=';
  }
  return out;
}

/** 按扩展名推断 MIME */
export function guessMime(name: string): string {
  const n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.gif')) return 'image/gif';
  if (n.endsWith('.webp')) return 'image/webp';
  if (n.endsWith('.pdf')) return 'application/pdf';
  if (n.endsWith('.txt') || n.endsWith('.md')) return 'text/plain';
  return 'application/octet-stream';
}

/** 文件头 magic bytes 检测真实图片类型（分享 uri 常无扩展名，扩展名推断不可靠） */
export function detectImageType(bytes: Uint8Array): string {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) {
    return 'image/gif';
  }
  if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    return 'image/webp';
  }
  return '';
}

/** 按 MIME 补扩展名（文件无扩展名时） */
export function extForType(type: string): string {
  if (type === 'image/png') return '.png';
  if (type === 'image/jpeg') return '.jpg';
  if (type === 'image/gif') return '.gif';
  if (type === 'image/webp') return '.webp';
  return '';
}
