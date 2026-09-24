import { Palette } from '../config/Palette';
import { TodoItem } from '../swarm/RichMessage';

@Component
export struct TodoProgress {
  @Prop items: TodoItem[] = [];
  @Prop @Watch('reset') sessionKey: string = '';
  @State expanded: boolean = false;
  private reset(): void { this.expanded = false; }
  private title(): string {
    const completed = this.items.filter((item: TodoItem) => item.status === 'completed').length;
    const running = this.items.find((item: TodoItem) => item.status === 'in_progress');
    return '任务进度 ' + completed.toString() + '/' + this.items.length.toString() + (running ? ' · ' + running.activeForm : '');
  }
  private status(item: TodoItem): string {
    if (item.status === 'completed') { return '✓ 已完成'; }
    if (item.status === 'in_progress') { return '◌ 进行中'; }
    if (item.status === 'cancelled') { return '− 已取消'; }
    return '○ 待开始';
  }
  build() {
    Column({ space: 6 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Text(this.expanded ? '⌄' : '›').fontSize(16)
          Text(this.title()).fontSize(12).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }.height(30).width('100%').padding({ left: 10, right: 10 }).borderRadius(10)
        .fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => { this.expanded = !this.expanded; })
      if (this.expanded) {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.items, (item: TodoItem) => {
              Row({ space: 10 }) {
                Text(this.status(item)).fontSize(11).fontColor(item.status === 'in_progress' ? Palette.ink : Palette.muted).width(68)
                Text(item.status === 'in_progress' ? item.activeForm : item.content).fontSize(12).fontColor(Palette.ink).layoutWeight(1)
              }.width('100%').alignItems(VerticalAlign.Top)
            }, (item: TodoItem) => item.id + '|' + item.status + '|' + item.content + '|' + item.activeForm)
          }.width('100%').padding(10)
        }.width('100%').constraintSize({ maxHeight: 150 }).backgroundColor(Palette.soft).borderRadius(10)
      }
    }.width('100%').padding({ left: 16, right: 16, bottom: 6 }).id('todo-progress')
  }
}
