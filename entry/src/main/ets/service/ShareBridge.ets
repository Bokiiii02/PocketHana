/*
 * Hanako 壳 · 分享桥
 * 分享扩展与主界面同进程，通过模块级静态变量传递待填入对话的文本
 */
export class ShareBridge {
  static pendingText: string = '';
}
