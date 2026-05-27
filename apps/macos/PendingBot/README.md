# PendingBot macOS

Native macOS shell for PendingBot. This package is intentionally thin: it hosts
`PendingBotBigScreenAppView` from `apps/shared/PendingBotShared` and injects a
small fixture crew list so the first window is not empty.

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
