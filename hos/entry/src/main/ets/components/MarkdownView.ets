import { Palette } from '../config/Palette';
import { MarkdownBlock, Inline } from '../swarm/Markdown';
@Component
export struct MarkdownView {
  @Prop blocks: MarkdownBlock[] = [];
  onLink: (url: string) => void = () => {};
  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks, (block: MarkdownBlock) => {
        if (block.kind === 'rule') {
          Divider().color(Palette.line)
        } else if (block.kind === 'code') {
          Scroll() {
            Text(block.text || ' ').fontFamily('monospace').fontSize(13).lineHeight(20)
              .fontColor(Palette.ink).copyOption(CopyOptions.LocalDevice).padding(10)
          }.scrollable(ScrollDirection.Horizontal).backgroundColor(Palette.soft).borderRadius(8).width('100%')
        } else {
          Text() {
            ForEach(block.spans, (span: Inline) => {
              Span(span.text).fontWeight(span.style === 'bold' || block.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(span.style === 'italic' ? FontStyle.Italic : FontStyle.Normal)
                .fontFamily(span.style === 'code' ? 'monospace' : 'sans-serif')
                .fontColor(span.style === 'link' ? Palette.ink : block.kind === 'quote' ? Palette.muted : Palette.ink)
                .decoration({ type: span.style === 'strike' ? TextDecorationType.LineThrough : span.style === 'link' ? TextDecorationType.Underline : TextDecorationType.None })
                .onClick(() => { if (span.url) { this.onLink(span.url); } })
            })
          }.fontSize(block.kind === 'heading' ? Math.max(17, 25 - block.level * 2) : 16).lineHeight(25)
            .width('100%').copyOption(CopyOptions.LocalDevice)
            .padding(block.kind === 'quote' ? 10 : 0).backgroundColor(block.kind === 'quote' ? Palette.soft : Color.Transparent)
        }
      }, (block: MarkdownBlock) => block.id + ':' + block.kind + ':' + block.text)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

