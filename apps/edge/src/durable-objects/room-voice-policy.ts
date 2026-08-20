export function isCallAdminTargetPresent(
  targetId: string,
  humanIds: Iterable<string>,
  botIds: Iterable<string>,
): boolean {
  if (!targetId) return false;
  for (const humanId of humanIds) {
    if (humanId === targetId) return true;
  }
  for (const botId of botIds) {
    if (botId === targetId) return true;
  }
  return false;
}
