import { image } from '@kit.ImageKit';
import { CommunicationLog } from '../diagnostics/CommunicationLog';
import { requestId } from './Protocol';
import { common, wantConstant } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { systemShare } from '@kit.ShareKit';
import { Attachment } from './RichMessage';

export class AttachmentService {
  private static handoffs: string[] = [];
  static async cleanupHandoffs(): Promise<void> {
    const paths = AttachmentService.handoffs; AttachmentService.handoffs = [];
    for (const path of paths) { try { await fs.unlink(path); } catch (_) {} }
  }
  static async cleanupStartup(context: common.UIAbilityContext): Promise<void> {
    // Remove only this app's temporary attachment files, never user-selected saves.
    try {
      const names = await fs.listFile(context.cacheDir);
      for (const name of names) {
        if (/^jwb-\d+-/.test(name) && !name.includes('/') && !name.includes('\\')) {
          try { await fs.unlink(context.cacheDir + '/' + name); } catch (_) {}
        }
      }
    } catch (_) {}
  }
  async action(context: common.UIAbilityContext, file: Attachment, action: string, sessionId: string = ''): Promise<string> {
    const operationId = requestId(); const started = Date.now();
    CommunicationLog.record('attachment.action.start', { operationId: operationId, sessionId: sessionId, action: action,
      fileId: file.id, name: file.name, mime: file.mime, bytes: file.size, url: file.url, source: file.base64 ? 'base64' : 'http' });
    let path = ''; let handedOff = false;
    try {
      path = await this.obtain(context, file, operationId);
      const uri = fileUri.getUriFromPath(path);
      if (action === 'save') {
        CommunicationLog.record('attachment.save.picker', { operationId: operationId });
        const destinations = await new picker.DocumentViewPicker(context).save({ newFileNames: [this.filename(file.name)] });
        if (!destinations.length) { CommunicationLog.record('attachment.save.cancelled', { operationId: operationId }); return '已取消保存'; }
        const target = await fs.open(destinations[0], fs.OpenMode.WRITE_ONLY);
        try { await fs.copyFile(path, target.fd); } finally { await fs.close(target); }
        CommunicationLog.record('attachment.saved', { operationId: operationId, elapsedMs: Date.now() - started });
        return '已保存';
      }
      if (action === 'share') {
        const type = file.mime.startsWith('image/') ? 'general.image' : file.mime.startsWith('audio/') ? 'general.audio' : file.mime.startsWith('video/') ? 'general.video' : 'general.file';
        const data = new systemShare.SharedData({ utd: type, uri: uri, title: file.name });
        CommunicationLog.record('attachment.share.start', { operationId: operationId });
        await new systemShare.ShareController(data).show(context, { selectionMode: systemShare.SelectionMode.SINGLE, previewMode: systemShare.SharePreviewMode.DETAIL });
        AttachmentService.handoffs.push(path); handedOff = true;
        CommunicationLog.record('attachment.share.returned', { operationId: operationId, elapsedMs: Date.now() - started });
        return '已打开系统分享';
      }
      CommunicationLog.record('attachment.system_open.start', { operationId: operationId, mime: file.mime });
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: uri, type: file.mime,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
        parameters: { 'ohos.ability.params.showDefaultPicker': true } });
      AttachmentService.handoffs.push(path); handedOff = true;
      CommunicationLog.record('attachment.system_open.accepted', { operationId: operationId, elapsedMs: Date.now() - started,
        reason: 'system accepted launch; external display is not verified' });
      return '已交给系统打开';
    } catch (error) {
      CommunicationLog.record('attachment.action.failed', { operationId: operationId, sessionId: sessionId, action: action,
        error: (error as Error).message, elapsedMs: Date.now() - started }, 'error');
      throw error as Error;
    } finally { if (path && !handedOff) { try { await fs.unlink(path); } catch (_) {} } }
  }
  // Preview files are transient: delete them as soon as decoding/reading completes.
  async previewImage(context: common.UIAbilityContext, file: Attachment, sessionId: string, edge: number): Promise<image.PixelMap> {
    const operationId = requestId(); let path = '';
    CommunicationLog.record('attachment.preview.start', { operationId: operationId, sessionId: sessionId, fileId: file.id, name: file.name, url: file.url, action: 'image' });
    try {
      if (!file.available) { throw new Error('服务端未提供可下载内容'); }
      path = await this.fetch(context, file, operationId, 32 * 1024 * 1024);
      const source = image.createImageSource(path);
      try {
        const info = await source.getImageInfo();
        const ratio = Math.min(1, edge / Math.max(info.size.width, info.size.height));
        const bitmap = await source.createPixelMap({ desiredSize: { width: Math.max(1, Math.round(info.size.width * ratio)), height: Math.max(1, Math.round(info.size.height * ratio)) } });
        CommunicationLog.record('attachment.preview.ready', { operationId: operationId, action: 'image' });
        return bitmap;
      } finally { await source.release().catch(() => {}); }
    } catch (error) {
      CommunicationLog.record('attachment.preview.failed', { operationId: operationId, error: (error as Error).message }, 'error'); throw error as Error;
    } finally { if (path) { try { await fs.unlink(path); } catch (_) {} } }
  }
  async previewHtml(context: common.UIAbilityContext, file: Attachment, sessionId: string): Promise<string> {
    const operationId = requestId(); let path = '';
    CommunicationLog.record('attachment.preview.start', { operationId: operationId, sessionId: sessionId, fileId: file.id, name: file.name, url: file.url, action: 'html' });
    try {
      if (!file.available) { throw new Error('服务端未提供可下载内容'); }
      path = await this.fetch(context, file, operationId, 4 * 1024 * 1024);
      const text = await fs.readText(path);
      CommunicationLog.record('attachment.preview.ready', { operationId: operationId, action: 'html', characters: text.length });
      return text.replace(/^\uFEFF/, '');
    } catch (error) {
      CommunicationLog.record('attachment.preview.failed', { operationId: operationId, error: (error as Error).message }, 'error'); throw error as Error;
    } finally { if (path) { try { await fs.unlink(path); } catch (_) {} } }
  }
  private filename(name: string): string { return name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').slice(-120) || 'attachment'; }
  private async obtain(context: common.UIAbilityContext, file: Attachment, operationId: string): Promise<string> {
    if (!file.available) { throw new Error('附件只有电脑本地路径，服务端未提供可下载内容'); }
    await AttachmentService.cleanupHandoffs();
    return this.fetch(context, file, operationId);
  }
  private async fetch(context: common.UIAbilityContext, file: Attachment, operationId: string, limit: number = 128 * 1024 * 1024): Promise<string> {
    if (file.size > limit) { throw new Error('附件超过本次处理大小上限，请保存后使用系统打开'); }
    const path = context.cacheDir + '/jwb-' + Date.now().toString() + '-' + this.filename(operationId) + '-' + this.filename(file.name);
    try {
      if (file.base64) {
        if (file.base64.length > Math.min(70 * 1024 * 1024, Math.ceil(limit * 4 / 3) + 1024)) { throw new Error('附件内容过大，请在电脑端保存'); }
        const bytes = await new util.Base64Helper().decode(file.base64.replace(/^data:[^,]+,/, ''));
        if (bytes.byteLength > limit) { throw new Error('附件超过本次处理大小上限'); }
        CommunicationLog.record('attachment.base64.decoded', { operationId: operationId, bytes: bytes.byteLength });
        const target = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { let offset = 0;
          while (offset < bytes.byteLength) {
            const written = await fs.write(target.fd, bytes.buffer.slice(offset));
            if (written <= 0) { throw new Error('附件写入失败'); } offset += written;
          } } finally { await fs.close(target); }
      } else {
        await this.download(file.url, path, operationId, limit);
      }
      return path;
    } catch (error) { try { await fs.unlink(path); } catch (_) {} throw error as Error; }
  }
  private async download(url: string, path: string, operationId: string, limit: number): Promise<void> {
    CommunicationLog.record('attachment.http.start', { operationId: operationId, url: url });
    const started = Date.now(); let reported = 0;
    const client = http.createHttp();
    const target = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    let writes: Promise<void> = Promise.resolve();
    let writeError: Error | undefined;
    let size = 0;
    client.on('dataReceive', (chunk: ArrayBuffer) => {
      size += chunk.byteLength;
      if (size - reported >= 1024 * 1024) { reported = size; CommunicationLog.record('attachment.http.progress', { operationId: operationId, bytes: size, elapsedMs: Date.now() - started }); }
      if (size > limit) { writeError = new Error('附件超过本次处理大小上限，请保存后使用系统打开'); client.destroy(); return; }
      writes = writes.then(async (): Promise<void> => {
        if (writeError) { return; }
        let offset = 0;
        while (offset < chunk.byteLength) {
          const written = await fs.write(target.fd, chunk.slice(offset));
          if (written <= 0) { throw new Error('附件写入失败'); }
          offset += written;
        }
      }).catch((error: Error) => { writeError = error; client.destroy(); });
    });
    const timer = setTimeout(() => { writeError = new Error('附件下载超时，请稍后重试'); client.destroy(); }, 120000);
    try {
      const status = await client.requestInStream(url, { method: http.RequestMethod.GET, connectTimeout: 15000, readTimeout: 60000 });
      await writes;
      CommunicationLog.record('attachment.http.response', { operationId: operationId, status: status, bytes: size, elapsedMs: Date.now() - started });
      if (writeError) { throw writeError; }
      if (status < 200 || status >= 300) { throw new Error('附件下载失败（HTTP ' + status.toString() + '）'); }
    } finally { clearTimeout(timer); client.destroy(); await writes; await fs.close(target); }
  }}
