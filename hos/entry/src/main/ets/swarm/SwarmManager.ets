import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { HistoryClient, SessionInfo, SessionList } from './HistoryClient';
import { isUsageEvent } from './UsageStore';
import { Answer, Interaction } from './RichMessage';
import { interactionReply } from './InteractionReply';
import { ConnectionState, Frame, Payload, RequestFailure, Transport, endpointOf, downloadOriginOf, requestId } from './Protocol';
import { SwarmConnection } from './SwarmConnection';
import { ChatMessage, SwarmSession } from './SwarmSession';
import { QueuedMessage, SessionMode } from './SessionMode';
export class SwarmManager {
  connection: SwarmConnection;
  history: HistoryClient;
  remoteSessions: SessionInfo[] = []; listLoading: boolean = false; listTotal: number = 0;
  listError: string = ''; private connectionEpoch: number = 0; private listGeneration: number = 0;
  endpoint: string = '';
  downloadOrigin: string = '';
  activeId: string = '';
  creating: boolean = false;
  error: string = '';
  globalNotice: string = '';
  globalTaskState?: Payload;
  sessions: SwarmSession[] = [];
  onChange: () => void = () => {};
  onMessage: (row: ChatMessage) => void = () => {};
  private byId: Map<string, SwarmSession> = new Map();
  private requests: Map<string, SwarmSession> = new Map();
  private supplements: Map<string, QueuedMessage> = new Map();
  private stopTimers: Map<string, number> = new Map();
  constructor(factory: () => Transport) {
    this.connection = new SwarmConnection(factory); this.history = new HistoryClient(this.connection);
    this.connection.onState = (state: ConnectionState, reason: string): void => {
      if (state === 'closed' || state === 'error') {
        this.connectionEpoch++; this.history.cancel(); this.clearList(); this.clearSession(); this.globalTaskState = undefined; this.globalNotice = '';
        this.stopTimers.forEach((timer: number) => clearTimeout(timer)); this.stopTimers.clear();
        this.error = reason;
      }
      this.onChange();
    };
    this.connection.onProtocolError = (reason: string): void => { this.error = reason; this.onChange(); };
    this.connection.onEvent = (frame: Frame): void => {
      if (this.history.accept(frame)) { CommunicationLog.record('message.route', { event: frame.event, sessionId: frame.payload?.session_id, target: 'history' }); return; }
      const payload = frame.payload || {};
      if (frame.event === 'task.global_running') { this.globalTaskState = payload; return; }
      let session: SwarmSession | undefined;
      if (payload.session_id || payload.parent_session_id) { session = this.byId.get(this.endpoint + '|' + (payload.parent_session_id || payload.session_id)); }
      else if (payload.request_id) { session = this.requests.get(payload.request_id); }
      if (isUsageEvent(frame.event || '')) { return; }
      CommunicationLog.record('message.route', { event: frame.event, requestId: payload.request_id, sessionId: payload.session_id || payload.parent_session_id, target: session ? 'current_session' : 'unloaded_or_global', state: session?.state });
      if (!session || session.endpoint !== this.endpoint) {
        if (payload.session_id || payload.parent_session_id || payload.request_id) { return; }
        // These aggregate notifications do not own a session or indicate an error.
        if (!['task.global_running', 'connected', 'heartbeat', 'pong'].includes(frame.event || '')) {
          this.globalNotice = '收到服务通知：' + (frame.event || '未知事件'); this.onChange();
        }
        return;
      }
      const inputId = frame.event === 'chat.input_received' ? payload.input_request_id : payload.request_id;
      const candidate = this.supplements.get(inputId || '');
      const supplement = candidate?.requestId === inputId ? candidate : undefined;
      if (supplement) {
        if (frame.event === 'runtime.accepted' || frame.event === 'chat.input_received') {
          this.acceptSupplement(session, supplement);
        } else if (frame.event === 'chat.error') {
          this.failSupplement(session, supplement, payload.error || payload.message || '补充失败', payload.code !== 'SESSION_INPUT_DELIVERY_UNKNOWN');
        }
        // Supplemental ACK/errors/completion never own the original task lifecycle.
        if (frame.event !== 'chat.input_received') { this.drain(session); return; }
      }
      session.apply(frame);
      CommunicationLog.record('message.applied', { event: frame.event, requestId: payload.request_id, sessionId: session.id, state: session.state, count: session.messages.length });
      if (frame.event === 'chat.error' || frame.event === 'execution.error') {
        session.rich.interactions.forEach((row: ChatMessage) => {
          if (row.interaction && row.interaction.replyId === payload.request_id) {
            row.interaction.status = 'failed'; row.interaction.error = payload.message || payload.error || '回复未完成';
            row.interaction.executePlan = false; session!.rich.changed(row);
          }
        });
      }
      this.continuePlan(session);
      if (session.state !== 'stopping') { this.clearStopTimer(session.id); }
      if (frame.event === 'chat.processing_status' && payload.is_processing === false) { this.drain(session); }
    };
  }
  clearList(): void {
    this.listGeneration++; this.remoteSessions = []; this.listTotal = 0; this.listLoading = false; this.listError = '';
    this.onChange();
  }
  private clearSession(): void {
    this.history.abandon();
    this.stopTimers.forEach((timer: number) => clearTimeout(timer)); this.stopTimers.clear();
    this.sessions.forEach((session: SwarmSession) => session.dispose());
    this.sessions = []; this.byId.clear(); this.requests.clear(); this.supplements.clear(); this.activeId = '';
  }
  async listSessions(more: boolean = false): Promise<void> {
    if (this.connection.state !== 'open' || this.listLoading) { return; }
    const epoch = this.connectionEpoch;
    const listGeneration = this.listGeneration;
    const offset = more ? this.remoteSessions.length : 0;
    this.listLoading = true; this.listError = ''; this.onChange();
    try {
      const result = await this.connection.request('session.list', { limit: 30, offset: offset }) as Object as SessionList;
      if (epoch !== this.connectionEpoch || listGeneration !== this.listGeneration || this.connection.state !== 'open') { return; }
      if (!Array.isArray(result.sessions)) { throw new Error('会话列表格式无效'); }
      const next = more ? this.remoteSessions.slice() : [];
      result.sessions.forEach((info: SessionInfo) => {
        if (info.session_id && !next.some((item: SessionInfo) => item.session_id === info.session_id)) { next.push(info); }
      });
      this.remoteSessions = next; this.listTotal = result.total ?? next.length;
    } catch (error) { if (epoch === this.connectionEpoch && listGeneration === this.listGeneration) { this.listError = (error as Error).message; } }
    finally { if (epoch === this.connectionEpoch && listGeneration === this.listGeneration) { this.listLoading = false; this.onChange(); } }
  }
  async openSession(info: SessionInfo): Promise<void> {
    if (this.connection.state !== 'open') { throw new Error('请先连接电脑'); }
    this.clearSession();
    let session: SwarmSession | undefined;
    if (!session) {
      const mode = (info.mode || '').toLowerCase();
      session = new SwarmSession(info.session_id, this.endpoint, info.title || '未命名会话',
        new SessionMode(mode.startsWith('team') ? 'team' : 'agent', mode.includes('.code.') || info.work_mode === 'code' ? 'code' : 'work', mode.endsWith('.plan') ? 'plan' : 'normal'), this.downloadOrigin);
      const bound = session;
      session.onChange = (): void => this.onChange();
      session.onMessage = (row: ChatMessage): void => { if (this.current() === bound) { this.onMessage(row); } };
      this.byId.set(this.endpoint + '|' + info.session_id, session); this.sessions.push(session);
    }
    this.select(session.id);
    await this.loadHistory(session, false);
  }
  async olderHistory(): Promise<void> {
    const session = this.current(); if (session?.historyCursor) { await this.loadHistory(session, true); }
  }
  private async loadHistory(session: SwarmSession, older: boolean): Promise<void> {
    if (session.historyLoading || this.connection.state !== 'open') { return; }
    const epoch = this.connectionEpoch; const liveRevision = session.liveRevision;
    session.historyLoading = true; this.error = ''; this.onChange();
    try {
      // Metadata and history both come from this connection; reject late results after disconnect/switch.
      const metadata = await this.connection.request('session.get_metadata', { session_id: session.id }) as Object as SessionInfo;
      if (session.disposed || epoch !== this.connectionEpoch || session.endpoint !== this.endpoint) { return; }
      const page = await this.history.fetch(session.id, older ? session.historyCursor : null);
      if (session.disposed || epoch !== this.connectionEpoch || session.endpoint !== this.endpoint) { return; }
      if (older && (page.snapshot !== session.historySnapshot || page.snapshotEnd !== session.historySnapshotEnd)) { throw new Error('后端历史已变化，请重新打开会话'); }
      if (!older && !metadata.is_processing && session.liveRevision === liveRevision && !session.rich.hasPending()
        && ['idle', 'error', 'unknown'].includes(session.state)) { session.replaceIdleTimeline(); }
      session.historyCursor = page.nextCursor; session.historySnapshot = page.snapshot; session.historySnapshotEnd = page.snapshotEnd;
      session.restoreHistory(older ? page.records.concat(session.historyRecords) : page.records);
      session.title = metadata.title || session.title;
      if (!session.requestId) {
        const mode = metadata.mode || session.mode.wire();
        session.mode = new SessionMode(mode.startsWith('team') ? 'team' : 'agent', mode.includes('.code.') || metadata.work_mode === 'code' ? 'code' : 'work', mode.endsWith('.plan') ? 'plan' : 'normal');
        session.state = metadata.is_processing ? 'unknown' : 'idle';
        session.notice = metadata.is_processing ? '此会话正在其他客户端执行，可停止或稍后重新打开查看结果' : '';
      }
    } catch (error) {
      if (!session.disposed && epoch === this.connectionEpoch) { this.error = (error as Error).message; if (!session.historyLoaded) { session.notice = '历史加载失败，请重试'; } }
    } finally { session.historyLoading = false; if (!session.disposed && epoch === this.connectionEpoch) { this.onChange(); } }
  }
  leaveSession(): void { this.clearSession(); this.error = ''; this.globalNotice = ''; this.onChange(); }
  visibleSessions(): SwarmSession[] { return this.sessions.filter((session: SwarmSession) => session.endpoint === this.endpoint); }
  current(): SwarmSession | undefined { return this.byId.get(this.endpoint + '|' + this.activeId); }
  async connect(input: string, downloadOrigin: string = ''): Promise<void> {
    const endpoint = endpointOf(input);
    const origin = downloadOrigin || downloadOriginOf(endpoint);
    if (endpoint !== this.endpoint || origin !== this.downloadOrigin) {
      if (this.connection.state === 'connecting') { throw new Error('正在连接，请稍后再切换地址'); }
      this.connection.close(); this.clearSession(); this.endpoint = endpoint; this.downloadOrigin = origin;
    }
    this.error = ''; this.globalNotice = ''; this.globalTaskState = undefined;
    await this.connection.connect(endpoint); this.onChange();
  }
  async create(mode: SessionMode = new SessionMode()): Promise<void> {
    if (this.creating) { return; }
    if (this.connection.state !== 'open') { throw new Error('请先连接电脑'); }
    const selected = mode.copy();
    const endpoint = this.endpoint; const epoch = this.connectionEpoch;
    this.creating = true; this.error = ''; this.onChange();
    try {
      const payload = await this.connection.request('session.create', { mode: selected.wire(), work_mode: selected.profile, create_token: requestId() });
      const id = payload.session_id || payload.sessionId;
      if (!id || typeof id !== 'string') { throw new Error('服务端未返回会话 ID'); }
      if (endpoint !== this.endpoint || epoch !== this.connectionEpoch) { throw new Error('连接已切换'); }
      this.clearSession();
      const session = new SwarmSession(id, endpoint, '新对话', selected, this.downloadOrigin);
      session.onChange = (): void => this.onChange();
      session.onMessage = (row: ChatMessage): void => { if (this.current() === session) { this.onMessage(row); } };
      this.byId.set(endpoint + '|' + id, session); this.sessions.push(session); this.activeId = id;
    } finally { this.creating = false; this.onChange(); }
  }
  select(id: string): void { if (!this.byId.has(this.endpoint + '|' + id)) { return; } this.activeId = id; this.onChange(); }
  async send(): Promise<void> {
    const session = this.current();
    if (!session || !session.draft.trim()) { return; }
    if (session.historyLoading || !session.historyLoaded && session.notice === '历史加载失败，请重试') { throw new Error('请先完成历史加载'); }
    if (this.connection.state !== 'open') { throw new Error('请先连接电脑'); }
    const content = session.draft.trim(); session.draft = '';
    if (session.state !== 'idle' && session.state !== 'error' || session.queue.length > 0 || session.queuePaused) {
      session.queue.push(new QueuedMessage(requestId(), content)); this.onChange(); this.drain(session); return;
    }
    await this.sendContent(session, content);
  }
  private async sendContent(session: SwarmSession, content: string): Promise<void> {
    if (session.disposed || this.current() !== session) { return; }
    const id = requestId();
    this.requests.set(id, session); session.begin(id, content);
    try {
      await this.connection.request('chat.send', { session_id: session.id, mode: session.mode.wire(), work_mode: session.mode.profile, content: content }, id);
      if (!session.disposed) { session.accepted(id); }
    } catch (error) {
      if (session.disposed) { return; }
      const failure = error as RequestFailure;
      session.queuePaused = true;
      session.failed(id, failure.message, failure.definitive === true);
    }
  }
  async answer(sessionId: string, questionId: string, answers: Answer[]): Promise<void> {
    const session = this.byId.get(this.endpoint + '|' + sessionId);
    const row = session?.rich.interactions.get(questionId);
    const interaction = row?.interaction;
    if (!session || !row || !interaction || !['pending', 'failed'].includes(interaction.status)) { throw new Error('此确认已提交或已失效'); }
    if (this.connection.state !== 'open') { throw new Error('请先连接电脑'); }
    const reply = interactionReply(session.id, session.mode.wire(), interaction, answers);
    const rid = requestId(); interaction.replyId = rid; interaction.status = 'sending'; interaction.error = ''; interaction.ended = false;
    interaction.previousMode = session.mode.style;
    interaction.executePlan = interaction.planKind === 'plan_approval' && answers.some((a: Answer) => a.selected_options.includes('plan_execute'));
    this.requests.set(rid, session); session.replyOwners.add(rid); session.rich.changed(row); this.onChange();
    try {
      await this.connection.request(reply.method, reply.params, rid, reply.runtime);
      if (session.disposed || interaction.status !== 'sending') { return; }
      interaction.status = 'submitted';
      if (interaction.executePlan) { session.mode.style = 'normal'; }
      if (session.rich.hasPending()) { session.state = 'waiting'; }
      else { session.state = interaction.ended ? 'idle' : 'running'; session.notice = ''; }
      session.rich.changed(row); this.onChange(); this.continuePlan(session); this.drain(session);
    } catch (error) {
      if (session.disposed || interaction.status === 'expired') { return; }
      const failure = error as RequestFailure;
      interaction.status = failure.definitive ? 'failed' : 'unknown'; interaction.error = failure.message;
      interaction.executePlan = false; session.queuePaused = true;
      session.state = failure.definitive ? 'waiting' : 'unknown';
      session.notice = failure.definitive ? '回复失败，可在卡片上重试' : '回复是否送达尚不确定，请在电脑端核实，避免重复审批';
      session.rich.changed(row); this.onChange();
    }
  }
  private continuePlan(session: SwarmSession): void {
    if (session.disposed || session.rich.hasPending() || this.connection.state !== 'open' || session.state === 'stopping') { return; }
    session.rich.interactions.forEach((row: ChatMessage) => {
      const value = row.interaction;
      if (value?.executePlan && value.status === 'submitted' && value.ended) {
        value.executePlan = false; session.mode.style = 'normal'; session.state = 'idle';
        this.sendContent(session, '请执行已批准的计划。');
      }
    });
  }
  private drain(session: SwarmSession): void {
    if (session.disposed || this.current() !== session || session.endpoint !== this.endpoint || this.connection.state !== 'open' || session.state !== 'idle' || session.queuePaused || session.rich.hasPending()) { return; }
    if (session.queue.some((task: QueuedMessage) => task.status !== 'queued')) { return; }
    const next = session.queue.shift();
    if (next) { this.sendContent(session, next.content); }
  }
  toggleQueue(): void {
    const session = this.current(); if (!session) { return; }
    session.queuePaused = !session.queuePaused;
    if (!session.queuePaused && session.state === 'error') { session.state = 'idle'; }
    this.onChange(); this.drain(session);
  }
  removeQueued(id: string): void {
    const session = this.current(); if (!session) { return; }
    const task = session.queue.find((item: QueuedMessage) => item.id === id);
    if (!task || task.status === 'sending') { return; }
    session.queue = session.queue.filter((item: QueuedMessage) => item.id !== id);
    this.onChange(); this.drain(session);
  }
  editQueued(id: string): void {
    const session = this.current(); if (!session) { return; }
    const task = session.queue.find((item: QueuedMessage) => item.id === id);
    if (!task || task.status === 'sending' || task.status === 'unknown') { return; }
    if (session.draft.trim()) { throw new Error('请先发送或清空输入框中的草稿'); }
    session.draft = task.content;
    session.queue = session.queue.filter((item: QueuedMessage) => item.id !== id); this.onChange();
  }
  moveQueued(id: string, offset: number): void {
    const session = this.current(); if (!session) { return; }
    const index = session.queue.findIndex((item: QueuedMessage) => item.id === id);
    const next = index + offset;
    if (index < 0 || next < 0 || next >= session.queue.length || session.queue[index].status === 'sending' || session.queue[next].status === 'sending') { return; }
    const task = session.queue[index]; session.queue[index] = session.queue[next]; session.queue[next] = task; this.onChange();
  }
  retryQueued(id: string): void {
    const session = this.current(); if (!session) { return; }
    const task = session.queue.find((item: QueuedMessage) => item.id === id);
    if (!task || task.status !== 'failed') { return; }
    task.status = 'queued'; task.error = ''; this.onChange(); this.drain(session);
  }
  canSupplement(session: SwarmSession): boolean {
    return this.connection.state === 'open' && session.mode.role === 'agent' && session.state === 'running' && !!session.executionId;
  }
  async supplement(id: string): Promise<void> {
    const session = this.current();
    if (!session || !this.canSupplement(session)) { throw new Error('当前执行暂不支持补充，请保留在队列中'); }
    const task = session.queue.find((item: QueuedMessage) => item.id === id);
    if (!task || (task.status !== 'queued' && task.status !== 'failed')) { return; }
    const rid = requestId(); task.requestId = rid; task.status = 'sending'; task.error = '';
    this.requests.set(rid, session); this.supplements.set(rid, task); this.onChange();
    try {
      await this.connection.request('chat.send', {
        session_id: session.id, mode: session.mode.wire(), work_mode: session.mode.profile,
        content: task.content, input_mode: 'steer', expected_execution_id: session.executionId
      }, rid, true);
      this.acceptSupplement(session, task);
    } catch (error) {
      const failure = error as RequestFailure;
      this.failSupplement(session, task, failure.message, failure.definitive === true);
    }
    this.drain(session);
  }
  private acceptSupplement(session: SwarmSession, task: QueuedMessage): void {
    if (session.disposed) { return; }
    task.status = 'accepted'; task.error = '';
    session.queue = session.queue.filter((item: QueuedMessage) => item.id !== task.id);
    this.onChange();
  }
  private failSupplement(session: SwarmSession, task: QueuedMessage, message: string, definitive: boolean): void {
    if (session.disposed || task.status === 'accepted') { return; }
    task.status = definitive ? 'failed' : 'unknown'; task.error = message;
    session.queuePaused = true; this.onChange();
  }
  async stop(): Promise<void> {
    const session = this.current();
    if (!session || this.connection.state !== 'open' || session.state === 'stopping') { return; }
    session.queuePaused = true;
    session.rich.cancelDeferredPlans();
    const stopId = requestId();
    session.stopRequestId = stopId; this.requests.set(stopId, session);
    session.state = 'stopping'; session.notice = '正在请求停止…'; this.onChange();
    this.clearStopTimer(session.id);
    this.stopTimers.set(session.id, setTimeout(() => {
      this.stopTimers.delete(session.id);
      if (session.state === 'stopping' && session.stopRequestId === stopId) {
        session.state = 'unknown'; session.notice = '尚未收到停止确认，请在电脑端核实。'; this.onChange();
      }
    }, 30000));
    try {
      await this.connection.request('chat.interrupt', { session_id: session.id, mode: session.mode.wire(), work_mode: session.mode.profile, intent: 'cancel' }, stopId);
    } catch (error) {
      if (session.disposed) { return; }
      this.clearStopTimer(session.id);
      session.state = 'unknown'; session.notice = (error as Error).message; this.onChange();
    }
  }
  private clearStopTimer(id: string): void {
    const timer = this.stopTimers.get(id);
    if (timer !== undefined) { clearTimeout(timer); this.stopTimers.delete(id); }
  }
  dispose(): void { this.onMessage = () => {}; this.onChange = () => {}; this.connection.close(); this.sessions.forEach((session: SwarmSession) => session.flush()); }
}



