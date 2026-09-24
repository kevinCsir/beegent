import { Palette } from '../config/Palette';
import { Attachment, isImage, isHtml } from '../swarm/RichMessage';
import { ImagePreview } from './ImagePreview';

@Component
export struct InlineAttachment {
  file: Attachment = new Attachment('', {}, '');
  sessionKey: string = '';
  onAction: (file: Attachment, action: string) => void = () => {};
  build() {
    Column({ space: 8 }) {
      if (isImage(this.file) && this.file.available) {
        ImagePreview({ file: this.file, sessionKey: this.sessionKey, onOpen: () => this.onAction(this.file, 'preview') })
        Row({ space: 8 }) {
          Text(this.file.name).fontSize(11).fontColor(Palette.muted).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('↓ 保存').fontSize(12).height(30).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => this.onAction(this.file, 'save'))
          Button('↗ 转发').fontSize(12).height(30).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => this.onAction(this.file, 'share'))
        }.width('100%').justifyContent(FlexAlign.End)
      } else {
        Text('附件 · ' + this.file.name).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
        Text(this.file.mime + (this.file.size ? ' · ' + Math.ceil(this.file.size / 1024).toString() + ' KB' : '')).fontSize(11).fontColor(Palette.muted).width('100%')
        if (this.file.available) {
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('打开').fontSize(12).height(32).backgroundColor(Palette.honey).fontColor(Palette.ink).margin({ right: 8, bottom: 4 }).onClick(() => this.onAction(this.file, 'open')).id('attachment-open')
            Button('保存').fontSize(12).height(32).backgroundColor(Palette.honey).fontColor(Palette.ink).margin({ right: 8, bottom: 4 }).onClick(() => this.onAction(this.file, 'save')).id('attachment-save')
            Button('转发').fontSize(12).height(32).backgroundColor(Palette.honey).fontColor(Palette.ink).margin({ right: 8, bottom: 4 }).onClick(() => this.onAction(this.file, 'share')).id('attachment-share')
            if (isHtml(this.file)) {
              Button('渲染').fontSize(12).height(32).backgroundColor(Palette.honey).fontColor(Palette.ink).margin({ bottom: 4 }).onClick(() => this.onAction(this.file, 'render')).id('attachment-render')
            }
          }.width('100%')
        } else { Text('已收到，但没有可下载内容，请在电脑端查看').fontSize(12).fontColor(Palette.muted).width('100%') }
      }
    }.width('100%').padding(isImage(this.file) ? 0 : 10).backgroundColor(isImage(this.file) ? Color.Transparent : Palette.soft).borderRadius(10)
  }
}
