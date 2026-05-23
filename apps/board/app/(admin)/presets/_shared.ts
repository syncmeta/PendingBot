export type SavePresetState = {
  ok?: boolean;
  error?: string;
  slug?: string;
};

export function formatJson(value: unknown) {
  return JSON.stringify(value ?? [], null, 2);
}
