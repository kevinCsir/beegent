import { CommunicationLog, LogDetails } from '../diagnostics/CommunicationLog';
import { ConnectionState, Frame, Params, Payload, RequestFailure, RequestFrame, Transport, decodeFrame, requestId } from './Protocol';
class Pending {
  resolve: (payload: Payload) => void;
  reject: (error: RequestFailure) => void;
  timer: number;
  awaitRuntime: boolean = false;
  method: string = ''; sessionId: string = ''; startedAt: number = Date.now();
  constructor(resolve: (payload: Payload) => void, reject: (error: RequestFailure) => void, timer: number) {
    this.resolve = resolve; this.reject = reject; this.timer = timer;
  }
}
export class SwarmConnection {
  state: ConnectionState = 'closed';
  acknowledgement?: Payload;
  onState: (state: ConnectionState, reason: string) => void = () => {};
  onEvent: (frame: Frame) => void = () => {};
  onProtocolError: (reason: string) => void = () => {};
  private connectionId: string = ''; private endpoint: string = '';
  private trace(event: string, details: LogDetails = {}, level: string = 'info'): void {
    details.connectionId = details.connectionId || this.connectionId; details.endpoint = details.endpoint || this.endpoint;
    CommunicationLog.record(event, details, level);
  }
  private factory: () => Transport;
  private transport?: Transport;
  private opening?: Promise<void>;
  private generation: number = 0;
  private cancelOpening?: (error: Error) => void;
  private pending: Map<string, Pending> = new Map();
  constructor(factory: () => Transport) { this.factory = factory; }
  connect(url: string): Promise<void> {
    if (this.state === 'open') { return Promise.resolve(); }
    if (this.opening) { return this.opening; }
    this.connectionId = requestId(); this.endpoint = url;
    const connectionId = this.connectionId;
    this.trace('ws.connect.start');
    this.acknowledgement = undefined;
    const generation = ++this.generation;
    const transport = this.factory();
    this.transport = transport;
    this.setState('connecting', '');
    transport.onText = (text: string): void => {
      if (generation !== this.generation) { this.trace('ws.receive.stale_socket', { connectionId: connectionId, endpoint: url, characters: text.length, generation: generation }, 'warn'); return; }
      let frame: Frame;
      try { frame = decodeFrame(text); }
      catch (error) {
        // Unparseable text is not dumped: it cannot be reliably structurally redacted.
        this.trace('ws.receive.invalid', { characters: text.length,
          error: (error as Error).name === 'SyntaxError' ? 'Invalid JSON; raw text omitted' : (error as Error).message }, 'error');
        this.onProtocolError('收到无法解析的消息，已跳过'); return;
      }
      const rid = frame.id || frame.payload?.request_id || frame.payload?.turn_request_id || '';
      const pending = this.pending.get(rid);
      this.trace('ws.receive', { direction: 'in', requestId: rid, sessionId: frame.payload?.session_id || frame.payload?.parent_session_id || pending?.sessionId,
        event: frame.event || frame.type, method: pending?.method, matched: !!pending,
        elapsedMs: pending ? Date.now() - pending.startedAt : undefined, characters: text.length, frame: frame });
      try { this.receive(frame); }
      catch (error) { this.trace('ws.receive.handler_error', { requestId: rid, event: frame.event, error: (error as Error).message }, 'error'); this.onProtocolError('消息处理失败，详见通信日志'); }
    };
    transport.onClosed = (reason: string): void => {
      if (generation === this.generation) { this.close(reason || '连接已断开'); }
    };
    let connectTimer: number = -1;
    const attempt = new Promise<void>((resolve, reject) => {
      this.cancelOpening = reject;
      const timer = setTimeout(() => reject(new Error('连接超时，请检查地址和防火墙')), 10000);
      connectTimer = timer;
      transport.open(url).then(() => {
        clearTimeout(timer);
        if (generation !== this.generation) { reject(new Error('连接已取消')); return; }
        this.setState('open', ''); resolve();
      }).catch((error: Error) => { clearTimeout(timer); reject(error); });
    });
    this.opening = attempt.catch((error: Error) => {
      if (generation === this.generation) {
        this.close('连接失败，请检查 Swarm 是否启动及网络是否可达');
        this.setState('error', error.message);
      }
      throw error;
    }).finally(() => {
      clearTimeout(connectTimer);
      if (generation === this.generation) { this.opening = undefined; this.cancelOpening = undefined; }
    });
    return this.opening;
  }
  close(reason: string = '连接已断开'): void {
    this.trace('ws.close', { reason: reason, count: this.pending.size });
    this.generation++; this.acknowledgement = undefined;
    const transport = this.transport;
    this.transport = undefined;
    this.cancelOpening?.(new Error(reason));
    this.cancelOpening = undefined; this.opening = undefined;
    this.pending.forEach((pending: Pending, id: string) => { this.trace('request.cancelled', { requestId: id, method: pending.method, sessionId: pending.sessionId, elapsedMs: Date.now() - pending.startedAt, reason: reason }, 'warn'); clearTimeout(pending.timer); pending.reject(new RequestFailure(reason)); });
    this.pending.clear();
    transport?.close();
    this.setState('closed', reason);
  }
  request(method: string, params: Params, id: string = requestId(), awaitRuntime: boolean = false): Promise<Payload> {
    const transport = this.transport;
    if (this.state !== 'open' || !transport) { this.trace('request.blocked', { requestId: id, method: method, sessionId: params.session_id, state: this.state }, 'warn'); return Promise.reject(new RequestFailure('尚未连接电脑', true)); }
    const generation = this.generation;
    const frame: RequestFrame = { type: 'req', id: id, method: method, params: params };
    const connectionId = this.connectionId; const endpoint = this.endpoint;
    return new Promise<Payload>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.trace('request.timeout', { requestId: id, method: method, sessionId: params.session_id, elapsedMs: Date.now() - pending.startedAt, awaitRuntime: awaitRuntime }, 'error');
        this.pending.delete(id);
        reject(new RequestFailure('服务端响应超时，结果待确认，请勿重复发送'));
      }, 30000);
      const pending = new Pending(resolve, reject, timer);
      pending.awaitRuntime = awaitRuntime; pending.method = method; pending.sessionId = params.session_id || '';
      this.pending.set(id, pending);
      const text = JSON.stringify(frame);
      this.trace('ws.send', { direction: 'out', requestId: id, method: method, sessionId: params.session_id,
        characters: text.length, awaitRuntime: awaitRuntime, frame: frame });
      transport.send(text).then(() => {
        this.trace('ws.send.accepted_by_socket', { connectionId: connectionId, endpoint: endpoint, requestId: id, method: method, elapsedMs: Date.now() - pending.startedAt });
      }).catch((error: Error) => {
        this.trace('ws.send.failed', { connectionId: connectionId, endpoint: endpoint, requestId: id, method: method, error: error.message }, 'error');
        const pending = this.pending.get(id);
        if (pending) { clearTimeout(timer); this.pending.delete(id); pending.reject(new RequestFailure('发送中断，结果待确认')); }
        if (generation === this.generation) { this.close('网络发送失败'); }
      });
    });
  }
  private receive(frame: Frame): void {
    if (frame.type === 'event') {
      if (frame.event === 'chat.final' && frame.payload?.event_type === 'runtime.accepted') {
        frame.event = 'runtime.accepted';
      }
      if (frame.event === 'connection.ack' || frame.event === 'connect.ack') {
        this.acknowledgement = frame.payload || {}; return;
      }
      const payload = frame.payload || {};
      const pending = this.pending.get(payload.request_id || '');
      if (pending?.awaitRuntime && (frame.event === 'runtime.accepted' || frame.event === 'chat.error')) {
        this.trace('request.runtime_receipt', { requestId: payload.request_id, sessionId: pending.sessionId, method: pending.method, event: frame.event, elapsedMs: Date.now() - pending.startedAt });
        clearTimeout(pending.timer); this.pending.delete(payload.request_id || '');
        if (frame.event === 'runtime.accepted') { pending.resolve(payload); }
        else { pending.reject(new RequestFailure(payload.error || payload.message || '补充被拒绝', payload.code !== 'SESSION_INPUT_DELIVERY_UNKNOWN')); }
      }
      this.onEvent(frame); return;
    }
    const id = frame.id || '';
    const pending = this.pending.get(id);
    if (!pending) { this.trace('request.unmatched_response', { requestId: id }, 'warn'); return; }
    if (frame.ok && pending.awaitRuntime) { this.trace('request.gateway_ack_waiting_runtime', { requestId: id, method: pending.method }); return; }
    this.trace(frame.ok ? 'request.response_ok' : 'request.response_error', { requestId: id, sessionId: pending.sessionId, method: pending.method, elapsedMs: Date.now() - pending.startedAt }, frame.ok ? 'info' : 'error');
    clearTimeout(pending.timer); this.pending.delete(id);
    if (frame.ok) { pending.resolve(frame.payload || {}); }
    else { pending.reject(new RequestFailure((frame.code ? frame.code + '：' : '') + (frame.error || '请求被拒绝'), true)); }
  }
  private setState(state: ConnectionState, reason: string): void { this.state = state; this.trace('ws.state', { state: state, reason: reason }); this.onState(state, reason); }
}
