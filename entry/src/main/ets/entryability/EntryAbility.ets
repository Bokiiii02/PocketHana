/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { writeShareFiles, writeShareText, ShareFileItem } from '../service/ShareBridge';
import { toBase64, guessMime, detectImageType, extForType } from '../service/ShareUtil';

const DOMAIN = 0x0000;
const SHARE_DOMAIN = 0x0008;
const SHARE_TAG = 'HanakoShare';
const MAX_SHARE_BYTES: number = 20 * 1024 * 1024;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.handleShareWant(want, launchParam);
  }

  /** 系统分享拉起（App 已在运行） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleShareWant(want, launchParam);
  }

  /** 判断是否被系统分享拉起，解析分享数据写入 Preferences */
  private handleShareWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      if (launchParam.launchReasonMessage !== 'ReasonMessage_SystemShare') {
        return;
      }
      hilog.info(SHARE_DOMAIN, SHARE_TAG, 'system share launch, want.uri=%{public}s', want.uri ?? '');
      systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
        const records: Array<systemShare.SharedRecord> = data.getRecords();
        hilog.info(SHARE_DOMAIN, SHARE_TAG, 'share records: %{public}d', records.length);
        const files: ShareFileItem[] = [];
        let text: string = '';
        for (const rec of records) {
          if (rec.uri !== undefined && rec.uri.length > 0) {
            const item: ShareFileItem | null = this.readShareFileItem(rec.uri);
            if (item !== null) {
              files.push(item);
            }
          } else if (rec.content !== undefined && rec.content.length > 0 && text.length === 0) {
            text = rec.content;
          }
        }
        if (files.length > 0) {
          writeShareFiles(this.context, files).then(() => {
            hilog.info(SHARE_DOMAIN, SHARE_TAG, 'share files persisted: %{public}d', files.length);
          });
        }
        if (text.length > 0) {
          writeShareText(this.context, text).then(() => {
            hilog.info(SHARE_DOMAIN, SHARE_TAG, 'share text persisted');
          });
        }
      }).catch((err: BusinessError) => {
        hilog.warn(SHARE_DOMAIN, SHARE_TAG, 'getSharedData failed: %{public}s', JSON.stringify(err));
      });
    } catch (e) {
      hilog.warn(SHARE_DOMAIN, SHARE_TAG, 'handleShareWant error: %{public}s', JSON.stringify(e));
    }
  }

  /** 读取分享文件：magic bytes 检测图片类型，base64 暂存 path 字段 */
  private readShareFileItem(uri: string): ShareFileItem | null {
    try {
      const f = fileIo.openSync(uri);
      const size: number = fileIo.statSync(f.fd).size;
      if (size <= 0 || size > MAX_SHARE_BYTES) {
        fileIo.closeSync(f);
        hilog.warn(SHARE_DOMAIN, SHARE_TAG, 'share file size invalid: %{public}d', size);
        return null;
      }
      const buf = new ArrayBuffer(size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const bytes = new Uint8Array(buf);
      const b64: string = toBase64(bytes);
      let name: string = uri.split('/').pop() || 'share';
      let type: string = detectImageType(bytes);
      if (type.length > 0) {
        // 图片且无扩展名时补扩展名，确保页面识别为图片显示预览
        if (name.indexOf('.') === -1) {
          name = name + extForType(type);
        }
      } else {
        type = guessMime(name);
      }
      const item: ShareFileItem = new ShareFileItem();
      item.b64 = b64;
      item.name = name;
      item.type = type;
      hilog.info(SHARE_DOMAIN, SHARE_TAG, 'share file read: %{public}s (%{public}d bytes) type=%{public}s', name, size, type);
      return item;
    } catch (e) {
      hilog.warn(SHARE_DOMAIN, SHARE_TAG, 'readShareFileItem failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 沉浸式：全屏布局 + 系统栏透明。
    // 状态栏/导航条设为透明，让状态栏区域透出底下内容（ArkWeb 页面内容或壳层取色背景），
    // 避免不透明系统栏盖在页面顶部形成独立色带；图标颜色由壳层按背景亮度自适应（见 Index.ets）。
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#00000000',
        navigationBarContentColor: '#00000000'
      });
      mainWindow.setWindowBackgroundColor('#F7F1E7');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Window config failed. Cause: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
