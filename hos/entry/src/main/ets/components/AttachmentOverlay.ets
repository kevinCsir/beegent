import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { Palette } from '../config/Palette';
import { Attachment } from '../swarm/RichMessage';
import { AttachmentService } from '../swarm/AttachmentService';
import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { ImagePreview } from './ImagePreview';

@Component
export struct AttachmentOverlay {
  file: Attachment = new Attachment('', {}, '');
  kind: string = '';
  sessionKey: string = '';
  onClose: () => void = () => {};
  onAction: (file: Attachment, action: string) => void = () => {};
  @State loading: boolean = true;
  @State error: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private generation: number = 0;
  private visible: boolean = false;
  aboutToAppear(): void { this.visible = true; }
  aboutToDisappear(): void { this.visible = false; this.generation++; }
  private async loadHtml(): Promise<void> {
    const generation = ++this.generation;
    this.loading = true; this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const html = await new AttachmentService().previewHtml(context, this.file, this.sessionKey);
      if (!this.visible || generation !== this.generation) { return; }
      // Isolated origin: HTML has no app bridge, file access, or shared server cookies.
      this.controller.loadData(html, 'text/html', 'UTF-8', 'https://preview.beegent.invalid/');
    } catch (error) {
      if (this.visible && generation === this.generation) { this.error = (error as Error).message || 'HTML 加载失败'; }
    } finally { if (this.visible && generation === this.generation) { this.loading = false; } }
  }
  build() {
    Column() {
      Row({ space: 12 }) {
        Button('‹ 返回').fontSize(14).height(36).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(this.onClose).id('preview-back')
        Column({ space: 3 }) {
          Text(this.file.name).fontSize(15).fontColor(Palette.ink).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.kind === 'html' ? 'HTML 预览' : '双指缩放 · 双击放大／还原').fontSize(11).fontColor(Palette.muted)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding(12)
      if (this.kind === 'image') {
        Column() { ImagePreview({ file: this.file, sessionKey: this.sessionKey, fullscreen: true }) }.layoutWeight(1).width('100%')
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Web({ src: 'about:blank', controller: this.controller, incognitoMode: true })
            .width('100%').height('100%').javaScriptAccess(true).domStorageAccess(false).fileAccess(false)
            .cacheMode(CacheMode.None).mixedMode(MixedMode.All).multiWindowAccess(false)
            .onControllerAttached(() => { this.loadHtml(); })
            .onOverrideUrlLoading((request: WebResourceRequest): boolean => {
              const url = request.getRequestUrl();
              return !/^https?:\/\//i.test(url) && url !== 'about:blank';
            })
            .onPageEnd(() => { CommunicationLog.record('attachment.html.page_end', { sessionId: this.sessionKey, fileId: this.file.id }); })
            .onErrorReceive((event) => {
              if (event?.request.isMainFrame() && this.visible) {
                this.error = '页面加载失败，可返回后保存或使用系统打开';
                CommunicationLog.record('attachment.html.page_error', { sessionId: this.sessionKey, fileId: this.file.id }, 'error');
              }
            })
          if (this.loading || this.error) {
            Column({ space: 12 }) {
              if (this.loading) { LoadingProgress().width(30).height(30).color(Palette.ink); Text('正在加载 HTML…').fontSize(14).fontColor(Palette.muted) }
              else {
                Text(this.error).fontSize(13).fontColor(Palette.muted).padding(20)
                Button('重新加载').fontSize(13).height(34).backgroundColor(Palette.honey).fontColor(Palette.ink).onClick(() => this.loadHtml())
              }
            }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(Palette.background)
          }
        }.layoutWeight(1).width('100%')
      }
      Row({ space: 10 }) {
        Text(this.file.size ? Math.ceil(this.file.size / 1024).toString() + ' KB' : '').fontSize(12).fontColor(Palette.muted).layoutWeight(1)
        Button('↓ 保存').fontSize(13).height(34).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => this.onAction(this.file, 'save'))
        Button('↗ 转发').fontSize(13).height(34).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => this.onAction(this.file, 'share'))
      }.width('100%').padding(12)
    }.width('100%').height('100%').backgroundColor(Palette.background).onClick(() => {}).id('attachment-preview')
  }
}
