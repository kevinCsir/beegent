import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { Palette } from '../config/Palette';
import { Attachment } from '../swarm/RichMessage';
import { AttachmentService } from '../swarm/AttachmentService';

// Limit concurrent thumbnail downloads/decodes during history scrolling.
class PreviewSlots {
  private static active: number = 0;
  private static waiting: Array<() => void> = [];
  static async acquire(): Promise<void> {
    if (PreviewSlots.active < 2) { PreviewSlots.active++; return; }
    await new Promise<void>((resolve) => { PreviewSlots.waiting.push(resolve); });
  }
  static release(): void {
    const next = PreviewSlots.waiting.shift();
    if (next) { next(); } else { PreviewSlots.active--; }
  }
}

@Component
export struct ImagePreview {
  @Prop @Watch('reload') file: Attachment = new Attachment('', {}, '');
  @Prop sessionKey: string = '';
  fullscreen: boolean = false;
  onOpen: () => void = () => {};
  @State bitmap: image.PixelMap | undefined = undefined;
  @State loading: boolean = true;
  @State error: string = '';
  @State zoomLevel: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;
  private generation: number = 0;
  private visible: boolean = false;
  aboutToAppear(): void { this.visible = true; this.reload(); }
  aboutToDisappear(): void { this.visible = false; this.generation++; this.release(); }
  private release(): void {
    const bitmap = this.bitmap; this.bitmap = undefined;
    if (bitmap) { bitmap.release().catch(() => {}); }
  }
  private reload(): void {
    if (!this.visible) { return; }
    this.load().catch(() => {});
  }
  private async load(): Promise<void> {
    const generation = ++this.generation;
    const file = this.file; const session = this.sessionKey;
    this.release(); this.loading = true; this.error = ''; this.zoomLevel = 1; this.offsetX = 0; this.offsetY = 0;
    await PreviewSlots.acquire();
    try {
      if (!this.visible || generation !== this.generation) { return; }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bitmap = await new AttachmentService().previewImage(context, file, session, this.fullscreen ? 2560 : 960);
      if (!this.visible || generation !== this.generation) { await bitmap.release(); return; }
      this.bitmap = bitmap;
    } catch (error) {
      if (this.visible && generation === this.generation) { this.error = (error as Error).message || '图片加载失败'; }
    } finally {
      PreviewSlots.release();
      if (this.visible && generation === this.generation) { this.loading = false; }
    }
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.bitmap) {
        if (this.fullscreen) {
          Image(this.bitmap).width('100%').height('100%').objectFit(ImageFit.Contain)
            .scale({ x: this.zoomLevel, y: this.zoomLevel }).translate({ x: this.offsetX, y: this.offsetY })
            .gesture(GestureGroup(GestureMode.Parallel,
              PinchGesture().onActionStart(() => { this.baseScale = this.zoomLevel; })
                .onActionUpdate((event: GestureEvent) => { this.zoomLevel = Math.max(1, Math.min(5, this.baseScale * event.scale)); })
                .onActionEnd(() => { if (this.zoomLevel === 1) { this.offsetX = 0; this.offsetY = 0; } }),
              PanGesture().onActionStart(() => { this.baseX = this.offsetX; this.baseY = this.offsetY; })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.zoomLevel > 1) { this.offsetX = Math.max(-1000, Math.min(1000, this.baseX + event.offsetX)); this.offsetY = Math.max(-1000, Math.min(1000, this.baseY + event.offsetY)); }
                }),
              TapGesture({ count: 2 }).onAction(() => { this.zoomLevel = this.zoomLevel > 1 ? 1 : 2; this.offsetX = 0; this.offsetY = 0; })
            ))
        } else {
          Image(this.bitmap).width('100%').height('100%').objectFit(ImageFit.Contain).onClick(this.onOpen)
        }
      } else if (this.loading) {
        Column({ space: 8 }) { LoadingProgress().width(28).height(28).color(Palette.ink); Text('正在加载图片…').fontSize(12).fontColor(Palette.muted) }
      } else {
        Column({ space: 10 }) {
          Text(this.error || '图片暂时无法预览').fontSize(12).fontColor(Palette.muted).maxLines(3)
          Button('重新加载').fontSize(12).height(30).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => this.reload())
        }.padding(12)
      }
    }.width('100%').height(this.fullscreen ? '100%' : 220).clip(true).borderRadius(this.fullscreen ? 0 : 10).backgroundColor(Palette.soft)
  }
}
