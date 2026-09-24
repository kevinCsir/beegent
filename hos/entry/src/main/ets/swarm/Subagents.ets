import { ChatMessage, brief } from './RichMessage';
export interface SubagentWire {
  subagent_id?: string; parent_session_id?: string; display_name?: string; description?: string;
  task_description?: string; status?: string; lifecycle?: string; turn_outcome?: string;
  closed_reason?: string; can_send_input?: boolean; needs_resume?: boolean;
  revision?: number; updated_at?: number; created_at?: number;
  task_id?: string; activity_id?: string; seq?: number; sequence?: number;
  kind?: string; summary?: string; at_ms?: number; tool_name?: string; dropped?: number;
}
export class AgentActivity {
  id: string; task: string; sequence: number; at: number; title: string; text: string;
  constructor(id: string, p: SubagentWire) {
    this.id = id; this.task = p.task_id || ''; this.sequence = p.seq ?? p.sequence ?? 0; this.at = p.at_ms || 0;
    this.title = p.kind === 'thinking' ? '思考' : p.kind === 'tool_call' ? '调用工具' : p.kind === 'tool_result' ? '工具结果' : p.kind === 'error' ? '错误' : p.kind === 'truncated' ? '记录已截断' : p.kind || '活动';
    if (p.tool_name) { this.title += ' · ' + p.tool_name; }
    this.text = brief(p.summary || (p.dropped ? '省略 ' + p.dropped.toString() + ' 条活动' : '收到执行活动'));
  }
}
export class SubagentView {
  id: string; name: string; task: string = ''; status: string = '状态待确认'; latest: string = '';
  revision: number = -1; updatedAt: number = -1; running: boolean = false;
  activities: AgentActivity[] = []; omitted: number = 0;
  constructor(id: string) { this.id = id; this.name = id; }
  copy(): SubagentView {
    const value = new SubagentView(this.id);
    value.name = this.name; value.task = this.task; value.status = this.status; value.latest = this.latest;
    value.revision = this.revision; value.updatedAt = this.updatedAt; value.running = this.running;
    value.activities = this.activities.slice(); value.omitted = this.omitted;
    return value;
  }
}
function statusLabel(p: SubagentWire): string {
  const outcome = p.turn_outcome || p.closed_reason || p.status || '';
  const result = ['failed', 'error'].includes(outcome) ? '失败' : ['cancelled', 'canceled'].includes(outcome) ? '已取消' : outcome === 'parent_ended' ? '主任务已结束' : outcome === 'completed' ? '已完成' : '';
  if (p.lifecycle === 'closed' || p.needs_resume || p.status === 'closed') { return '已关闭' + (result ? ' · ' + result : ''); }
  if (['running', 'starting', 'pending', 'pending_init'].includes(p.status || '')) { return '执行中'; }
  if (p.status === 'idle' || (p.lifecycle === 'live' && p.can_send_input)) { return '空闲' + (result ? ' · 本轮' + result : ''); }
  return result || p.status || '状态待确认';
}
export class Subagents {
  private rows: Map<string, ChatMessage> = new Map();
  private seen: Set<string> = new Set();
  private dirty: Set<ChatMessage> = new Set();
  private timer: number = -1;
  private sessionId: string;
  private add: (row: ChatMessage) => void;
  private update: (row: ChatMessage) => void;
  constructor(sessionId: string, add: (row: ChatMessage) => void, update: (row: ChatMessage) => void) {
    this.sessionId = sessionId; this.add = add; this.update = update;
  }
  apply(event: string, p: SubagentWire): boolean {
    if (!['chat.subtask_update', 'chat.subagent_activity'].includes(event)) { return false; }
    if (!p.subagent_id || (p.parent_session_id && p.parent_session_id !== this.sessionId)) { return false; }
    const id = p.subagent_id;
    const activityId = id + '|' + (p.task_id || '') + '|' + (p.activity_id || (p.seq ?? p.sequence)?.toString() || ((p.at_ms || 0).toString() + '|' + p.kind + '|' + p.summary));
    if (event === 'chat.subagent_activity' && this.seen.has(activityId)) { return true; }
    let row = this.rows.get(id);
    if (!row) {
      row = new ChatMessage('subagent-' + id, 'assistant', ''); row.kind = 'subagent'; row.subagent = new SubagentView(id);
      this.rows.set(id, row); this.add(row);
    }
    const agent = row.subagent!;
    if (event === 'chat.subtask_update') {
      const revision = p.revision ?? 0; const at = p.updated_at ?? p.created_at ?? 0;
      if (revision < agent.revision || (revision === agent.revision && at <= agent.updatedAt)) { return true; }
      agent.revision = revision; agent.updatedAt = at;
      agent.name = p.display_name || p.description || agent.name;
      agent.task = p.task_description || agent.task;
      agent.status = statusLabel(p); agent.running = agent.status === '执行中';
    } else {
      this.seen.add(activityId);
      if (this.seen.size > 2048) { this.seen.delete(Array.from(this.seen)[0]); }
      const activity = new AgentActivity(activityId, p);
      agent.activities.push(activity);
      agent.activities.sort((a: AgentActivity, b: AgentActivity) => a.task === b.task ? a.sequence - b.sequence || a.at - b.at : a.at - b.at);
      if (agent.activities.length > 200) { agent.activities.shift(); agent.omitted++; }
      const latest = agent.activities[agent.activities.length - 1];
      agent.latest = latest.title + '：' + latest.text;
      // Activity alone does not prove the agent is still running: it may arrive after its terminal status.
    }
    this.dirty.add(row);
    if (this.timer === -1) { this.timer = setTimeout(() => this.flush(), 40); }
    return true;
  }
  uncertain(): void {
    this.rows.forEach((row: ChatMessage) => {
      if (row.subagent?.running) { row.subagent.status = '状态待确认'; row.subagent.running = false; this.dirty.add(row); }
    });
    this.flush();
  }
  flush(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.dirty.forEach((row: ChatMessage) => this.update(row)); this.dirty.clear();
  }
}
