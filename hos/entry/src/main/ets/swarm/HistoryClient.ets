import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { isUsageEvent } from './UsageStore';
import { Frame, Params, Payload, requestId } from './Protocol';
import { SwarmConnection } from './SwarmConnection';
export interface SessionInfo {
  session_id: string; title?: string; mode?: string; work_mode?: string;
  last_message_at?: number; message_count?: number; is_processing?: boolean;
  execution_id?: string; execution_blocked?: boolean; stop_pending?: boolean;
}
export interface SessionList { sessions?: SessionInfo[]; total?: number; }
export interface HistoryPart { record_id: string; part_idx: number; total_parts: number; }
export interface HistoryRecord extends Payload { timestamp?: number; _part?: HistoryPart; reasoning_content?: string; }
interface HistoryEnvelope {
  session_id?: string; subagent_id?: string; request_id?: string; cursor?: string | null;
  message?: HistoryRecord | string; content?: string; status?: string; error?: string; code?: string;
  next_cursor?: string | null; has_more?: boolean | null; snapshot_id?: string | null; snapshot_end?: number;
  page_idx?: number | null; total_pages?: number | null;
}
type HistoryProtocol = 'cursor' | 'page';
type HistoryMode = 'auto' | HistoryProtocol;
// Kept only in session memory. UI treats this as an opaque "load older" position.
// Page numbers never masquerade as server-issued cursors.
export interface HistoryContinuation {
  protocol: HistoryProtocol; cursor?: string; pageIdx?: number; totalPages?: number;
}
export class HistoryPage {
  records: HistoryRecord[] = []; nextCursor: HistoryContinuation | null = null;
  snapshot: string = ''; snapshotEnd: number = 0;
}
class HistoryPending {
  session: string; request: string; cursor: string | null; page: HistoryPage = new HistoryPage();
  mode: HistoryMode; pageIdx: number; totalPages?: number;
  abandoned: boolean = false; waiters: Array<() => void> = [];
  parts: Map<string, Map<number, HistoryRecord>> = new Map();
  resolve: (page: HistoryPage) => void; reject: (error: Error) => void; timer: number = -1;
  constructor(session: string, request: string, mode: HistoryMode, continuation: HistoryContinuation | null,
    resolve: (page: HistoryPage) => void, reject: (error: Error) => void) {
    this.session = session; this.request = request; this.mode = mode;
    this.cursor = continuation?.cursor ?? null; this.pageIdx = continuation?.pageIdx ?? 1;
    this.totalPages = continuation?.totalPages; this.resolve = resolve; this.reject = reject;
  }
}
export class HistoryClient {
  private pending: Map<string, HistoryPending> = new Map();
  private connection: SwarmConnection;
  private mode: HistoryMode = 'auto';
  private epoch: number = 0;
  constructor(connection: SwarmConnection) { this.connection = connection; }
  async fetch(session: string, continuation: HistoryContinuation | null = null): Promise<HistoryPage> {
    const epoch = this.epoch;
    const previous = this.pending.get(session);
    // Frames carry session/cursor, but older servers omit request IDs. Drain an abandoned
    // response before requesting the same session again, so old frames cannot cross over.
    if (previous?.abandoned) { await new Promise<void>((resolve) => { previous.waiters.push(resolve); }); }
    if (epoch !== this.epoch || this.connection.state !== 'open') { throw new Error('连接已断开，历史加载已取消'); }
    if (this.pending.has(session)) { return Promise.reject(new Error('正在加载此会话')); }
    const mode: HistoryMode = continuation?.protocol || this.mode;
    if (continuation) {
      if (this.mode !== 'auto' && mode !== this.mode) { throw new Error('历史分页协议已变化，请重新打开会话'); }
      if (mode === 'cursor' && !continuation.cursor) { throw new Error('历史游标无效，请重新打开会话'); }
      if (mode === 'page' && (typeof continuation.pageIdx !== 'number'
        || !Number.isSafeInteger(continuation.pageIdx) || continuation.pageIdx < 2)) {
        throw new Error('历史页码无效，请重新打开会话');
      }
    }
    const rid = requestId();
    return new Promise<HistoryPage>((resolve, reject) => {
      const pending = new HistoryPending(session, rid, mode, continuation, resolve, reject);
      const params: Params = { session_id: session };
      // Old servers ignore cursor; new servers prefer it when present. The first
      // request works with either. Only a valid completed page identifies the mode.
      if (mode !== 'page') { params.cursor = pending.cursor; params.limit = 50; }
      if (mode !== 'cursor') { params.page_idx = pending.pageIdx; }
      pending.timer = setTimeout(() => this.fail(pending, new Error('历史加载超时，请重试')), 30000);
      this.pending.set(session, pending);
      this.connection.request('history.get', params, rid)
        .catch((error: Error) => this.fail(pending, error));
    });
  }
  private fail(pending: HistoryPending, error: Error): void {
    if (this.pending.get(pending.session) !== pending) { return; }
    CommunicationLog.record('history.failed', { sessionId: pending.session, requestId: pending.request, state: pending.mode, error: error.message }, 'warn');
    clearTimeout(pending.timer); this.pending.delete(pending.session); pending.reject(error); pending.waiters.forEach((resolve: () => void) => resolve()); pending.waiters = [];
  }
  abandon(): void {
    this.pending.forEach((pending: HistoryPending) => {
      pending.abandoned = true; pending.page.records = []; pending.parts.clear();
    });
  }
  cancel(): void {
    this.epoch++; this.mode = 'auto';
    this.pending.forEach((pending: HistoryPending) => this.fail(pending, new Error('连接已断开，历史加载已取消')));
  }
  private matches(p: HistoryEnvelope, pending: HistoryPending): boolean {
    if (p.subagent_id || (p.request_id && p.request_id !== pending.request)) { return false; }
    // Legacy frames omit cursor entirely (some versions emit null). Page fields
    // can be null on cursor servers. Check the discriminator only when supplied.
    if (p.cursor !== undefined && p.cursor !== pending.cursor) { return false; }
    if (typeof p.page_idx === 'number' && p.page_idx !== pending.pageIdx) { return false; }
    // For later cursor pages, a frame without cursor must still identify its request.
    if (pending.cursor !== null && p.cursor === undefined && !p.request_id) { return false; }
    return true;
  }
  private finish(p: HistoryEnvelope, pending: HistoryPending): void {
    if (pending.parts.size) { throw new Error('历史消息分片不完整，请重试'); }
    let protocol: HistoryProtocol;
    if (typeof p.has_more === 'boolean') {
      if (pending.mode === 'page') { throw new Error('历史分页协议已变化，请重新打开会话'); }
      if (p.has_more && (typeof p.next_cursor !== 'string' || !p.next_cursor || p.next_cursor === pending.cursor)) {
        throw new Error('历史分页信息不完整或游标未前进');
      }
      protocol = 'cursor';
      pending.page.nextCursor = p.has_more ? { protocol: 'cursor', cursor: p.next_cursor || '' } : null;
      pending.page.snapshot = p.snapshot_id || ''; pending.page.snapshotEnd = p.snapshot_end || 0;
    } else {
      if (pending.mode === 'cursor' || (p.has_more !== undefined && p.has_more !== null)) {
        throw new Error('历史分页信息不完整');
      }
      const pageIdx = p.page_idx; const totalPages = p.total_pages;
      if (typeof pageIdx !== 'number' || typeof totalPages !== 'number'
        || !Number.isSafeInteger(pageIdx) || !Number.isSafeInteger(totalPages)
        || pageIdx < 1 || totalPages < pageIdx || pageIdx !== pending.pageIdx) {
        throw new Error('历史页码信息不完整');
      }
      if (pending.totalPages !== undefined && pending.totalPages !== totalPages) {
        throw new Error('后端历史页数已变化，请重新打开会话');
      }
      protocol = 'page';
      pending.page.nextCursor = pageIdx < totalPages
        ? { protocol: 'page', pageIdx: pageIdx + 1, totalPages: totalPages } : null;
    }
    if (this.mode !== 'auto' && this.mode !== protocol) { throw new Error('历史分页协议已变化，请重新连接'); }
    this.mode = protocol;
    CommunicationLog.record('history.page_loaded', { sessionId: pending.session, requestId: pending.request,
      state: protocol, count: pending.page.records.length });
    clearTimeout(pending.timer); this.pending.delete(pending.session); pending.resolve(pending.page);
    pending.waiters.forEach((resolve: () => void) => resolve()); pending.waiters = [];
  }
  accept(frame: Frame): boolean {
    if (frame.event === 'chat.error' || frame.event === 'execution.error') {
      const request = frame.payload?.request_id;
      const pending = Array.from(this.pending.values()).find((item: HistoryPending) => item.request === request);
      if (pending) { this.fail(pending, new Error(frame.payload?.error || frame.payload?.message || '历史读取失败')); return true; }
    }
    if (frame.event !== 'history.message') { return false; }
    const p = frame.payload as Object as HistoryEnvelope;
    if (!p) { return true; }
    const pending = this.pending.get(p.session_id || '');
    if (!pending || !this.matches(p, pending)) { return true; }
    try {
      if (pending.abandoned) {
        if (p.status === 'done' || p.content === 'done' || p.status === 'error') { this.fail(pending, new Error('已离开会话')); }
        return true;
      }
      if (p.status === 'error') { throw new Error(p.error || '历史读取失败'); }
      if (p.status === 'done' || p.content === 'done') {
        this.finish(p, pending);
        return true;
      }
      const value = p.message ?? p.content;
      const record = (typeof value === 'string' ? JSON.parse(value) : value) as HistoryRecord;
      if (!record || typeof record !== 'object' || Array.isArray(record)) { throw new Error('历史消息格式无效'); }
      if (isUsageEvent(record.event_type || '')) { return true; }
      if (record._part) {
        const part = record._part;
        if (!part.record_id || part.total_parts < 1 || part.total_parts > 1024 || part.part_idx < 0 || part.part_idx >= part.total_parts) { throw new Error('历史分片序号无效'); }
        let bucket = pending.parts.get(part.record_id);
        if (!bucket) { bucket = new Map(); pending.parts.set(part.record_id, bucket); }
        bucket.set(part.part_idx, record);
        if (bucket.size === part.total_parts) {
          const first = bucket.get(0)!;
          const chunks: string[] = [];
          for (let i = 0; i < part.total_parts; i++) {
            const chunk = bucket.get(i); if (!chunk || chunk._part?.total_parts !== part.total_parts) { throw new Error('历史分片不一致'); }
            chunks.push(chunk.content || '');
          }
          first.content = chunks.join(''); first._part = undefined;
          pending.parts.delete(part.record_id); pending.page.records.push(first);
        }
      } else { pending.page.records.push(record); }
    } catch (error) { this.fail(pending, error as Error); }
    return true;
  }
}
export function historyKey(record: HistoryRecord): string {
  return (record.id || record.request_id || '') + '|' + (record.event_type || record.role || '') + '|' + (record.timestamp || 0).toString() + '|' + (record.content || '');
}
