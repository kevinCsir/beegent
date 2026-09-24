import { isUsageEvent } from './UsageStore';
import { Frame, Payload, requestId } from './Protocol';
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
  message?: HistoryRecord | string; content?: string; status?: string;
  next_cursor?: string | null; has_more?: boolean; snapshot_id?: string | null; snapshot_end?: number;
}
export class HistoryPage {
  records: HistoryRecord[] = []; nextCursor: string | null = null;
  snapshot: string = ''; snapshotEnd: number = 0;
}
class HistoryPending {
  session: string; request: string; cursor: string | null; page: HistoryPage = new HistoryPage();
  abandoned: boolean = false; waiters: Array<() => void> = [];
  parts: Map<string, Map<number, HistoryRecord>> = new Map();
  resolve: (page: HistoryPage) => void; reject: (error: Error) => void; timer: number = -1;
  constructor(session: string, request: string, cursor: string | null, resolve: (page: HistoryPage) => void, reject: (error: Error) => void) {
    this.session = session; this.request = request; this.cursor = cursor; this.resolve = resolve; this.reject = reject;
  }
}
export class HistoryClient {
  private pending: Map<string, HistoryPending> = new Map();
  private connection: SwarmConnection;
  constructor(connection: SwarmConnection) { this.connection = connection; }
  async fetch(session: string, cursor: string | null = null): Promise<HistoryPage> {
    const previous = this.pending.get(session);
    // Frames carry session/cursor, but older servers omit request IDs. Drain an abandoned
    // response before requesting the same session again, so old frames cannot cross over.
    if (previous?.abandoned) { await new Promise<void>((resolve) => { previous.waiters.push(resolve); }); }
    if (this.pending.has(session)) { return Promise.reject(new Error('正在加载此会话')); }
    const rid = requestId();
    return new Promise<HistoryPage>((resolve, reject) => {
      const pending = new HistoryPending(session, rid, cursor, resolve, reject);
      pending.timer = setTimeout(() => this.fail(pending, new Error('历史加载超时，请重试')), 30000);
      this.pending.set(session, pending);
      this.connection.request('history.get', { session_id: session, cursor: cursor, limit: 50 }, rid)
        .catch((error: Error) => this.fail(pending, error));
    });
  }
  private fail(pending: HistoryPending, error: Error): void {
    if (this.pending.get(pending.session) !== pending) { return; }
    clearTimeout(pending.timer); this.pending.delete(pending.session); pending.reject(error); pending.waiters.forEach((resolve: () => void) => resolve()); pending.waiters = [];
  }
  abandon(): void {
    this.pending.forEach((pending: HistoryPending) => {
      pending.abandoned = true; pending.page.records = []; pending.parts.clear();
    });
  }
  cancel(): void { this.pending.forEach((pending: HistoryPending) => this.fail(pending, new Error('连接已断开，历史加载已取消'))); }
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
    if (!pending || p.subagent_id || p.cursor !== pending.cursor || (p.request_id && p.request_id !== pending.request)) { return true; }
    try {
      if (pending.abandoned) {
        if (p.status === 'done' || p.content === 'done') { this.fail(pending, new Error('已离开会话')); }
        return true;
      }
      if (p.status === 'done' || p.content === 'done') {
        if (pending.parts.size) { throw new Error('历史消息分片不完整，请重试'); }
        if (typeof p.has_more !== 'boolean' || (p.has_more && (typeof p.next_cursor !== 'string' || !p.next_cursor))) { throw new Error('历史分页信息不完整'); }
        pending.page.nextCursor = p.has_more ? p.next_cursor || null : null;
        pending.page.snapshot = p.snapshot_id || ''; pending.page.snapshotEnd = p.snapshot_end || 0;
        clearTimeout(pending.timer); this.pending.delete(pending.session); pending.resolve(pending.page); pending.waiters.forEach((resolve: () => void) => resolve()); pending.waiters = [];
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
