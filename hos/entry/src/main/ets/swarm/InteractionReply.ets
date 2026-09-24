import { Params } from './Protocol';
import { Answer, Interaction, PlanAction } from './RichMessage';
export class Reply {
  method: string; params: Params; runtime: boolean;
  constructor(method: string, params: Params, runtime: boolean = false) { this.method = method; this.params = params; this.runtime = runtime; }
}
export function interactionReply(sessionId: string, mode: string, interaction: Interaction, answers: Answer[]): Reply {
  if (answers.length !== interaction.questions.length || answers.length === 0) { throw new Error('请回答全部问题'); }
  const structuredPlan = interaction.planKind === 'plan_approval' && interaction.planActions.length > 0;
  if (structuredPlan && answers.length !== 1) { throw new Error('计划审批问题结构无效'); }
  answers.forEach((answer: Answer, index: number) => {
    const question = interaction.questions[index];
    if (answer.question !== question.question || (!answer.selected_options.length && !answer.custom_input?.trim())) { throw new Error('请选择选项或填写补充内容'); }
    if (!question.multi_select && answer.selected_options.length > 1) { throw new Error('此问题只能选择一项'); }
    if (structuredPlan) {
      const selected = answer.selected_options;
      const action = interaction.planActions.find((item: PlanAction) => item.value === selected[0]);
      if (selected.length !== 1 || !action || !['plan_execute', 'plan_skip', 'plan_revise'].includes(action.value)) { throw new Error('请选择服务端提供的计划操作'); }
      const input = answer.custom_input?.trim() || '';
      if ((action.value === 'plan_revise' || action.requires_input === 'yes') && !input) { throw new Error('请填写计划修改意见'); }
      if ((action.value === 'plan_skip' || action.requires_input === 'empty') && input) { throw new Error('已有修改意见，请选择下一步'); }
      answer.custom_input = input;
    } else if (answer.selected_options.some((value: string) => !(question.options || []).some((option) => (option.value || option.label) === value))) { throw new Error('选项已变化，请重新选择'); }
    answer.card_id = question.card_id;
  });
  if (interaction.source === 'swarmflow_human') {
    if (!interaction.flow?.run_id || !interaction.flow.correlation_id) { throw new Error('缺少流程回复标识，请在电脑端处理'); }
    return new Reply('chat.swarmflow_reply', { session_id: sessionId, run_id: interaction.flow.run_id,
      correlation_id: interaction.flow.correlation_id, answer: answers.map((a: Answer) => a.custom_input || a.selected_options.join('、')).join('\n') });
  }
  const params: Params = { session_id: sessionId, request_id: interaction.id, answers: answers, source: interaction.source };
  if (interaction.approvalSchema) { params.approval_schema = interaction.approvalSchema; }
  if (interaction.evolution) { params.evolution_meta = interaction.evolution; }
  const interrupt = ['permission_interrupt', 'confirm_interrupt', 'ask_user_interrupt', 'evolution_interrupt'].includes(interaction.source) ||
    interaction.source === 'skill_evolution_approval' && interaction.evolution?.approval_transport === 'interrupt';
  if (interrupt) {
    params.query = ''; params.mode = mode;
    if (interaction.planKind) { params.plan_approval_kind = interaction.planKind; }
    if (interaction.planContent) { params.plan_content = interaction.planContent; }
    if (interaction.planLanguage) { params.plan_language = interaction.planLanguage; }
    return new Reply('chat.send', params, interaction.source === 'permission_interrupt' && !!answers[0].card_id);
  }
  if (interaction.source === 'auto_harness' || interaction.source === 'activate_confirm') { throw new Error('此工作流暂需在电脑端确认'); }
  return new Reply('chat.user_answer', params);
}
