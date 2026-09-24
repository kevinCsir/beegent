import { TodoProgress } from '../components/TodoProgress';
import { AttachmentOverlay } from '../components/AttachmentOverlay';
import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { LogStore } from '../diagnostics/LogStore';
import { Palette } from '../config/Palette';
import { SessionInfo } from '../swarm/HistoryClient';
import { common } from '@kit.AbilityKit';
import { AttachmentService } from '../swarm/AttachmentService';
import { Answer, Attachment, TodoItem } from '../swarm/RichMessage';
import { MessageCard } from '../components/MessageCard';
import { DEFAULT_SWARM_IP, DEFAULT_SWARM_PORT, DEFAULT_DOWNLOAD_PORT } from '../config/AppConfig';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { QueuedMessage, SessionMode } from '../swarm/SessionMode';
import { SwarmManager } from '../swarm/SwarmManager';
import { HarmonyTransport } from '../swarm/HarmonyTransport';
import { ChatMessage } from '../swarm/SwarmSession';
import { RunState, ConnectionSettings } from '../swarm/Protocol';
import { MessageSource, MessageView } from '../viewmodel/MessageSource';

@Entry
@Component
struct Index {
  @State todos: TodoItem[] = [];
  @State previewFile: Attachment | undefined = undefined;
  @State previewKind: string = '';
  @State previewSession: string = '';
  private todoKey: string = '';
  private previewOwner: number = 0;
  @State logVisible: boolean = false;
  @State logBusy: boolean = false;
  @State logStatus: string = '';
  @State logFeedback: string = '';
  @State address: string = DEFAULT_SWARM_IP;
  @State webPort: string = '';
  @State downloadPort: string = '';
  @State connection: string = 'closed';
  @State expanded: boolean = false;
  @State sidebar: boolean = false;
  @State remote: SessionInfo[] = [];
  @State listLoading: boolean = false;
  @State listError: string = '';
  @State listMore: boolean = false;
  @State historyLoading: boolean = false;
  @State historyMore: boolean = false;
  @State title: string = 'beegent';
  @State error: string = '';
  @State globalNotice: string = '';
  @State activeId: string = '';
  @State draft: string = '';
  @State runState: RunState = 'idle';
  @State notice: string = '';
  @State creating: boolean = false;
  @State hasMessages: boolean = false;
  @State following: boolean = true;
  @State roleIndex: number = 0;
  @State profileIndex: number = 0;
  @State styleIndex: number = 0;
  @State queue: QueuedMessage[] = [];
  @State queuePaused: boolean = false;
  @State canSupplement: boolean = false;
  @State isAgent: boolean = true;
  private attachments: AttachmentService = new AttachmentService();
  private attachmentBusy: boolean = false;
  private queueKey: string = '';
  private manager: SwarmManager = new SwarmManager(() => new HarmonyTransport());
  private source: MessageSource = new MessageSource();
  private scroller: Scroller = new Scroller();
  private boundSession: string = '';
  private scrollTimer: number = -1;
  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.manager.onChange = (): void => this.sync();
    this.manager.onMessage = (message: ChatMessage): void => {
      this.source.update(message); this.hasMessages = true; this.followOutput();
    };
    this.sync();
  }
  aboutToDisappear(): void {
    if (this.scrollTimer !== -1) { clearTimeout(this.scrollTimer); }
    this.closePreview(); this.todos = []; this.manager.dispose(); this.source.bind([]); this.remote = []; this.queue = []; this.draft = ''; this.queueKey = ''; this.boundSession = '';
  }
  private sync(): void {
    const previousConnection = this.connection;
    this.connection = this.manager.connection.state;
    if (previousConnection === 'open' && this.connection !== 'open') { this.draft = ''; this.address = DEFAULT_SWARM_IP; this.webPort = ''; this.downloadPort = ''; }
    this.creating = this.manager.creating;
    this.error = this.manager.error; this.globalNotice = this.manager.globalNotice;
    const session = this.manager.current();
    if (this.previewFile && (!session || session.viewId !== this.previewOwner)) { this.closePreview(); }
    const todoKey = (session?.viewId || 0).toString() + ':' + (session?.todosVersion || 0).toString();
    if (todoKey !== this.todoKey) { this.todoKey = todoKey; this.todos = session?.todos.slice() || []; }
    const binding = this.manager.endpoint + '|' + (session?.id || '') + '|' + (session?.viewId || 0).toString() + '|' + (session?.historyRevision || 0).toString();
    this.title = session?.title || 'beegent';
    this.historyLoading = session?.historyLoading || false; this.historyMore = !!session?.historyCursor;
    this.remote = this.sidebar && this.connection === 'open' ? this.manager.remoteSessions.slice() : [];
    this.listLoading = this.manager.listLoading; this.listError = this.manager.listError;
    this.listMore = this.remote.length < this.manager.listTotal;
    if (this.boundSession !== binding) {
      const changedSession = !this.boundSession.startsWith(this.manager.endpoint + '|' + (session?.id || '') + '|');
      this.boundSession = binding;
      const hadSession = !!this.activeId;
      this.activeId = session?.id || '';
      this.source.bind(session?.timeline() || []);
      if (session || hadSession) { this.draft = session?.draft || ''; }
      if (changedSession) { this.following = true; }
      this.followOutput();
    }
    this.hasMessages = (session?.timeline().length || 0) > 0;
    this.runState = session?.state || 'idle';
    this.notice = session?.notice || '';
    if (session) { this.draft = session.draft; }
    this.queuePaused = session?.queuePaused || false;
    this.canSupplement = session ? this.manager.canSupplement(session) : false;
    this.isAgent = session?.mode.role !== 'team';
    const queueKey = binding + '|' + (session?.queue || []).map((item: QueuedMessage) => item.id + item.status + item.content + item.error).join('|');
    if (queueKey !== this.queueKey) {
      this.queueKey = queueKey; this.queue = (session?.queue || []).map((item: QueuedMessage) => item.copy());
    }
  }
  private followOutput(): void {
    if (!this.following || this.scrollTimer !== -1) { return; }
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      if (this.following && this.source.totalCount() > 0) { this.scroller.scrollEdge(Edge.Bottom); }
    }, 40);
  }
  private fail(error: Error): void { this.manager.error = error.message || '操作失败'; this.sync(); }
  private async answer(sessionId: string, id: string, answers: Answer[]): Promise<void> {
    try { await this.manager.answer(sessionId, id, answers); } catch (error) { this.fail(error as Error); }
  }
  private closePreview(): void { this.previewFile = undefined; this.previewKind = ''; this.previewSession = ''; this.previewOwner = 0; }
  private async attachment(file: Attachment, action: string): Promise<void> {
    if (action === 'preview' || action === 'render') {
      const session = this.manager.current(); if (!session) { return; }
      this.previewSession = session.id; this.previewOwner = session.viewId;
      this.previewKind = action === 'render' ? 'html' : 'image'; this.previewFile = file;
      CommunicationLog.record('ui.attachment.preview', { sessionId: session.id, fileId: file.id, action: this.previewKind });
      return;
    }
    CommunicationLog.record('ui.attachment.tap', { sessionId: this.activeId, fileId: file.id, name: file.name, action: action, state: this.attachmentBusy ? 'ignored_busy' : 'accepted' });
    if (this.attachmentBusy) { return; }
    const owner = this.manager.current();
    this.attachmentBusy = true; this.manager.error = ''; this.sync();
    this.getUIContext().getPromptAction().showToast({ message: '正在准备附件…' });
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await this.attachments.action(context, file, action, owner?.id || '');
      if (this.manager.current() === owner) { this.getUIContext().getPromptAction().showToast({ message: result }); }
    } catch (error) { if (this.manager.current() === owner) { this.fail(new Error('附件操作未完成：' + (error as Error).message)); } }
    finally { this.attachmentBusy = false; }
  }
  private async openLink(url: string): Promise<void> {
    if (!/^https?:\/\//i.test(url)) { return; }
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).startAbility({ action: 'ohos.want.action.viewData', uri: url }); }
    catch (error) { this.fail(new Error('无法打开此链接：' + (error as Error).message)); }
  }
  private closeSidebar(): void {
    this.sidebar = false; this.remote = []; this.manager.clearList();
  }
  private async connect(): Promise<void> {
    try {
      const settings = new ConnectionSettings(this.address, this.webPort, this.downloadPort);
      await this.manager.connect(settings.endpoint, settings.downloadOrigin);
      this.address = settings.ip; this.webPort = settings.webPort.toString(); this.downloadPort = settings.downloadPort.toString();
      this.expanded = false;
      if (this.sidebar) { this.manager.listSessions(); }
    } catch (error) { this.fail(error as Error); }
  }
  private async create(): Promise<void> {
    if (this.creating) { return; }
    const pendingDraft = this.activeId ? '' : this.draft;
    try {
      await this.manager.create(new SessionMode(this.roleIndex === 0 ? 'agent' : 'team',
        this.profileIndex === 0 ? 'work' : 'code', this.styleIndex === 0 ? 'normal' : 'plan'));
      this.closeSidebar();
      if (pendingDraft.trim()) { this.draft = pendingDraft; this.manager.current()!.draft = pendingDraft; await this.send(); }
    } catch (error) { this.fail(error as Error); }
  }
  private async supplement(id: string): Promise<void> {
    try { await this.manager.supplement(id); } catch (error) { this.fail(error as Error); }
  }
  private editQueued(id: string): void { try { this.manager.editQueued(id); } catch (error) { this.fail(error as Error); } }
  private removeQueued(task: QueuedMessage): void {
    if (task.status !== 'unknown') { this.manager.removeQueued(task.id); return; }
    AlertDialog.show({ title: '移除待确认消息', message: '电脑可能已经收到这条补充。移除只清理手机队列，不会撤回；请勿再次发送相同内容。',
      primaryButton: { value: '保留', action: () => {} },
      secondaryButton: { value: '移除', action: () => this.manager.removeQueued(task.id) } });
  }
  private async send(): Promise<void> {
    const session = this.manager.current();
    if (!this.draft.trim() || this.creating) { return; }
    if (!session) { if (this.connection !== 'open') { this.expanded = true; } else { await this.create(); } return; }
    session.draft = this.draft;
    this.following = true;
    const sending = this.manager.send();
    this.draft = session.draft;
    try { await sending; } catch (error) { this.fail(error as Error); }
  }
  private async stop(): Promise<void> { try { await this.manager.stop(); } catch (error) { this.fail(error as Error); } }
  private busy(): boolean { return this.runState !== 'idle' && this.runState !== 'error'; }
  private status(): string {
    switch (this.runState) {
      case 'sending': return '正在发送';
      case 'running': return '正在处理…';
      case 'stopping': return '正在停止';
      case 'waiting': return '等待你的回复或审批';
      case 'unknown': return '任务状态待确认';
      case 'error': return '本轮未完成';
      default: return '准备就绪';
    }
  }
  private startNew(): void {
    if (this.creating) { return; }
    this.closeSidebar(); this.manager.leaveSession(); this.draft = '';
    this.roleIndex = 0; this.profileIndex = 0; this.styleIndex = 0;
  }
  @Builder
  modeButtons() {
    Row({ space: 8 }) {
      Button(this.roleIndex === 0 ? 'Agent · 单代理' : 'Team · 多代理')
        .layoutWeight(1).height(30).padding({ left: 8, right: 8 }).fontSize(12).fontColor(Palette.ink)
        .backgroundColor(Palette.action(!this.creating)).enabled(!this.creating).borderRadius(15)
        .onClick(() => { this.roleIndex = 1 - this.roleIndex; }).id('mode-role-toggle')
      Button(this.profileIndex === 0 ? 'Work · 通用' : 'Code · 编程')
        .layoutWeight(1).height(30).padding({ left: 8, right: 8 }).fontSize(12).fontColor(Palette.ink)
        .backgroundColor(Palette.action(!this.creating)).enabled(!this.creating).borderRadius(15)
        .onClick(() => { this.profileIndex = 1 - this.profileIndex; }).id('mode-profile-toggle')
      Button(this.styleIndex === 0 ? 'Normal · 直接' : 'Plan · 计划')
        .layoutWeight(1).height(30).padding({ left: 8, right: 8 }).fontSize(12).fontColor(Palette.ink)
        .backgroundColor(Palette.action(!this.creating)).enabled(!this.creating).borderRadius(15)
        .onClick(() => { this.styleIndex = 1 - this.styleIndex; }).id('mode-style-toggle')
    }.width('100%').id('new-session-modes')
  }
  @Builder
  queuePanel() {
    Column({ space: 6 }) {
      Row() {
        Text('消息队列 · ' + this.queue.length.toString() + (this.queuePaused ? ' · 已暂停' : ''))
          .fontSize(12).fontColor(Palette.ink).layoutWeight(1).id('queue-title')
        Button(this.queuePaused ? '恢复队列' : '暂停队列').height(28).fontSize(11)
          .backgroundColor(Palette.honey).fontColor(Palette.ink).id('queue-toggle').onClick(() => this.manager.toggleQueue())
      }
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.queue, (task: QueuedMessage, index: number) => {
            Column({ space: 5 }) {
              Text(task.content).fontSize(13).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%').id('queue-text-' + task.id)
              Text(task.statusLabel() + (task.error ? ' · ' + task.error : '')).fontSize(10).fontColor(Palette.muted).width('100%')
              Row({ space: 6 }) {
                if (this.isAgent) {
                  Button('补充当前任务').height(28).fontSize(11).backgroundColor(Palette.action(this.canSupplement && (task.status === 'queued' || task.status === 'failed'))).fontColor(Palette.ink)
                    .enabled(this.canSupplement && (task.status === 'queued' || task.status === 'failed'))
                    .id('queue-steer-' + task.id).onClick(() => this.supplement(task.id))
                }
                if (task.status === 'failed') {
                  Button('重新排队').height(28).fontSize(11).backgroundColor(Palette.honey).fontColor(Palette.ink)
                    .onClick(() => this.manager.retryQueued(task.id))
                }
                Button('编辑').height(28).fontSize(11).backgroundColor(Palette.action(task.status === 'queued' || task.status === 'failed')).fontColor(Palette.ink)
                  .enabled(task.status === 'queued' || task.status === 'failed').onClick(() => this.editQueued(task.id))
                Button('移除').height(28).fontSize(11).backgroundColor(Palette.action(task.status !== 'sending')).fontColor(Palette.ink)
                  .enabled(task.status !== 'sending').onClick(() => this.removeQueued(task))
                Button('↑').height(28).fontSize(12).backgroundColor(Palette.action(index > 0)).fontColor(Palette.ink).enabled(index > 0)
                  .onClick(() => this.manager.moveQueued(task.id, -1))
              }
            }.width('100%').padding(10).backgroundColor(Palette.surface).borderRadius(10)
          }, (task: QueuedMessage) => task.id + task.status + task.content + task.error)
        }.width('100%')
      }.constraintSize({ maxHeight: 154 }).width('100%').scrollBar(BarState.Auto)
    }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 }).id('queue-panel')
  }

  onBackPress(): boolean {
    if (this.previewFile) { this.closePreview(); return true; }
    if (this.logVisible) { if (!this.logBusy) { this.logVisible = false; } return true; }
    if (this.expanded) { this.expanded = false; return true; }
    if (this.sidebar) { this.closeSidebar(); return true; }
    return false;
  }
  private openSidebar(): void { this.sidebar = true; this.manager.listSessions(); }
  private async openHistory(info: SessionInfo): Promise<void> {
    this.closeSidebar(); 
    try { await this.manager.openSession(info); } catch (error) { this.fail(error as Error); }
  }
  @Builder
  connectionPanel() {
    Column({ space: 20 }) {
      Row() {
        Text('连接你的 Swarm').fontSize(22).fontWeight(FontWeight.Medium).layoutWeight(1)
        Button('×').width(32).height(32).fontSize(22).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => { this.expanded = false; })
      }.width('100%')
      Text('手机与电脑连接同一局域网').fontSize(13).fontColor(Palette.muted).width('100%')
      Text('服务器 IP').fontSize(13).fontColor(Palette.muted).width('100%')
      TextInput({ text: this.address, placeholder: '例如 192.168.43.217' })
        .id('server-address').fontSize(15).fontColor(Palette.ink).backgroundColor(this.connection === 'open' || this.connection === 'connecting' ? Palette.disabled : Palette.background).borderRadius(14).height(52)
        .enabled(this.connection !== 'connecting' && this.connection !== 'open').onChange((value: string) => { this.address = value; })
      Row({ space: 12 }) {
        Column({ space: 8 }) {
          Text('后端端口').fontSize(13).fontColor(Palette.muted).width('100%')
          TextInput({ text: this.webPort, placeholder: '默认 ' + DEFAULT_SWARM_PORT }).type(InputType.Number)
            .id('server-port').height(48).fontSize(15).fontColor(Palette.ink).borderRadius(14)
            .backgroundColor(this.connection === 'open' || this.connection === 'connecting' ? Palette.disabled : Palette.background)
            .enabled(this.connection !== 'connecting' && this.connection !== 'open').onChange((value: string) => { this.webPort = value; })
        }.layoutWeight(1)
        Column({ space: 8 }) {
          Text('下载端口').fontSize(13).fontColor(Palette.muted).width('100%')
          TextInput({ text: this.downloadPort, placeholder: '默认 ' + DEFAULT_DOWNLOAD_PORT }).type(InputType.Number)
            .id('download-port').height(48).fontSize(15).fontColor(Palette.ink).borderRadius(14)
            .backgroundColor(this.connection === 'open' || this.connection === 'connecting' ? Palette.disabled : Palette.background)
            .enabled(this.connection !== 'connecting' && this.connection !== 'open').onChange((value: string) => { this.downloadPort = value; })
        }.layoutWeight(1)
      }.width('100%')
      if (this.error) { Text(this.error).fontSize(13).fontColor(Palette.muted).width('100%') }
      Button(this.connection === 'open' ? '断开连接' : this.connection === 'connecting' ? '正在连接…' : '连接')
        .id('connect-button').height(48).width('100%').fontColor(Palette.ink).backgroundColor(Palette.action(this.connection !== 'connecting'))
        .enabled(this.connection !== 'connecting').onClick(() => {
          if (this.connection === 'open') { this.manager.connection.close(); this.expanded = false; }
          else { this.connect(); }
        })
    }.width('90%').constraintSize({ maxWidth: 440 }).padding(24).backgroundColor(Palette.surface).borderRadius(28)
      .onClick(() => {}).id('connection-dialog')
  }
  @Builder
  sidebarPanel() {
    Column({ space: 16 }) {
      Row() {
        Image($r('app.media.beegent_icon')).width(34).height(34).borderRadius(10)
        Text('beegent').fontSize(22).fontWeight(FontWeight.Medium).layoutWeight(1).margin({ left: 10 })
        Button('×').fontSize(24).width(36).height(36).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => { this.closeSidebar(); })
      }.width('100%')
      Button(this.connection === 'open' ? '● 已连接  ›' : '○ 未连接  ›').alignSelf(ItemAlign.Start)
        .fontSize(13).fontColor(Palette.muted).backgroundColor(Palette.honey).padding({ left: 10, right: 10 })
        .onClick(() => { this.expanded = true; })
      Button('＋  新建会话').width('100%').height(48).fontSize(16).fontColor(Palette.ink).backgroundColor(Palette.action(this.connection === 'open' && !this.creating))
        .border({ width: 1, color: Palette.line }).borderRadius(16).enabled(this.connection === 'open' && !this.creating)
        .onClick(() => { this.closeSidebar(); this.startNew(); }).id('drawer-new-session')
      Row() {
        Text('历史会话').fontSize(12).fontColor(Palette.muted).layoutWeight(1)
        if (this.connection === 'open') {
          Button('刷新').fontSize(12).height(28).fontColor(Palette.ink).backgroundColor(Palette.action(!this.listLoading))
            .enabled(!this.listLoading).onClick(() => this.manager.listSessions())
        }
      }.width('100%')
      if (this.connection !== 'open') {
        Text('连接 Swarm 后查看历史会话').fontSize(14).fontColor(Palette.muted).layoutWeight(1)
      } else {
        List({ space: 8 }) {
          ForEach(this.remote, (info: SessionInfo) => {
            ListItem() {
              Column({ space: 7 }) {
                Text(info.title || '未命名会话').fontSize(15).maxLines(2).width('100%').textOverflow({ overflow: TextOverflow.Ellipsis })
                Text((info.mode || '会话') + ' · ' + (info.message_count || 0).toString() + ' 条消息').fontSize(10).fontColor(Palette.muted).width('100%')
              }.padding(14).width('100%').backgroundColor(this.activeId === info.session_id ? Palette.soft : Color.Transparent).borderRadius(14)
                .onClick(() => this.openHistory(info)).id('remote-session-' + info.session_id)
            }
          }, (info: SessionInfo) => info.session_id + ':' + info.title)
          ListItem() {
            Column({ space: 12 }) {
              if (this.listLoading) { LoadingProgress().width(24).height(24).color(Palette.ink) }
              if (this.listError) { Text(this.listError).fontSize(12).fontColor(Palette.muted) }
              if (!this.listLoading && !this.listError && this.remote.length === 0) { Text('暂无历史会话').fontSize(14).fontColor(Palette.muted).padding(30) }
              if (this.listMore && !this.listLoading) { Button('加载更多').fontSize(13).backgroundColor(Palette.honey).fontColor(Palette.ink).onClick(() => this.manager.listSessions(true)) }
            }.width('100%')
          }
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).id('remote-session-list')
      }
      Button('通信日志').fontSize(13).fontColor(Palette.ink).backgroundColor(Palette.honey).height(34).onClick(() => this.openLogs()).id('communication-logs')
      Text('beegent  ·  随时连接，随处行动').fontSize(11).fontColor(Palette.muted).padding({ top: 16, bottom: 12 })
    }.width('84%').height('100%').padding({ left: 20, right: 20, top: 24, bottom: 12 })
      .backgroundColor(Palette.background).alignItems(HorizontalAlign.Start).onClick(() => {}).id('session-drawer')
  }
  private openLogs(): void {
    this.logStatus = LogStore.summary(); this.logFeedback = LogStore.error; this.logVisible = true;
  }
  private async logAction(clear: boolean): Promise<void> {
    if (this.logBusy) { return; }
    this.logBusy = true; this.logFeedback = '';
    try {
      if (clear) { await LogStore.clear(); this.logFeedback = '日志已清空'; }
      else { this.logFeedback = await LogStore.export(this.getUIContext().getHostContext() as common.UIAbilityContext); }
    } catch (error) { this.logFeedback = '日志操作失败：' + (error as Error).message; }
    finally { this.logBusy = false; this.logStatus = LogStore.summary(); }
  }
  @Builder
  logPanel() {
    Column({ space: 16 }) {
      Row() {
        Text('通信日志').fontSize(21).fontColor(Palette.ink).layoutWeight(1)
        Button('×').padding(0).width(32).height(32).fontSize(22).fontColor(Palette.ink)
          .backgroundColor(Palette.action(!this.logBusy)).enabled(!this.logBusy).onClick(() => { this.logVisible = false; })
      }.width('100%')
      Text('记录消息正文、请求响应、连接变化及附件处理。密钥、下载令牌和二进制内容会脱敏。')
        .fontSize(13).fontColor(Palette.muted).width('100%')
      Text('自动轮换保留最近约 12 MB，可导出为 JSONL。超长消息截断，写入过载会记录丢弃数量。')
        .fontSize(12).fontColor(Palette.muted).width('100%')
      Text(this.logStatus).fontSize(13).fontColor(Palette.ink).width('100%')
      if (this.logFeedback) { Text(this.logFeedback).fontSize(12).fontColor(Palette.muted).width('100%') }
      Row({ space: 10 }) {
        Button('清空日志').fontSize(14).layoutWeight(1).fontColor(Palette.ink).backgroundColor(Palette.action(!this.logBusy))
          .enabled(!this.logBusy).onClick(() => this.logAction(true)).id('clear-logs')
        Button(this.logBusy ? '处理中…' : '导出日志').fontSize(14).layoutWeight(1).fontColor(Palette.ink).backgroundColor(Palette.action(!this.logBusy))
          .enabled(!this.logBusy).onClick(() => this.logAction(false)).id('export-logs')
      }.width('100%')
    }.width('90%').constraintSize({ maxWidth: 440 }).padding(24).backgroundColor(Palette.surface).borderRadius(24).onClick(() => {})
  }
  @Builder
  welcome() {
    Column({ space: 12 }) {
      Text(this.activeId ? '开始这段对话' : '有什么可以帮你？')
        .fontSize(25).fontWeight(FontWeight.Medium).fontColor(Palette.ink)
      Text(this.connection === 'open' ? '输入消息，开始行动' : '连接电脑上的 Swarm，开始对话')
        .fontSize(14).fontColor(Palette.muted)
    }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center).padding({ left: 24, right: 24 })
  }
  @Builder
  composer() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: this.busy() ? '继续输入，发送后排队…' : '发送消息…' })
          .layoutWeight(1).height(44).fontSize(16).fontColor(Palette.ink)
          .backgroundColor(Color.Transparent).borderRadius(22).padding({ left: 14, right: 8 })
          .enterKeyType(EnterKeyType.Send).onSubmit(() => this.send()).id('message-input')
          .onChange((value: string) => { this.draft = value; const session = this.manager.current(); if (session) { session.draft = value; } })
        if (this.busy() && !this.draft.trim()) {
          Button('■').padding(0).width(38).height(38).fontSize(16).fontColor(Palette.ink)
            .backgroundColor(Palette.action(this.connection === 'open' && this.runState !== 'stopping'))
            .enabled(this.connection === 'open' && this.runState !== 'stopping').onClick(() => this.stop()).id('stop-button')
        } else {
          Button(this.creating ? '…' : this.busy() || this.queue.length > 0 || this.queuePaused ? '排队' : '↑')
            .padding(0).width(40).height(38).fontSize(this.busy() ? 12 : 24).fontColor(Palette.ink)
            .backgroundColor(Palette.action(!!this.draft.trim() && !this.historyLoading && !this.creating))
            .enabled(!!this.draft.trim() && !this.historyLoading && !this.creating).onClick(() => this.send()).id('send-button')
        }
      }.width('100%').padding({ right: 4 }).border({ width: 1, color: Palette.line }).borderRadius(24)
        .backgroundColor(Color.Transparent)
      if (!this.activeId) { this.modeButtons() }
    }.padding({ left: 12, right: 12, top: 4, bottom: 8 }).backgroundColor(Color.Transparent)
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row({ space: 10 }) {
          Button({ type: ButtonType.Circle }) {
            Column({ space: 6 }) { Rect().width(21).height(2.5).fill(Palette.ink).radius(2); Rect().width(13).height(2.5).fill(Palette.ink).radius(2) }
              .alignItems(HorizontalAlign.Start)
          }.width(40).height(40).backgroundColor(Palette.honey).onClick(() => this.openSidebar()).id('sidebar-toggle')
          Column({ space: 3 }) {
            Text(this.title).fontColor(Palette.ink).fontSize(20).fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            Text(this.connection === 'open' ? '● 已连接' + (this.busy() ? ' · ' + this.status() : '') + '  ›' : this.connection === 'connecting' ? '◌ 连接中…' : '○ 未连接  ›')
              .fontSize(12).fontColor(Palette.muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => { this.expanded = true; }).id('connection-panel-toggle')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button('+').padding(0).width(36).height(36).fontSize(24).fontColor(Palette.ink).backgroundColor(Palette.action(!this.creating)).enabled(!this.creating).id('new-session')
            .onClick(() => this.startNew())
        }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 }).backgroundColor(Color.Transparent)
        if (this.error && !this.expanded) { Text(this.error).fontSize(12).fontColor(Palette.ink).backgroundColor(Palette.soft).padding(12).width('100%').id('connection-error') }
        if (this.globalNotice) { Text(this.globalNotice).fontSize(11).fontColor(Palette.muted).padding(6).width('100%') }
        if (this.todos.length > 0) { TodoProgress({ items: this.todos, sessionKey: this.activeId }) }
        if (this.historyMore || this.historyLoading) {
          Button(this.historyLoading ? '正在加载…' : '查看更早消息').fontSize(12).height(30).backgroundColor(Palette.action(!this.historyLoading && this.connection === 'open')).fontColor(Palette.ink)
            .enabled(!this.historyLoading && this.connection === 'open').onClick(() => { this.following = false; this.manager.olderHistory(); }).id('load-older')
        }
        if (this.historyLoading && !this.hasMessages) {
          Column({ space: 12 }) { LoadingProgress().width(28).height(28).color(Palette.ink); Text('正在读取会话…').fontSize(14).fontColor(Palette.muted) }
            .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else if (this.hasMessages) {

          Stack({ alignContent: Alignment.BottomEnd }) {
            List({ space: 18, scroller: this.scroller }) {
              LazyForEach(this.source, (message: MessageView) => {
                ListItem() { MessageCard({ message: message, sessionKey: this.activeId,
                  onAnswer: (id: string, answers: Answer[]) => this.answer(this.activeId, id, answers),
                  onAttachment: (file: Attachment, action: string) => this.attachment(file, action),
                  onLink: (url: string) => this.openLink(url) }) }
              }, (message: MessageView) => message.id)
            }.width('100%').height('100%').cachedCount(3).scrollBar(BarState.Auto)
              .padding({ left: 16, right: 12, top: 8, bottom: 8 }).id('message-list')
              .onScrollFrameBegin((offset: number, state: ScrollState) => { if (state !== ScrollState.Idle && offset < 0) { this.following = false; } return { offsetRemain: offset }; })
              .onReachEnd(() => { this.following = true; })
            if (!this.following) { Button('↓').width(36).height(36).fontColor(Palette.ink).backgroundColor(Palette.honey).margin(16).onClick(() => { this.following = true; this.followOutput(); }) }
          }.layoutWeight(1).width('100%')
        } else { this.welcome() }
        if (this.notice) { Text(this.notice).fontSize(12).fontColor(Palette.muted).width('100%').padding({ left: 16, right: 16, bottom: 4 }).id('session-notice') }
        if (this.notice === '历史加载失败，请重试') { Button('重新加载').fontSize(13).fontColor(Palette.ink).backgroundColor(Palette.honey).onClick(() => this.openHistory({ session_id: this.activeId, title: this.title })) }
        if (this.queue.length > 0) { this.queuePanel() }
        this.composer()
      }.width('100%').height('100%')
      if (this.sidebar) {
        Stack({ alignContent: Alignment.Start }) {
          Rect().width('100%').height('100%').fill('#6624231F').onClick(() => { this.closeSidebar(); })
          this.sidebarPanel()
        }.width('100%').height('100%')
      }
      if (this.expanded) {
        Stack({ alignContent: Alignment.Center }) {
          Rect().width('100%').height('100%').fill('#6624231F').onClick(() => { this.expanded = false; })
          this.connectionPanel()
        }.width('100%').height('100%')
      }
      if (this.logVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Rect().width('100%').height('100%').fill('#6624231F').onClick(() => { if (!this.logBusy) { this.logVisible = false; } })
          this.logPanel()
        }.width('100%').height('100%')
      }
      if (this.previewFile) {
        AttachmentOverlay({ file: this.previewFile, kind: this.previewKind, sessionKey: this.previewSession,
          onClose: () => this.closePreview(), onAction: (file: Attachment, action: string) => this.attachment(file, action) })
      }
    }.width('100%').height('100%').backgroundColor(Palette.background)
  }
}



