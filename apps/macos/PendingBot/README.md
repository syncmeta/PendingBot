# PendingBot macOS

Native macOS companion for PendingBot. It hosts `PendingBotBigScreenAppView`
from `apps/shared/PendingBotShared`, logs in through the Edge device-login flow,
then loads real crew data with a `pendingbot_client` device grant.

## Build

From the repository root:

```bash
swift build --package-path apps/macos/PendingBot
```

Or use the helper:

```bash
apps/macos/PendingBot/script/build_and_run.sh --verify
```

## Run

```bash
apps/macos/PendingBot/script/build_and_run.sh
```

The default API URL is `https://api.pendingname.com`. To point at a local Edge
worker, change the API URL field in the app window, save it with the checkmark
button, then log in.

## Login

1. Launch the Mac app.
2. Click `创建设备登录`.
3. Approve the displayed QR payload/code from PendingBot on iPhone or iPad.
4. The Mac app polls `GET /v1/device-login/challenges/:id?secret=...` until the
   Edge API returns a device grant token.
5. The grant token is saved in the macOS Keychain and used as a Bearer token for
   `GET /v1/me/subject`, `GET /v1/crew`, crew detail routes, announcement
   sending, and session creation.

The challenge request uses:

```json
{
  "appKind": "pendingbot_macos",
  "scopes": ["subject:read", "crew:read", "crew:write"]
}
```

The approving PendingBot client should approve it as `grantKind:
pendingbot_client`.
