export class Inline {
  text: string; style: string; url: string;
  constructor(text: string, style: string = '', url: string = '') { this.text = text; this.style = style; this.url = url; }
}
export class MarkdownBlock {
  id: string; kind: string; text: string; level: number; spans: Inline[];
  constructor(id: string, kind: string, text: string, level: number = 0) {
    this.id = id; this.kind = kind; this.text = text; this.level = level;
    this.spans = kind === 'code' ? [new Inline(text)] : inline(text);
  }
}
export function inline(text: string): Inline[] {
  const result: Inline[] = [];
  const pattern = /(!?\[([^\]]+)\]\(([^\s)]+)\)|\*\*([^*]+)\*\*|`([^`]+)`|~~([^~]+)~~|\*([^*]+)\*)/g;
  let cursor = 0; let match: RegExpExecArray | null;
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > cursor) { result.push(new Inline(text.slice(cursor, match.index))); }
    if (match[2]) { result.push(new Inline(match[1].startsWith('!') ? '图片：' + match[2] : match[2], 'link', /^https?:\/\//i.test(match[3]) ? match[3] : '')); }
    else if (match[4]) { result.push(new Inline(match[4], 'bold')); }
    else if (match[5]) { result.push(new Inline(match[5], 'code')); }
    else if (match[6]) { result.push(new Inline(match[6], 'strike')); }
    else { result.push(new Inline(match[7], 'italic')); }
    cursor = pattern.lastIndex;
  }
  if (cursor < text.length) { result.push(new Inline(text.slice(cursor))); }
  return result;
}
export function markdown(text: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = []; const lines = text.replace(/\r\n/g, '\n').split('\n');
  let buffer: string[] = []; let fence = ''; let code: string[] = [];
  const add = (kind: string, value: string, level: number = 0): void => { blocks.push(new MarkdownBlock(blocks.length.toString(), kind, value, level)); };
  const flush = (): void => { if (buffer.length) { add('paragraph', buffer.join('\n')); buffer = []; } };
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]; const marker = /^\s*(```+|~~~+)/.exec(line);
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length) { add('code', code.join('\n')); code = []; fence = ''; }
      else { code.push(line); } continue;
    }
    if (marker) { flush(); fence = marker[1]; continue; }
    if (!line.trim()) { flush(); continue; }
    const heading = /^(#{1,6})\s+(.+)$/.exec(line);
    if (heading) { flush(); add('heading', heading[2], heading[1].length); continue; }
    if (/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line)) { flush(); add('rule', ''); continue; }
    if (/^\s*>/.test(line)) { flush(); add('quote', line.replace(/^\s*>\s?/, '')); continue; }
    if (/^\s*([-+*]|\d+[.)])\s+/.test(line)) { flush(); add('list', line.replace(/^(\s*)[-+*]\s+/, '$1• ')); continue; }
    if (line.includes('|') && index + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[index + 1])) {
      flush(); const table: string[] = [line]; index++;
      while (index + 1 < lines.length && lines[index + 1].includes('|')) { table.push(lines[++index]); }
      add('code', table.join('\n')); continue;
    }
    buffer.push(line);
  }
  if (fence) { add('code', code.join('\n')); } flush(); return blocks;
}
