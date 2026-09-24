export interface LogDetails {
  connectionId?: string; endpoint?: string; requestId?: string; sessionId?: string;
  method?: string; event?: string; direction?: string; frame?: Object;
  state?: string; reason?: string; error?: string; code?: number; elapsedMs?: number;
  characters?: number; bytes?: number; status?: number; matched?: boolean;
  awaitRuntime?: boolean; generation?: number; action?: string; operationId?: string;
  fileId?: string; name?: string; mime?: string; url?: string; source?: string;
  target?: string; count?: number; truncated?: boolean; preview?: string;
}
class LogEntry {
  version: number = 1;
  time: string = new Date().toISOString();
  runId: string = CommunicationLog.runId;
  sequence: number;
  level: string;
  event: string;
  details: LogDetails;
  constructor(sequence: number, event: string, details: LogDetails, level: string) {
    this.sequence = sequence; this.event = event; this.details = details; this.level = level;
  }
}

// Platform-independent instrumentation. The file sink is attached by EntryAbility.
// Diagnostics must never throw into the message path or alter a wire payload.
export class CommunicationLog {
  static readonly runId: string = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 9);
  static sink: (line: string) => void = () => {};
  private static sequence: number = 0;
  static record(event: string, details: LogDetails = {}, level: string = 'info'): void {
    try {
      const entry = new LogEntry(++CommunicationLog.sequence, event, details, level);
      let line = CommunicationLog.serialize(entry, 0);
      if (line.length > 128 * 1024) {
        entry.details = { connectionId: details.connectionId, endpoint: details.endpoint,
          requestId: details.requestId, sessionId: details.sessionId, method: details.method,
          event: details.event, direction: details.direction, truncated: true,
          characters: line.length, preview: line.slice(0, 120 * 1024) };
        line = CommunicationLog.serialize(entry, 0);
      }
      CommunicationLog.sink(line + '\n');
    } catch (_) { /* A failed diagnostic must not interrupt chat. */ }
  }
  private static serialize(value: Object, depth: number): string {
    return JSON.stringify(value, (key: string, item: Object): Object => {
      if (/token$|password|passwd|secret|api[_-]?key|access[_-]?key|authorization|cookie|credential/i.test(key)) {
        return '[REDACTED]';
      }
      if (typeof item !== 'string') { return item; }
      if (/base64|binary|file_bytes/i.test(key)) { return '[BINARY OMITTED: ' + item.length.toString() + ' characters]'; }
      // Tool arguments and history messages sometimes contain another serialized JSON object.
      const first = item.trim().charAt(0);
      if (depth < 3 && (first === '{' || first === '[')) {
        try { return CommunicationLog.serialize(JSON.parse(item) as Object, depth + 1); } catch (_) {}
      }
      return CommunicationLog.scrubText(item);
    });
  }
  private static scrubText(value: string): string {
    return value.replace(/data:[^\s,;]+(?:;[^,\s]*)?;base64,[A-Za-z0-9+/=_-]+/gi, '[DATA URI OMITTED]')
      .replace(/([?&](?:[^=&#\s]*(?:token|secret|api[_-]?key|signature|credential|password)[^=&#\s]*)=)[^&#\s"'\\]+/gi, '$1[REDACTED]')
      .replace(/((?:Bearer|Basic)\s+)[A-Za-z0-9._~+/=-]+/gi, '$1[REDACTED]')
      .replace(/(https?:\/\/)[^\s/@]+:[^\s/@]+@/gi, '$1[REDACTED]@')
      .replace(/\bsk-[A-Za-z0-9_-]{12,}\b/g, '[REDACTED]')
      .replace(/((?:api[_-]?key|password|secret|access[_-]?token)\s*[:=]\s*)[^\s,;]+/gi, '$1[REDACTED]')
      .replace(/[A-Za-z0-9+/=_-]{4096,}/g, '[LONG ENCODED VALUE OMITTED]');
  }
}
