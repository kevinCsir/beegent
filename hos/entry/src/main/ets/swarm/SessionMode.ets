export type AgentRole = 'agent' | 'team';
export type WorkProfile = 'work' | 'code';
export type ExecutionStyle = 'normal' | 'plan';

export class SessionMode {
  role: AgentRole;
  profile: WorkProfile;
  style: ExecutionStyle;
  constructor(role: AgentRole = 'agent', profile: WorkProfile = 'work', style: ExecutionStyle = 'normal') {
    this.role = role; this.profile = profile; this.style = style;
  }
  wire(): string { return this.role + '.' + this.profile + '.' + this.style; }
  label(): string {
    return (this.role === 'agent' ? '单 Agent' : 'Team') + ' · ' +
      (this.profile === 'work' ? '通用工作' : '代码项目') + ' · ' +
      (this.style === 'normal' ? '直接执行' : '计划优先');
  }
  copy(): SessionMode { return new SessionMode(this.role, this.profile, this.style); }
}

export type QueueStatus = 'queued' | 'sending' | 'failed' | 'unknown' | 'accepted';
export class QueuedMessage {
  id: string;
  content: string;
  status: QueueStatus = 'queued';
  error: string = '';
  requestId: string = '';
  constructor(id: string, content: string) { this.id = id; this.content = content; }
  copy(): QueuedMessage {
    const result = new QueuedMessage(this.id, this.content);
    result.status = this.status; result.error = this.error; result.requestId = this.requestId;
    return result;
  }
  statusLabel(): string {
    switch (this.status) {
      case 'sending': return '等待接收确认';
      case 'failed': return '补充未成功';
      case 'unknown': return '结果待确认，请勿重发';
      default: return '等待发送';
    }
  }
}
