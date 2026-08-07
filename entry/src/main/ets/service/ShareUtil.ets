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
