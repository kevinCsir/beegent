import { InlineAttachment } from './InlineAttachment';
import { Palette } from '../config/Palette';
import { AgentActivity } from '../swarm/Subagents';
import { MessageView } from '../viewmodel/MessageSource';
import { Answer, Question, Choice, Step, Attachment, Interaction, PlanAction } from '../swarm/RichMessage';
import { markdown } from '../swarm/Markdown';
import { MarkdownView } from './MarkdownView';

@Component
struct QuestionForm {
  interaction: Interaction = new Interaction();
  @Prop revision: number = 0;
  @State selections: string[][] = [];
  @State inputs: string[] = [];
  onSubmit: (answers: Answer[]) => void = () => {};
  aboutToAppear(): void {
    this.selections = this.interaction.questions.map(() => [] as string[]);
    this.inputs = this.interaction.questions.map(() => '');
  }
  private editable(): boolean { return this.revision >= 0 && ['pending', 'failed'].includes(this.interaction.status); }
  private selected(index: number, choice: Choice): boolean { return (this.selections[index] || []).includes(choice.value || choice.label); }
  private choose(index: number, question: Question, choice: Choice): void {
    const value = choice.value || choice.label;
    const selection = this.selections[index] || [];
    const updated = selection.includes(value) ? selection.filter((s: string) => s !== value) : question.multi_select ? selection.concat([value]) : [value];
    this.selections[index] = updated; this.selections = this.selections.slice();
  }
  private submit(): void {
    const answers: Answer[] = this.interaction.questions.map((q: Question, index: number): Answer => {
      return { question: q.question, selected_options: this.selections[index] || [], custom_input: (this.inputs[index] || '').trim(), card_id: q.card_id };
    });
    this.onSubmit(answers);
  }
  private isPlan(): boolean { return this.interaction.planKind === 'plan_approval' && this.interaction.planActions.length > 0; }
  private planAction(kind: string): PlanAction | undefined { return this.interaction.planActions.find((action: PlanAction) => action.kind === kind); }
  private planLabel(kind: string): string { return this.planAction(kind)?.label || (kind === 'execute' ? '执行' : kind === 'skip' ? '跳过' : '下一步'); }
  private planSecondary(): string { return (this.inputs[0] || '').trim() ? 'revise' : 'skip'; }
  private submitPlan(kind: string): void {
    const action = this.planAction(kind);
    const question = this.interaction.questions[0];
    if (!action || !question) { return; }
    this.onSubmit([{ question: question.question, selected_options: [action.value], custom_input: kind === 'revise' ? (this.inputs[0] || '').trim() : '' }]);
  }
  private label(): string {
    if (this.revision < 0) { return ''; }
    switch (this.interaction.status) {
      case 'sending': return '正在提交…'; case 'submitted': return '已提交'; case 'unknown': return '结果待确认，请在电脑端核实';
      case 'expired': return '此确认已失效'; case 'failed': return '重新提交'; default: return '提交回复';
    }
  }
  build() {
    Column({ space: 12 }) {
      Text(this.interaction.planKind === 'plan_approval' ? '计划审批' : '等待你的回复').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      if (this.interaction.planContent) { MarkdownView({ blocks: markdown(this.interaction.planContent) }) }
      if (this.isPlan()) {
        if (!this.interaction.planContent) { Text('本次计划内容为空').fontSize(13).fontColor(Palette.muted).width('100%') }
        TextArea({ text: this.inputs[0] || '', placeholder: '填写计划修改意见，或直接执行／跳过' })
          .fontSize(14).constraintSize({ minHeight: 48, maxHeight: 120 }).enabled(this.editable()).id('plan-feedback')
          .onChange((value: string) => { this.inputs = [value]; })
        Row({ space: 10 }) {
          Button(this.planLabel('execute')).fontSize(13).backgroundColor(Palette.action(this.editable() && !!this.planAction('execute'))).fontColor(Palette.ink).layoutWeight(1).id('plan-execute')
            .enabled(this.editable() && !!this.planAction('execute')).onClick(() => this.submitPlan('execute'))
          Button(this.planLabel(this.planSecondary())).fontSize(13).fontColor(Palette.ink).backgroundColor(Palette.action(this.editable() && !!this.planAction(this.planSecondary()))).layoutWeight(1).id('plan-secondary')
            .enabled(this.editable() && !!this.planAction(this.planSecondary())).onClick(() => this.submitPlan(this.planSecondary()))
        }.width('100%')
        if (!this.editable()) { Text(this.label()).fontSize(12).fontColor(Palette.muted).width('100%') }
      } else {
      ForEach(this.interaction.questions, (question: Question, index: number) => {
        Column({ space: 8 }) {
          Text((question.header ? question.header + ' · ' : '') + question.question).fontSize(15).width('100%')
          ForEach(question.options || [], (choice: Choice) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                Text((this.selected(index, choice) ? '● ' : '○ ') + choice.label).fontSize(14).width('100%')
                if (choice.description) { Text(choice.description).fontSize(12).width('100%') }
              }.padding(10)
            }.width('100%').borderRadius(8).fontColor(Palette.ink)
              .backgroundColor(Palette.action(this.editable()))
              .enabled(this.editable()).onClick(() => this.choose(index, question, choice))
          })
          TextArea({ text: this.inputs[index] || '', placeholder: question.options?.length ? '补充说明或其他回答…' : '填写回复…' })
            .fontSize(14).constraintSize({ minHeight: 44, maxHeight: 120 }).enabled(this.editable())
            .onChange((value: string) => { this.inputs[index] = value; this.inputs = this.inputs.slice(); })
        }.width('100%')
      })
      }
      if (this.interaction.error) { Text(this.interaction.error).fontColor(Palette.ink).fontSize(12).width('100%') }
      if (!this.isPlan()) { Button(this.label()).fontSize(13).backgroundColor(Palette.action(this.editable() && this.interaction.questions.length > 0)).fontColor(Palette.ink).width('100%')
        .enabled(this.editable() && this.interaction.questions.length > 0).onClick(() => this.submit()).id('question-submit') }
    }.width('100%')
  }
}

@Component
export struct MessageCard {
  sessionKey: string = '';
  @ObjectLink message: MessageView;
  @State subagentExpanded: boolean = false;
  @State manualExpansion: number = -1;
  @State expansionVersion: number = -1;
  onAnswer: (id: string, answers: Answer[]) => void = () => {};
  onAttachment: (file: Attachment, action: string) => void = () => {};
  onLink: (url: string) => void = () => {};
  private stepStatus(): string {
    if (this.message.steps.some((step: Step) => step.status === 'error')) { return ' · 有失败'; }
    if (this.message.steps.some((step: Step) => step.status === 'running')) { return ' · 执行中'; }
    return '';
  }
  private expanded(): boolean { return this.expansionVersion !== this.message.collapseVersion || this.manualExpansion < 0 ? !this.message.collapse : this.manualExpansion === 1; }
  build() {
    Column({ space: 6 }) {
      if (this.message.showHeader) {
        Text(this.message.role === 'user' ? '你' : this.message.kind === 'notice' ? '收到消息' : 'beegent')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor(Palette.muted).width('100%')
      }
      if (this.message.kind === 'subagent' && this.message.subagent) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('子代理 · ' + this.message.subagent.name).fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
            Text(this.message.subagent.status).fontSize(12).fontColor(this.message.subagent.running ? Palette.ink : Palette.muted)
          }.width('100%')
          if (this.message.subagent.task) {
            Text(this.message.subagent.task).fontSize(13).fontColor(Palette.muted).width('100%').maxLines(this.subagentExpanded ? 30 : 2)
          }
          Text(this.message.subagent.latest || '等待执行活动…').fontSize(12).fontColor(Palette.muted).width('100%').maxLines(2)
          Button((this.subagentExpanded ? '⌄ 收起' : '› 执行记录') + ' · ' + this.message.subagent.activities.length.toString())
            .fontSize(12).height(28).fontColor(Palette.ink).backgroundColor(Palette.honey)
            .onClick(() => { this.subagentExpanded = !this.subagentExpanded; }).id('subagent-toggle-' + this.message.subagent.id)
          if (this.subagentExpanded) {
            if (this.message.subagent.omitted > 0) { Text('仅保留最近 200 条活动').fontSize(11).fontColor(Palette.muted) }
            ForEach(this.message.subagent.activities, (activity: AgentActivity) => {
              Column({ space: 4 }) {
                Text(activity.title).fontSize(12).fontWeight(FontWeight.Medium).width('100%')
                if (activity.task) { Text('任务 ' + activity.task).fontSize(10).fontColor(Palette.muted).width('100%') }
                Text(activity.text).fontSize(12).fontColor(Palette.muted).width('100%').copyOption(CopyOptions.LocalDevice)
              }.width('100%').padding(8).backgroundColor(Palette.soft).borderRadius(8)
            }, (activity: AgentActivity) => activity.id)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(Palette.surface).borderRadius(12).id('subagent-' + this.message.subagent.id)
      } else if (this.message.kind === 'steps') {
        Column({ space: 6 }) {

          Button((this.expanded() ? '⌄ ' : '› ') + '思考与工具 · ' + this.message.steps.length.toString() + ' 步' + this.stepStatus())
            .fontSize(12).fontColor(Palette.ink).backgroundColor(Palette.honey).height(28).padding({ left: 10, right: 10 }).borderRadius(14)
            .onClick(() => { this.manualExpansion = this.expanded() ? 0 : 1; this.expansionVersion = this.message.collapseVersion; }).id('steps-toggle')
          if (this.expanded()) {
            ForEach(this.message.steps, (step: Step) => {
              Column({ space: 6 }) {
                Text((step.status === 'running' ? '◌ ' : step.status === 'done' ? '✓ ' : '! ') + step.title)
                  .fontSize(13).fontWeight(FontWeight.Medium).fontColor(step.status === 'error' ? Palette.ink : Palette.muted).width('100%')
                Text(step.text || '执行中…').fontSize(12).lineHeight(19).fontColor(Palette.muted).width('100%').copyOption(CopyOptions.LocalDevice)
              }.width('100%').padding(8).backgroundColor(Palette.soft).borderRadius(8)
            }, (step: Step) => step.id + ':' + step.status + ':' + step.text)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      } else {
      Column({ space: 10 }) {
        if (this.message.kind === 'interaction' && this.message.interaction) {
          QuestionForm({ interaction: this.message.interaction, revision: this.message.revision,
            onSubmit: (answers: Answer[]) => this.onAnswer(this.message.interaction!.id, answers) })
        } else if (this.message.kind === 'attachments') {
          if (this.message.text) { Text(this.message.text).fontSize(14).width('100%') }
          ForEach(this.message.attachments, (file: Attachment) => {
            InlineAttachment({ file: file, sessionKey: this.sessionKey, onAction: this.onAttachment })
          }, (file: Attachment) => this.sessionKey + '|' + file.id)
        } else if (this.message.kind === 'text' && this.message.role === 'assistant') {
          MarkdownView({ blocks: this.message.blocks, onLink: this.onLink })
        } else {
          Text(this.message.text || '…').fontSize(this.message.kind === 'notice' ? 13 : 16).lineHeight(25)
            .fontColor(Palette.ink).copyOption(CopyOptions.LocalDevice).width('100%')
        }
      }.width('100%').padding(14).backgroundColor(this.message.role === 'user' ? Palette.soft : Palette.surface)
        .borderRadius(16).id('message-' + this.message.id)
      }
      if (this.message.delivery) { Text(this.message.delivery).fontSize(11).fontColor(Palette.muted).width('100%').textAlign(TextAlign.End) }
    }.width('100%').padding({ left: this.message.role === 'user' ? 40 : 0, right: this.message.role === 'user' ? 0 : 8 })
  }
}



