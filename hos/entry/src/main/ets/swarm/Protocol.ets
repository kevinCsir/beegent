import { SubagentWire } from './Subagents';
import { Answer, Question, EvolutionMeta, FlowMeta, PlanAction, FileWire, ToolWire, TodoWire } from './RichMessage';
// Wire types intentionally preserve the original payload for future message renderers.
export interface Params {
  limit?: number; offset?: number; cursor?: string | null; page_idx?: number;
  session_id?: string;
  mode?: string;
  content?: string;
  intent?: string;
  title?: string;
  work_mode?: string;
  create_token?: string;
  input_mode?: string;
  expected_execution_id?: string;
  request_id?: string; query?: string; answers?: Answer[]; source?: string;
  approval_schema?: string; evolution_meta?: EvolutionMeta; plan_approval_kind?: string;
  plan_content?: string; plan_language?: string; run_id?: string; correlation_id?: string; answer?: string;
}
export interface Payload extends ToolWire, SubagentWire {
  todos?: TodoWire[];
  session_id?: string;
  sessionId?: string;
  request_id?: string;
  turn_request_id?: string;
  execution_id?: string;
  content?: string;
  message?: string;
  error?: string;
  role?: string;
  source?: string;
  segment_id?: string;
  output_phase_id?: string;
  final_mode?: string;
  is_processing?: boolean;
  is_complete?: boolean;
  success?: boolean;
  has_active_task?: boolean;
  intent?: string;
  accepted?: boolean;
  code?: string;
  event_type?: string;
  input_request_id?: string;
  input_boundary?: string;
  input_delivery?: string;
  output_suppressed?: boolean;
  protocol_version?: string; tools?: string[]; running?: boolean; count?: number;
  plan_actions?: PlanAction[];
  questions?: Question[]; approval_schema?: string; evolution_meta?: EvolutionMeta; _evolution_meta?: EvolutionMeta;
  plan_approval_kind?: string; plan_content?: string; plan_language?: string; swarmflow_meta?: FlowMeta;
  files?: FileWire[]; media_items?: FileWire[]; audio_base64?: string; audio_mime?: string;
  tool_call?: ToolWire; tool_result?: ToolWire; tool_update?: ToolWire;
  tool_call_id?: string; toolCallId?: string; id?: string; name?: string; tool_name?: string;
  arguments?: Object | string; description?: string; status?: string; result?: Object | string;
  rendered_result?: string; raw_output?: ToolWire; data?: ToolWire | string;
  updates?: MessageUpdates; message_id?: string;
}
export interface Frame {
  type: string;
  id?: string;
  ok?: boolean;
  error?: string;
  code?: string;
  event?: string;
  payload?: Payload;
  seq?: number;
  stream_id?: string;
}
export interface RequestFrame {
  type: string;
  id: string;
  method: string;
  params: Params;
}
export type ConnectionState = 'closed' | 'connecting' | 'open' | 'error';
export type RunState = 'idle' | 'sending' | 'running' | 'stopping' | 'waiting' | 'unknown' | 'error';
export interface Transport {
  onText: (text: string) => void;
  onClosed: (reason: string) => void;
  open(url: string): Promise<void>;
  send(text: string): Promise<void>;
  close(): void;
}
export class RequestFailure extends Error {
  // false means the server may have accepted a request before transport loss.
  definitive: boolean;
  constructor(message: string, definitive: boolean = false) {
    super(message);
    this.definitive = definitive;
  }
}
let counter: number = 0;
export function requestId(): string {
  counter++;
  return 'jwb-' + Date.now().toString(36) + '-' + counter.toString(36);
}
export function endpointOf(input: string): string {
  let value = input.trim();
  if (!value.includes('://')) { value = 'ws://' + value; }
  const match = /^(wss?):\/\/(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?(\/[^\s?#]*)?$/.exec(value);
  if (match === null) { throw new Error('请输入电脑 IP、IP:端口或完整 ws://地址/ws'); }
  const port = match[3] ? Number(match[3]) : 19000;
  if (port < 1 || port > 65535) { throw new Error('端口必须为 1–65535'); }
  return match[1] + '://' + match[2].toLowerCase() + ':' + port.toString() + (match[4] || '/ws');
}
export function decodeFrame(text: string): Frame {
  const value = JSON.parse(text) as Frame;
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw new Error('服务端返回无效消息'); }
  if (value.type !== 'res' && value.type !== 'event') { throw new Error('未知协议消息'); }
  if (value.type === 'res' && (typeof value.id !== 'string' || typeof value.ok !== 'boolean')) {
    throw new Error('服务端响应缺少请求标识');
  }
  if (value.type === 'event' && typeof value.event !== 'string') { throw new Error('事件缺少名称'); }
  if (value.payload !== undefined && (!value.payload || typeof value.payload !== 'object' || Array.isArray(value.payload))) {
    throw new Error('无效事件载荷');
  }
  return value;
}

export interface MessageUpdates { query?: string; }



export function downloadOriginOf(endpoint: string, port: number = 5173): string {
  const match = /^(wss?):\/\/(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::[0-9]+)?(?:\/.*)?$/.exec(endpoint);
  if (!match) { throw new Error('服务器地址无效'); }
  return (match[1] === 'wss' ? 'https://' : 'http://') + match[2] + ':' + port.toString();
}
function connectionPort(value: string, fallback: number, label: string): number {
  const text = value.trim();
  if (!text) { return fallback; }
  const port = Number(text);
  if (!/^[0-9]+$/.test(text) || port < 1 || port > 65535) { throw new Error(label + '必须为 1–65535 的整数'); }
  return port;
}
export class ConnectionSettings {
  ip: string;
  webPort: number;
  downloadPort: number;
  endpoint: string;
  downloadOrigin: string;
  constructor(ip: string, webPort: string, downloadPort: string) {
    this.ip = ip.trim();
    const parts = this.ip.split('.');
    if (parts.length !== 4 || parts.some((part: string) => !/^[0-9]{1,3}$/.test(part) || Number(part) > 255)) {
      throw new Error('请输入电脑的 IPv4 地址，例如 192.168.43.217');
    }
    this.ip = parts.map((part: string) => Number(part).toString()).join('.');
    this.webPort = connectionPort(webPort, 19000, '后端端口');
    this.downloadPort = connectionPort(downloadPort, 5173, '下载端口');
    this.endpoint = endpointOf(this.ip + ':' + this.webPort.toString());
    this.downloadOrigin = downloadOriginOf(this.endpoint, this.downloadPort);
  }
}
