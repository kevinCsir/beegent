import { HistoryRecord, historyKey } from './HistoryClient';
import { Subagents } from './Subagents';
import { isUsageEvent } from './UsageStore';
import { Frame, Payload, RunState, downloadOriginOf } from './Protocol';
import { SessionMode, QueuedMessage } from './SessionMode';
import { ChatMessage, Interaction, TodoItem, parseTodos } from './RichMessage';
import { RichTimeline } from './RichTimeline';
export { ChatMessage } from './RichMessage';
export class SwarmSession {
  private static serial: number = 0;
  viewId: number = ++SwarmSession.serial;
  id: string;
  endpoint: string;
  downloadOrigin: string;
  title: string;
  todos: TodoItem[] = [];
  todosVersion: number = 0;
  draft: string = '';
  state: RunState = 'idle';
  notice: string = '';
  requestId: string = '';
  stopRequestId: string = '';
  executionId: string = '';
  mode: SessionMode;
  queue: QueuedMessage[] = [];
  queuePaused: boolean = false;
  rich: RichTimeline; subagents: Subagents;
  replyOwners: Set<string> = new Set();
  private retiredPhases: Set<string> = new Set();
  messages: ChatMessage[] = [];
  historyRows: ChatMessage[] = [];
  historyRecords: HistoryRecord[] = [];
  historyCursor: string | null = null;
  historySnapshot: string = ''; historySnapshotEnd: number = 0;
  historyLoading: boolean = false; historyLoaded: boolean = false; historyRevision: number = 0;
  liveRevision: number = 0;
  disposed: boolean = false;
  dispose(): void {
    this.disposed = true; this.onChange = () => {}; this.onMessage = () => {};
    this.rich.cancelDeferredPlans(); this.rich.expire();
    this.replaceIdleTimeline();
    this.historyRows = []; this.historyRecords = []; this.historyCursor = null;
    this.historySnapshot = ''; this.historySnapshotEnd = 0; this.historyLoading = false;
    this.historyLoaded = false; this.draft = ''; this.queue = []; this.queuePaused = false;
    this.title = ''; this.notice = ''; this.state = 'idle'; this.todos = []; this.todosVersion++;
  }
  replaceIdleTimeline(): void {
    this.flush(); this.subagents.flush();
    this.messages = []; this.rows.clear(); this.chunks.clear(); this.seen.clear();
    this.phaseByRequest.clear(); this.retiredPhases.clear(); this.replyOwners.clear();
    this.requestId = ''; this.stopRequestId = ''; this.executionId = '';
    this.rich = new RichTimeline(this.downloadOrigin, (row: ChatMessage) => this.add(row), (row: ChatMessage) => this.onMessage(row));
    this.subagents = new Subagents(this.id, (row: ChatMessage) => this.add(row), (row: ChatMessage) => this.onMessage(row));
  }
  timeline(): ChatMessage[] { return this.historyRows.concat(this.messages); }
  restoreHistory(records: HistoryRecord[]): void {
    const merged = new Map<string, HistoryRecord>();
    records.filter((record: HistoryRecord) => !isUsageEvent(record.event_type || '')).forEach((record: HistoryRecord) => merged.set(historyKey(record), record));
    this.historyRecords = Array.from(merged.values()).sort((a: HistoryRecord, b: HistoryRecord) => (a.timestamp || 0) - (b.timestamp || 0));
    const replay = new SwarmSession(this.id, this.endpoint, this.title, this.mode, this.downloadOrigin);
    const liveRequests = new Set<string>();
    this.messages.forEach((row: ChatMessage) => { if (row.role === 'user') { liveRequests.add(row.id); } if (row.answerId) { liveRequests.add(row.answerId); } });
    let turn = 'history';
    this.historyRecords.forEach((record: HistoryRecord, index: number) => {
      const request = record.request_id || turn;
      if (record.role === 'user' || record.role === 'human') {
        turn = request;
        if (!liveRequests.has(request)) { replay.add(new ChatMessage('history-user-' + index.toString(), 'user', record.content || '')); }
        return;
      }
      if (liveRequests.has(request)) { return; }
      const event = record.event_type || 'chat.final';
      if (['chat.processing_status', 'runtime.accepted', 'chat.output_phase'].includes(event)) { return; }
      const p = JSON.parse(JSON.stringify(record)) as Payload; p.request_id = request; p.session_id = this.id;
      if (event === 'chat.final') { p.segment_id = 'history-' + index.toString(); }
      replay.apply({ type: 'event', event: event, payload: p });
    });
    replay.flush(); replay.subagents.uncertain(); replay.rich.expire();
    replay.messages.forEach((row: ChatMessage) => { row.id = 'history:' + row.id; if (row.kind === 'steps') { row.collapse = true; } });
    this.historyRows = replay.messages; this.historyLoaded = true; this.historyRevision++;
  }
  onChange: () => void = () => {};
  onMessage: (row: ChatMessage) => void = () => {};
  private rows: Map<string, ChatMessage> = new Map();
  private chunks: Map<string, string[]> = new Map();
  private phaseByRequest: Map<string, string> = new Map();
  private seen: Set<string> = new Set();
  private timer: number = -1;
  constructor(id: string, endpoint: string, title: string, mode: SessionMode = new SessionMode(), downloadOrigin: string = '') {
    this.downloadOrigin = downloadOrigin || downloadOriginOf(endpoint);
    this.id = id; this.endpoint = endpoint; this.title = title; this.mode = mode.copy();
    this.subagents = new Subagents(id, (row: ChatMessage) => this.add(row), (row: ChatMessage) => this.onMessage(row));
    this.rich = new RichTimeline(this.downloadOrigin, (row: ChatMessage) => this.add(row), (row: ChatMessage) => this.onMessage(row));
  }
  begin(id: string, content: string): void {
    this.liveRevision++;
    this.replyOwners.clear();
    this.requestId = id; this.stopRequestId = ''; this.executionId = ''; this.state = 'sending'; this.notice = '';
    if (this.messages.length === 0) { this.title = content.slice(0, 22); }
    this.add(new ChatMessage(id, 'user', content, '发送中'));
    this.onChange();
  }
  accepted(id: string): void {
    const row = this.rows.get(id);
    if (row) { row.delivery = this.state === 'idle' ? '' : '已受理'; this.onMessage(row); }
    if (id === this.requestId && this.state === 'sending') { this.state = 'running'; }
    this.onChange();
  }
  failed(id: string, message: string, definitive: boolean): void {
    const row = this.rows.get(id);
    if (row) { row.delivery = definitive ? '发送失败' : '结果待确认'; this.onMessage(row); }
    if (id === this.requestId && this.state !== 'idle') {
      this.state = definitive ? 'error' : 'unknown'; this.notice = message;
    }
    this.flush(); this.onChange();
  }
  disconnected(): void {
    this.rich.cancelDeferredPlans(); this.subagents.uncertain();
    this.flush();
    if (this.queue.length > 0) { this.queuePaused = true; }
    if (this.state !== 'idle' && this.state !== 'error') {
      this.state = 'unknown';
      this.notice = '连接中断，电脑上的任务可能仍在运行。重连不会补齐遗漏消息，请在电脑端核实，或停止后继续。';
    }
    this.onChange();
  }
  apply(frame: Frame): void {
    if (this.disposed || isUsageEvent(frame.event || '')) { return; }
    const payload = frame.payload || {};
    const event = frame.event || '';
    const request = payload.turn_request_id || payload.request_id || this.requestId;
    // De-duplicate only when the server supplies a stable sequence. Never dedup by text.
    if (typeof frame.seq === 'number') {
      const key = (frame.stream_id || request) + ':' + frame.seq.toString() + ':' + event;
      if (this.seen.has(key)) { return; }
      if (this.seen.size >= 2048) { this.seen.clear(); }
      this.seen.add(key);
    }
    if (event === 'todo.updated' || event === 'todo.update') {
      // Session snapshots may carry a history request ID, not the current execution ID.
      // A child agent's private todo list must never replace the parent task list.
      if (payload.subagent_id || (payload.parent_session_id && payload.session_id !== this.id)) { return; }
      if (Array.isArray(payload.todos)) { this.todos = parseTodos(payload.todos); this.todosVersion++; this.onChange(); }
      return;
    }
    this.liveRevision++;
    if (this.subagents.apply(event, payload)) { return; }
    if (this.rich.apply(frame, request)) {
      if (event === 'chat.ask_user_question' || event === 'plan.approval_required') {
        this.flush(); this.state = 'waiting'; this.notice = '请在对话中的确认卡片上回复';
      }
      this.onChange(); return;
    }
    if (event === 'chat.input_received' && payload.input_request_id && typeof payload.content === 'string') {
      if (this.rows.has(payload.input_request_id)) { return; }
      this.flush();
      const phase = this.phaseByRequest.get(request);
      if (phase) { this.retiredPhases.add(request + ':' + phase); }
      this.phaseByRequest.set(request, 'after-' + payload.input_request_id);
      this.add(new ChatMessage(payload.input_request_id, 'user', payload.content, '已补充'));
      this.onChange(); return;
    }
    if (event === 'chat.output_phase') {
      if (payload.output_phase_id) {
        const old = this.phaseByRequest.get(request);
        if (old && old !== payload.output_phase_id) { this.retiredPhases.add(request + ':' + old); }
        this.phaseByRequest.set(request, payload.output_phase_id);
      }
      if (request === this.requestId && payload.execution_id) { this.executionId = payload.execution_id; this.onChange(); }
      return;
    }
    if (event === 'chat.delta' || event === 'chat.final') {
      if (payload.role && payload.role !== 'assistant') { return; }
      const text = typeof payload.content === 'string' ? payload.content : '';
      if (!text) { return; } // A terminal empty final must not erase an earlier segment.
      const phase = payload.segment_id || payload.output_phase_id || this.phaseByRequest.get(request) || 'default';
      if (payload.output_suppressed || (payload.output_phase_id && this.retiredPhases.has(request + ':' + payload.output_phase_id))) { return; }
      this.rich.body(request);
      const key = request + ':' + phase + this.rich.segment(request);
      if (!this.rows.has(key)) { const row = new ChatMessage(key, 'assistant', ''); row.answerId = request; this.add(row); }
      if (event === 'chat.delta') {
        let chunks = this.chunks.get(key);
        if (!chunks) { chunks = []; this.chunks.set(key, chunks); }
        chunks.push(text); this.schedule();
      } else {
        this.flush();
        const row = this.rows.get(key);
        if (row) { row.text = text; this.onMessage(row); }
        this.onChange();
      }
      return;
    }
    // Lifecycle events from an older request may not settle a newly started turn.
    if (request && this.requestId && request !== this.requestId && request !== this.stopRequestId && !this.replyOwners.has(request)) { this.rich.fallback(frame, request); return; }
    if (payload.execution_id && request === this.requestId) { this.executionId = payload.execution_id; }
    if (event === 'chat.processing_status' && typeof payload.is_processing === 'boolean') {
      if (payload.is_processing) {
        if (this.state !== 'stopping') { this.state = this.rich.hasPending() ? 'waiting' : 'running'; this.notice = ''; }
      } else {
        this.flush();
        this.rich.ended(request);
        // Interactive waits stay visible even if the server releases its execution slot.
        if (this.state !== 'waiting') { this.state = 'idle'; this.notice = ''; this.executionId = ''; }
        const row = this.rows.get(this.requestId);
        if (row) { row.delivery = ''; this.onMessage(row); }
      }
    } else if (event === 'runtime.accepted') {
      this.accepted(this.requestId); return;
    } else if (event === 'chat.interrupt_result') {
      if (payload.success === false) { this.state = 'unknown'; this.notice = payload.message || '停止未成功，请在电脑端确认'; }
      else if (payload.success === true || payload.has_active_task === false) {
        this.state = 'idle'; this.executionId = ''; this.notice = '已停止'; this.rich.expire(); this.subagents.uncertain(); this.flush();
      }
    } else if (event === 'chat.error' || event === 'execution.error') {
      this.state = 'error'; this.queuePaused = true; this.executionId = ''; this.notice = payload.message || payload.error || payload.content || '任务执行失败'; this.rich.expire(); this.subagents.uncertain(); this.flush();
    } else if (event === 'plan.mode_exited') {
      this.mode.style = 'normal';
    } else if (event === 'chat.ask_user_question' || event === 'plan.approval_required') {
      this.state = 'waiting'; this.notice = '需要在电脑端处理确认或审批。也可以停止当前任务。'; this.flush();
    } else if (event === 'chat.file' || event === 'chat.media') {
      this.notice = '收到文件或媒体，当前版本请在电脑端查看。';
    } else if (event === 'chat.notice') {
      this.notice = payload.content || payload.message || '';
    } else { this.rich.fallback(frame, request); }
    this.onChange();
  }
  flush(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.chunks.size === 0) { return; }
    this.chunks.forEach((chunks: string[], key: string) => {
      const row = this.rows.get(key);
      if (row) { row.text += chunks.join(''); this.onMessage(row); }
    });
    this.chunks.clear(); this.onChange();
  }
  private schedule(): void {
    if (this.timer !== -1) { return; }
    this.timer = setTimeout(() => { this.timer = -1; this.flush(); }, 40);
  }
  private add(row: ChatMessage): void { this.rows.set(row.id, row); this.messages.push(row); this.onMessage(row); }
}


