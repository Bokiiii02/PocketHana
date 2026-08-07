/*
 * Hanako 壳 · 分享中转页
 * ShareExtensionAbility 必须加载 UI 会话，本页负责拉起主界面后关闭扩展
 */
import { common, UIExtensionContentSession } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0008;
const TAG: string = 'HanakoShare';

@Entry
@Component
struct SharePage {
  @LocalStorageProp('session') session: UIExtensionContentSession | null = null;
  private jumping: boolean = false;

  aboutToAppear(): void {
    this.jumpToMain();
  }

  private jumpToMain(): void {
    if (this.jumping) {
      return;
    }
    this.jumping = true;
    const ctx = getContext(this) as common.UIExtensionContext;
    try {
      ctx.startAbility({
        bundleName: 'com.boki.hanako.mobile',
        abilityName: 'EntryAbility'
      }).then(() => {
        this.session?.terminateSelf();
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'start main failed: %{public}s', JSON.stringify(err));
        this.session?.terminateSelf();
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'start ability error: %{public}s', JSON.stringify(e));
      this.session?.terminateSelf();
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('正在分享到 Hanako…')
        .fontSize(16)
        .fontColor('#333333')
      LoadingProgress()
        .width(36)
        .height(36)
        .color('#c9a06c')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F7F1E7')
  }
}
