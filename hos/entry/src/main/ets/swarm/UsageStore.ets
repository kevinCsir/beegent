// Usage notifications have no UI and are discarded, including metadata and summaries.
export function isUsageEvent(event: string): boolean {
  return /^(context|chat)\.usage(?:[._]|$)/.test(event);
}
