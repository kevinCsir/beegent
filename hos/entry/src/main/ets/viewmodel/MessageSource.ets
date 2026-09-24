import { SubagentView } from '../swarm/Subagents';
import { Step, Attachment, Interaction } from '../swarm/RichMessage';
import { MarkdownBlock, markdown } from '../swarm/Markdown';
import { ChatMessage } from '../swarm/SwarmSession';
@Observed
export class MessageView {
  id: string;
  role: string;
  text: string;
  delivery: string;
  kind: string = 'text';
  steps: Step[] = [];
  attachments: Attachment[] = [];
  interaction?: Interaction; subagent?: SubagentView;
  collapse: boolean = false;
  collapseVersion: number = 0;
  answerId: string = '';
  showHeader: boolean = true;
  blocks: MarkdownBlock[] = [];
  revision: number = 0;
  constructor(message: ChatMessage) {
    this.id = message.id; this.role = message.role; this.text = message.text; this.delivery = message.delivery; this.update(message);
  }
  update(message: ChatMessage): void {
    this.text = message.text; this.delivery = message.delivery; this.kind = message.kind;
    this.steps = message.steps.slice(); this.attachments = message.attachments.slice();
    this.answerId = message.answerId; this.collapseVersion = message.collapseVersion;
    this.subagent = message.subagent?.copy(); this.interaction = message.interaction; this.collapse = message.collapse;
    this.blocks = message.role === 'assistant' && message.kind === 'text' ? markdown(message.text) : [];
    this.revision++;
  }
}
export class MessageSource implements IDataSource {
  private rows: MessageView[] = [];
  private indices: Map<string, number> = new Map();
  private listeners: DataChangeListener[] = [];
  private makeView(message: ChatMessage): MessageView {
    const view = new MessageView(message);
    const previous = this.rows.length ? this.rows[this.rows.length - 1] : undefined;
    view.showHeader = !(view.role === 'assistant' && previous?.role === 'assistant' && !!view.answerId && previous.answerId === view.answerId);
    return view;
  }
  totalCount(): number { return this.rows.length; }
  getData(index: number): MessageView { return this.rows[index]; }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) { this.listeners.splice(index, 1); }
  }
  bind(messages: ChatMessage[]): void {
    this.rows = []; this.indices.clear();
    messages.forEach((message: ChatMessage) => { this.indices.set(message.id, this.rows.length); this.rows.push(this.makeView(message)); });
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
  update(message: ChatMessage): void {
    const index = this.indices.get(message.id);
    if (index === undefined) {
      const next = this.rows.length;
      this.indices.set(message.id, next); this.rows.push(this.makeView(message));
      this.listeners.forEach((listener: DataChangeListener) => listener.onDataAdd(next));
    } else {
      // Keep row identity: only the corresponding @ObjectLink component updates.
      this.rows[index].update(message);
    }
  }
}


