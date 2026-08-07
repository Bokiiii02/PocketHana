/*
 * Hanako 壳 · 分享桥
 * 分享扩展与主界面同进程，通过模块级静态变量传递待处理内容
 * pendingText：文本（罕见，部分来源分享真文本）
 * pendingFile：文件/图片（base64 在扩展进程读好，避免跨进程读权限问题）
 */
export class ShareFileData {
  b64: string = '';
  name: string = '';
  type: string = '';
}

export class ShareBridge {
  static pendingText: string = '';
  static pendingFile: ShareFileData | null = null;
}
