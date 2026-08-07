/*
 * Hanako 壳 · 分享桥
 * 分享扩展与主界面同进程，通过模块级静态变量传递待处理内容
 * pendingText：文本（罕见，部分来源分享真文本）
 * pendingFileUri：文件/图片 uri（鸿蒙分享文字会转图片，主流路径）
 */
export class ShareBridge {
  static pendingText: string = '';
  static pendingFileUri: string = '';
}
