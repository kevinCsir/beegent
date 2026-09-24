import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import util from '@ohos.util';
import { Transport } from './Protocol';
export class HarmonyTransport implements Transport {
  onText: (text: string) => void = () => {};
  onClosed: (reason: string) => void = () => {};
  private socket: webSocket.WebSocket = webSocket.createWebSocket();
  private endpoint: string = '';
  private rejectOpen?: (error: Error) => void;
  open(url: string): Promise<void> {
    this.endpoint = url;
    return new Promise<void>((resolve, reject) => {
      this.rejectOpen = reject;
      this.socket.on('open', (error: BusinessError): void => {
        if (error) { CommunicationLog.record('transport.handshake_error', { endpoint: url, error: error.message, code: error.code }, 'error'); this.fail('WebSocket 握手失败'); return; }
        this.rejectOpen = undefined; resolve();
      });
      this.socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
        if (error) { CommunicationLog.record('transport.receive_error', { endpoint: url, error: error.message, code: error.code }, 'error'); this.fail('接收消息失败'); return; }
        const text = typeof data === 'string' ? data : util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(data));
        this.onText(text);
      });
      this.socket.on('close', (error: BusinessError, result: webSocket.CloseResult): void => {
        CommunicationLog.record('transport.closed', { endpoint: url, code: result?.code, reason: result?.reason, error: error?.message });
        this.fail('连接已断开');
      });
      this.socket.on('error', (error: BusinessError): void => {
        CommunicationLog.record('transport.error', { endpoint: url, code: error.code, error: error.message }, 'error');
        this.fail('连接异常，请检查网络和服务端（' + error.code.toString() + '）');
      });
      // connect() acknowledges initiation; only the open event confirms the handshake.
      this.socket.connect(url).then((started: boolean) => {
        if (!started) { this.fail('无法发起 WebSocket 连接'); }
      }).catch((error: Error) => { CommunicationLog.record('transport.connect_error', { endpoint: url, error: error.message }, 'error'); this.fail('无法发起 WebSocket 连接'); });
    });
  }
  private fail(reason: string): void {
    this.rejectOpen?.(new Error(reason)); this.rejectOpen = undefined;
    this.onClosed(reason);
  }
  async send(text: string): Promise<void> {
    if (!await this.socket.send(text)) { throw new Error('发送失败'); }
  }
  close(): void {
    this.rejectOpen?.(new Error('连接已关闭')); this.rejectOpen = undefined;
    try { this.socket.close().catch(() => {}); } catch (_) { /* Already closed. */ }
  }
}
