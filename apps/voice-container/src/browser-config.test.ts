import { describe, expect, it } from 'bun:test';
import {
  chromeLaunchArgs,
  DEFAULT_CHROME_HEADLESS_SHELL_PATH,
  resolveChromeExecutablePath,
} from './browser-config';

describe('browser config', () => {
  it('defaults to the Debian chrome-headless-shell package path', () => {
    expect(resolveChromeExecutablePath({})).toBe(DEFAULT_CHROME_HEADLESS_SHELL_PATH);
    expect(DEFAULT_CHROME_HEADLESS_SHELL_PATH).toBe('/usr/bin/chromium-headless-shell');
  });

  it('prefers chrome-headless-shell over full Chromium when both are configured', () => {
    expect(
      resolveChromeExecutablePath({
        CHROME_HEADLESS_SHELL_PATH: '/opt/chrome-headless-shell/chrome-headless-shell',
        CHROMIUM_PATH: '/usr/bin/chromium',
      }),
    ).toBe('/opt/chrome-headless-shell/chrome-headless-shell');
  });

  it('keeps the headless browser focused on realtime audio automation', () => {
    expect(chromeLaunchArgs()).toEqual(
      expect.arrayContaining([
        '--autoplay-policy=no-user-gesture-required',
        '--disable-extensions',
        '--disable-sync',
        '--no-first-run',
        '--no-sandbox',
        '--use-fake-ui-for-media-stream',
      ]),
    );
  });
});
