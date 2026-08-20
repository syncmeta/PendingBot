export type RoomMediaTokenContext = { mediaToken: string };

export function roomMediaToken(ctx: RoomMediaTokenContext): string {
  return ctx.mediaToken;
}
