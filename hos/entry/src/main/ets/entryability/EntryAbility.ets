import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { LogStore } from '../diagnostics/LogStore';
import { AttachmentService } from '../swarm/AttachmentService';
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Palette } from '../config/Palette';
export default class EntryAbility extends UIAbility {
  onCreate(): void { LogStore.initialize(this.context.filesDir); AttachmentService.cleanupStartup(this.context); }
  onForeground(): void { CommunicationLog.record('app.foreground'); AttachmentService.cleanupHandoffs(); }
  onBackground(): void { CommunicationLog.record('app.background'); LogStore.flush().catch(() => {}); }
  onDestroy(): void { CommunicationLog.record('app.destroy'); LogStore.flush().catch(() => {}); }
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
    stage.getMainWindow().then((main: window.Window) => {
      main.setWindowSystemBarProperties({ statusBarColor: Palette.background, navigationBarColor: Palette.background,
        statusBarContentColor: Palette.ink, navigationBarContentColor: Palette.ink }).catch(() => {});
    }).catch(() => {});
  }
}
