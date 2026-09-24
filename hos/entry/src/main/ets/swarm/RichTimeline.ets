import { isUsageEvent } from './UsageStore';
import { Frame } from './Protocol';
import { ChatMessage, Interaction, Attachment, FileWire, ToolWire, Step, brief, toolText } from './RichMessage';
export class RichTimeline {
  interactions: Map<string, ChatMessage> = new Map();
  private groups: Map<string, ChatMessage> = new Map();
  private tools: Map<string, ChatMessage> = new Map();
  private epochs: Map<string, number> = new Map();
  private bodySeen: Set<string> = new Set();
  private finalized: Set<string> = new Set();
  private fallbackRows: Map<string, ChatMessage> = new Map();
  private attachmentIds: Set<string> = new Set();
  private counter: number = 0;
  private endpoint: string;
  private add: (row: ChatMessage) => void;
  private update: (row: ChatMessage) => void;
  constructor(endpoint: string, add: (row: ChatMessage) => void, update: (row: ChatMessage) => void) {
    this.endpoint = endpoint; this.add = add; this.update = update;
  }
  segment(request: string): string { const epoch = this.epochs.get(request) || 0; return epoch ? ':part-' + epoch.toString() : ''; }
  private group(request: string): ChatMessage {
    let row = this.groups.get(request);
    if (!row) { row = new ChatMessage('steps-' + request + '-' + (++this.counter).toString(), 'assistant', '执行步骤'); row.kind = 'steps'; row.answerId = request; this.groups.set(request, row); this.add(row); }
    return row;
  }
  body(request: string): void {
    if (this.bodySeen.has(request)) { return; }
    this.bodySeen.add(request);
    const group = this.groups.get(request);
    if (!group) { return; }
    group.steps.forEach((step: Step) => { if (step.id.startsWith('reasoning-')) { step.status = 'done'; } });
    this.finalized.add(group.id); group.collapse = true; group.collapseVersion++;
    this.update(group);
  }
  hasPending(): boolean {
    return Array.from(this.interactions.values()).some((row: ChatMessage) => !!row.interaction && ['pending', 'sending', 'failed', 'unknown'].includes(row.interaction.status));
  }
  ended(request: string): void {
    this.interactions.forEach((row: ChatMessage) => { if (row.interaction?.replyId === request) { row.interaction.ended = true; this.update(row); } });
  }
  cancelDeferredPlans(): void {
    this.interactions.forEach((row: ChatMessage) => { if (row.interaction) { row.interaction.executePlan = false; } });
  }
  expire(): void {
    this.cancelDeferredPlans();
    this.interactions.forEach((row: ChatMessage) => { if (row.interaction && ['pending', 'sending', 'failed', 'unknown'].includes(row.interaction.status)) { row.interaction.status = 'expired'; row.interaction.executePlan = false; this.update(row); } });
    this.groups.forEach((row: ChatMessage) => { row.steps.forEach((step: Step) => { if (step.status === 'running') { step.status = 'stopped'; } }); this.update(row); });
  }
  changed(row: ChatMessage): void { this.update(row); }
  apply(frame: Frame, request: string): boolean {
    const p = frame.payload || {}; const event = frame.event || '';
    if (event === 'chat.ask_user_question' || event === 'plan.approval_required') {
      const id = p.request_id || request;
      if (this.interactions.has(id)) { return true; }
      const value = new Interaction(); value.id = id; value.source = p.source || '';
      value.planActions = p.plan_actions || [];
      value.questions = (p.questions || []).filter((q) => !!q && typeof q.question === 'string');
      value.approvalSchema = p.approval_schema || ''; value.evolution = p.evolution_meta || p._evolution_meta;
      value.planKind = p.plan_approval_kind || ''; value.planContent = p.plan_content || ''; value.planLanguage = p.plan_language || ''; value.flow = p.swarmflow_meta;
      if (!value.questions.length) { value.error = '已收到确认请求，但缺少问题结构，请在电脑端处理或停止任务。'; }
      const row = new ChatMessage('question-' + id, 'assistant', value.planContent); row.kind = 'interaction'; row.answerId = request; row.interaction = value;
      this.interactions.set(id, row); this.add(row); return true;
    }
    if (event === 'chat.reasoning' || event === 'chat.tool_call' || event === 'chat.tool_result' || event === 'chat.tool_update') {
      const tool: ToolWire = p.tool_call || p.tool_result || p.tool_update || p;
      const toolId = tool.id || tool.tool_call_id || tool.toolCallId || p.tool_call_id || p.toolCallId || '';
      if (event !== 'chat.reasoning' && !toolId) { this.fallback(frame, request); return true; }
      const existing = this.tools.get(request + '|' + toolId);
      if (!existing && this.bodySeen.has(request)) {
        this.bodySeen.delete(request); this.groups.delete(request); this.epochs.set(request, (this.epochs.get(request) || 0) + 1);
      }
      const row = existing || this.group(request);
      if (event === 'chat.reasoning') {
        let step = row.steps.find((s: Step) => s.id === 'reasoning-' + row.id);
        if (!step) { step = new Step('reasoning-' + row.id, '思考过程', '', 'running'); row.steps.push(step); }
        step.text += p.content || ''; row.collapse = false;
      } else {
        row.steps.forEach((s: Step) => { if (s.id.startsWith('reasoning-')) { s.status = 'done'; } });
        let step = row.steps.find((s: Step) => s.id === toolId);
        if (!step) { step = new Step(toolId, tool.name || tool.tool_name || p.tool_name || '工具执行', '', 'running'); row.steps.push(step); }
        const text = toolText(tool); if (text) { step.text = text; }
        const status = tool.status || p.status || '';
        if (tool.success === false || tool.error || ['error', 'failed', 'timeout', 'timed_out'].includes(status)) { step.status = 'error'; }
        else if (event === 'chat.tool_result' && status !== 'pending' && status !== 'running' || status === 'completed' || status === 'success') { step.status = 'done'; }
        this.tools.set(request + '|' + toolId, row);
        if (this.finalized.has(row.id)) { row.collapse = true; } else { row.collapse = false; }
      }
      this.update(row); return true;
    }
    if (event === 'chat.file' || event === 'chat.media') {
      const files: FileWire[] = p.files || p.media_items || [];
      if (p.audio_base64) { files.push({ name: '语音', mime_type: p.audio_mime || 'audio/wav', base64_data: p.audio_base64 }); }
      if (!files.length) { this.fallback(frame, request); return true; }
      const row = new ChatMessage('attachments-' + request + '-' + (++this.counter).toString(), 'assistant', p.content || ''); row.kind = 'attachments'; row.answerId = request;
      files.forEach((file: FileWire, index: number) => {
        const identity = request + '|' + (file.download_url || file.url || '') + '|' + (file.name || file.filename || file.path || '') + '|' + (file.base64_data || file.base64Data || '').slice(0, 64);
        if (this.attachmentIds.has(identity)) { return; }
        this.attachmentIds.add(identity); row.attachments.push(new Attachment(row.id + '-' + index.toString(), file, this.endpoint));
      });
      if (row.attachments.length) { this.add(row); } return true;
    }
    return false;
  }
  fallback(frame: Frame, request: string): void {
    const event = frame.event || '未知事件';
    // Transport/lifecycle notifications are represented by the connection and execution state.
    if (['runtime.accepted', 'chat.processing_status', 'chat.output_phase', 'connected', 'heartbeat', 'pong'].includes(event)) { return; }
    if (isUsageEvent(event)) { return; }
    const key = request + '|' + event;
    const p = frame.payload || {};
    const detail = brief(p.content || p.message || p.error || p.description || '已收到此类型消息，当前版本暂无专用展示。');
    const existing = this.fallbackRows.get(key);
    if (existing) { existing.text = event + '\n' + detail; this.update(existing); return; }
    const row = new ChatMessage('notice-' + (++this.counter).toString(), 'system', event + '\n' + detail); row.kind = 'notice';
    this.fallbackRows.set(key, row); this.add(row);
  }
}
