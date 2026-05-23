export type RoomMediaTokenContext =
  | { mediaProvider: 'sfu'; adapterToken: string }
  | { mediaProvider: 'realtimekit'; mediaToken: string };

export function roomMediaToken(ctx: RoomMediaTokenContext): string {
  return ctx.mediaProvider === 'realtimekit' ? ctx.mediaToken : ctx.adapterToken;
}
