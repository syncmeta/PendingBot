import { Hono } from 'hono';
import type { AppBindings } from '../types';

// Apple App Site Association — served at
// https://bot.pendingname.com/.well-known/apple-app-site-association
//
// Apple fetches this when the app is installed (and via the CDN otherwise)
// to verify the applinks: entitlement on the iOS side. Must be HTTPS,
// content-type application/json, and reachable without redirects.
//
// appIDs format: <TeamID>.<BundleID>
//   Team M42BKJN82S
//   Bundle com.pendingname.pendingbot
//
// Path components currently covered:
//   /c/*  contact-share QR (see Components/QRScannerView.swift)
//   /g/*  group invite (see Features/Group/GroupJoinView.swift)
//   /b/*  bot share (see Sources/Models/ShareLinks.swift) — invite-token
//         based: the path component is an inviter-scoped, revocable invite
//         token (minted by POST /v1/bots/:id/invite-links), not the bot slug.
//   /d/*  device login QR for approving Mac apps from the signed-in iOS app.
const AASA = {
  applinks: {
    details: [
      {
        appIDs: ['M42BKJN82S.com.pendingname.pendingbot'],
        components: [
          { '/': '/c/*', comment: 'contact share' },
          { '/': '/g/*', comment: 'group invite' },
          { '/': '/b/*', comment: 'bot share' },
          { '/': '/d/*', comment: 'device login' },
        ],
      },
    ],
  },
} as const;

export const wellKnownRoutes = new Hono<AppBindings>();

wellKnownRoutes.get('/apple-app-site-association', (c) => {
  return c.json(AASA);
});
