import { downloadOriginOf } from './Protocol';
import { SubagentView } from './Subagents';
export interface PlanAction { kind: string; value: string; label: string; requires_input?: string; }
export interface Choice { label: string; description?: string; value?: string; }
export interface Question { question: string; header?: string; options?: Choice[]; multi_select?: boolean; card_id?: string; }
export interface Answer { question: string; selected_options: string[]; custom_input?: string; card_id?: string; }
export interface EvolutionMeta { approval_transport?: string; }
export interface FlowMeta { run_id?: string; correlation_id?: string; }
export interface FileWire {
  name?: string; filename?: string; size?: number; size_bytes?: number; sizeBytes?: number;
  mime_type?: string; mimeType?: string; download_url?: string; download_token?: string;
  url?: string; path?: string; type?: string; base64_data?: string; base64Data?: string;
}
export interface ToolWire {
  id?: string; tool_call_id?: string; toolCallId?: string; name?: string; tool_name?: string;
  arguments?: Object | string; description?: string; call_goal?: string; status?: string;
  result?: Object | string; rendered_result?: string; error?: string; success?: boolean;
  raw_output?: ToolWire; data?: ToolWire | string; message?: string; output?: string;
}
export class Attachment {
  id: string; name: string; mime: string; size: number; url: string; base64: string; available: boolean;
  constructor(id: string, file: FileWire, endpoint: string) {
    this.id = id; this.name = file.name || file.filename || file.path?.split(/[\\/]/).pop() || '附件';
    this.mime = file.mime_type || file.mimeType || 'application/octet-stream';
    this.size = file.size || file.size_bytes || file.sizeBytes || 0;
    this.base64 = file.base64_data || file.base64Data || '';
    this.url = downloadAddress(file.download_url || file.url || '', endpoint);
    this.available = !!(this.url || this.base64);
  }
}
export function downloadAddress(value: string, endpoint: string): string {
  const origin = /^wss?:/.test(endpoint) ? downloadOriginOf(endpoint) : endpoint.replace(/\/$/, '');
  if (/^https?:\/\//i.test(value)) { return value; }
  if (value.startsWith('/') && !value.startsWith('//')) { return origin + value; }
  return '';
}
export class Step {
  id: string; title: string; text: string; status: string;
  constructor(id: string, title: string, text: string, status: string) {
    this.id = id; this.title = title; this.text = text; this.status = status;
  }
}
export class Interaction {
  id: string = ''; source: string = ''; questions: Question[] = []; status: string = 'pending';
  error: string = ''; approvalSchema: string = ''; evolution?: EvolutionMeta;
  planKind: string = ''; planContent: string = ''; planLanguage: string = ''; flow?: FlowMeta;
  planActions: PlanAction[] = [];
  replyId: string = ''; ended: boolean = false; executePlan: boolean = false; previousMode: string = '';
}
export class ChatMessage {
  id: string; role: string; text: string; delivery: string;
  answerId: string = ''; collapseVersion: number = 0;
  kind: string = 'text'; steps: Step[] = []; attachments: Attachment[] = [];
  interaction?: Interaction; collapse: boolean = false; subagent?: SubagentView;
  constructor(id: string, role: string, text: string, delivery: string = '') {
    this.id = id; this.role = role; this.text = text; this.delivery = delivery;
  }
}
export function brief(value: Object | string | undefined): string {
  if (value === undefined) { return ''; }
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  // Avoid putting binary blobs or bearer download links into the timeline.
  return text.slice(0, 12000).replace(/data:[^\s]+;base64,[A-Za-z0-9+/=]+/g, '[二进制内容]')
    .replace(/([?&](?:token|download_token|api_key)=)[^\s&"]+/gi, '$1[隐藏]');
}
export function toolText(tool: ToolWire): string {
  const raw = tool.raw_output || tool;
  const data = raw.data;
  return brief(raw.result || (typeof data === 'object' ? data.result || data.message : data) || tool.rendered_result || raw.output || tool.error || tool.description || tool.arguments);
}


export interface TodoWire { id?: string; content?: string; activeForm?: string; status?: string; }
export class TodoItem {
  id: string; content: string; activeForm: string; status: string;
  constructor(value: TodoWire) {
    this.id = value.id || ''; this.content = value.content || ''; this.activeForm = typeof value.activeForm === 'string' && value.activeForm ? value.activeForm : this.content;
    this.status = ['pending', 'in_progress', 'completed', 'cancelled'].includes(value.status || '') ? value.status! : 'pending';
  }
}
export function parseTodos(values: TodoWire[]): TodoItem[] {
  const items = new Map<string, TodoItem>();
  values.forEach((value: TodoWire) => {
    if (value && typeof value.id === 'string' && value.id && typeof value.content === 'string' && value.status !== 'deleted') {
      items.set(value.id, new TodoItem(value));
    }
  });
  return Array.from(items.values());
}
export function isImage(file: Attachment): boolean {
  return file.mime.toLowerCase().startsWith('image/') || /\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)$/i.test(file.name);
}
export function isHtml(file: Attachment): boolean {
  return ['text/html', 'application/xhtml+xml'].includes(file.mime.toLowerCase().split(';')[0].trim()) || /\.html?$/i.test(file.name);
}
