export const DEFAULT_CHROME_HEADLESS_SHELL_PATH =
  '/usr/bin/chromium-headless-shell';

type ChromeEnv = {
  [key: string]: string | undefined;
  CHROME_HEADLESS_SHELL_PATH?: string;
  CHROMIUM_PATH?: string;
};

export function resolveChromeExecutablePath(env: ChromeEnv = process.env): string {
  return (
    env.CHROME_HEADLESS_SHELL_PATH ||
    env.CHROMIUM_PATH ||
    DEFAULT_CHROME_HEADLESS_SHELL_PATH
  );
}

export function chromeLaunchArgs(): string[] {
  return [
    '--autoplay-policy=no-user-gesture-required',
    '--disable-background-networking',
    '--disable-breakpad',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-dev-shm-usage',
    '--disable-extensions',
    '--disable-features=Translate,MediaRouter',
    '--disable-gpu',
    '--disable-sync',
    '--metrics-recording-only',
    '--no-first-run',
    '--no-sandbox',
    '--password-store=basic',
    '--use-fake-ui-for-media-stream',
  ];
}
