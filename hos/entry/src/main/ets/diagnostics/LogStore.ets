import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CommunicationLog } from './CommunicationLog';

class BufferedLine {
  data: Uint8Array;
  constructor(text: string) { this.data = new util.TextEncoder().encodeInto(text); }
}
export class LogStore {
  private static directory: string = '';
  private static ready: boolean = false;
  private static size: number = 0;
  private static queue: BufferedLine[] = [];
  private static queuedBytes: number = 0;
  private static timer: number = -1;
  private static flushing: boolean = false;
  private static io: Promise<void> = Promise.resolve();
  private static dropped: number = 0;
  private static unreportedDrops: number = 0;
  private static written: number = 0;
  private static readonly fileLimit: number = 4 * 1024 * 1024;
  private static readonly queueLimit: number = 2 * 1024 * 1024;
  static error: string = '';
  static initialize(filesDir: string): void {
    if (LogStore.directory) { return; }
    LogStore.directory = filesDir + '/diagnostics';
    CommunicationLog.sink = (text: string): void => LogStore.buffer(text);
    LogStore.serialize(async (): Promise<void> => {
      if (!await fs.access(LogStore.directory)) { await fs.mkdir(LogStore.directory); }
      if (await fs.access(LogStore.path(0))) { LogStore.size = (await fs.stat(LogStore.path(0))).size; }
      LogStore.ready = true;
    }).catch(() => {});
    CommunicationLog.record('app.started', { reason: 'diagnostics enabled; text retained, credentials and binary redacted' });
  }
  private static path(index: number): string {
    return LogStore.directory + '/communication' + (index === 0 ? '' : '.' + index.toString()) + '.jsonl';
  }
  static summary(): string {
    return (LogStore.ready ? '记录中' : '日志未就绪') + ' · 本次启动已写入 ' + LogStore.written.toString() + ' 条' +
      (LogStore.dropped ? ' · 丢弃 ' + LogStore.dropped.toString() + ' 条（队列满或写入失败）' : '');
  }
  private static serialize(operation: () => Promise<void>): Promise<void> {
    const next = LogStore.io.then(operation);
    LogStore.io = next.catch((error: Error) => { LogStore.error = error.message || '日志文件操作失败'; });
    return next;
  }
  private static buffer(text: string): void {
    const line = new BufferedLine(text);
    if (LogStore.queuedBytes + line.data.byteLength > LogStore.queueLimit) {
      LogStore.dropped++; LogStore.unreportedDrops++; return;
    }
    LogStore.queue.push(line); LogStore.queuedBytes += line.data.byteLength;
    LogStore.schedule();
  }
  private static schedule(): void {
    if (LogStore.timer !== -1 || LogStore.flushing || !LogStore.queue.length) { return; }
    LogStore.timer = setTimeout(() => { LogStore.timer = -1; LogStore.flush().catch(() => {}); }, 250);
  }
  static flush(): Promise<void> {
    if (LogStore.timer !== -1) { clearTimeout(LogStore.timer); LogStore.timer = -1; }
    if (LogStore.flushing) { return LogStore.io; }
    LogStore.flushing = true;
    return LogStore.serialize(() => LogStore.drain()).finally(() => {
      LogStore.flushing = false; LogStore.schedule();
    });
  }
  private static async drain(): Promise<void> {
    const lines = LogStore.queue; LogStore.queue = []; LogStore.queuedBytes = 0;
    if (!lines.length) { return; }
    let committed = 0;
    try {
      if (!LogStore.ready) { throw new Error('日志目录不可写'); }
      let offset = 0;
      while (offset < lines.length) {
        const first = offset; let bytes = 0;
        while (offset < lines.length && (bytes === 0 || bytes + lines[offset].data.byteLength <= 256 * 1024)) {
          bytes += lines[offset++].data.byteLength;
        }
        const batch = new Uint8Array(bytes); let cursor = 0;
        for (let i = first; i < offset; i++) { batch.set(lines[i].data, cursor); cursor += lines[i].data.byteLength; }
        if (LogStore.size + bytes > LogStore.fileLimit) { await LogStore.rotate(); }
        const file = await fs.open(LogStore.path(0), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
        try { await LogStore.writeAll(file.fd, batch); }
        finally { await fs.close(file); }
        LogStore.size += bytes; LogStore.written += offset - first; committed = offset;
      }
      LogStore.error = '';
      if (LogStore.unreportedDrops) {
        const count = LogStore.unreportedDrops; LogStore.unreportedDrops = 0;
        CommunicationLog.record('log.entries_dropped', { count: count, reason: 'bounded queue or file write failure' }, 'warn');
      }
    } catch (error) {
      LogStore.dropped += lines.length - committed; LogStore.unreportedDrops += lines.length - committed;
      throw error as Error;
    }
  }
  private static async writeAll(fd: number, data: Uint8Array): Promise<void> {
    let offset = 0;
    while (offset < data.byteLength) {
      const count = await fs.write(fd, data.buffer.slice(offset));
      if (count <= 0) { throw new Error('日志写入未完成'); }
      offset += count;
    }
  }
  private static async remove(index: number): Promise<void> {
    const path = LogStore.path(index);
    if (await fs.access(path)) { await fs.unlink(path); }
  }
  private static async rotate(): Promise<void> {
    await LogStore.remove(2);
    if (await fs.access(LogStore.path(1))) { await fs.rename(LogStore.path(1), LogStore.path(2)); }
    if (await fs.access(LogStore.path(0))) { await fs.rename(LogStore.path(0), LogStore.path(1)); }
    LogStore.size = 0;
  }
  static async clear(): Promise<void> {
    await LogStore.serialize(async (): Promise<void> => {
      for (let i = 0; i < 3; i++) { await LogStore.remove(i); }
      LogStore.queue = []; LogStore.queuedBytes = 0; LogStore.size = 0;
      LogStore.dropped = 0; LogStore.unreportedDrops = 0; LogStore.written = 0; LogStore.error = '';
    });
  }
  static async export(context: common.UIAbilityContext): Promise<string> {
    const filename = 'Beegent-communication-' + new Date().toISOString().replace(/[:.]/g, '-') + '.jsonl';
    const destinations = await new picker.DocumentViewPicker(context).save({ newFileNames: [filename] });
    if (!destinations.length) { return '已取消导出'; }
    await LogStore.flush();
    await LogStore.serialize(async (): Promise<void> => {
      await LogStore.drain();
      const target = await fs.open(destinations[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        for (let i = 2; i >= 0; i--) {
          if (await fs.access(LogStore.path(i))) {
            const text = await fs.readText(LogStore.path(i));
            await LogStore.writeAll(target.fd, new util.TextEncoder().encodeInto(text));
          }
        }
      } finally { await fs.close(target); }
    });
    return '通信日志已导出';
  }
}
