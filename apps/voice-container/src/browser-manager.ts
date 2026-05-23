import puppeteer, { type Browser, type Page } from 'puppeteer-core';
import { chromeLaunchArgs, resolveChromeExecutablePath } from './browser-config';

let browserPromise: Promise<Browser> | null = null;
let openPages = 0;

async function sharedBrowser(): Promise<Browser> {
  if (!browserPromise) {
    browserPromise = puppeteer
      .launch({
        executablePath: resolveChromeExecutablePath(),
        headless: true,
        args: chromeLaunchArgs(),
      })
      .then((browser) => {
        browser.on('disconnected', () => {
          browserPromise = null;
          openPages = 0;
        });
        return browser;
      });
  }
  return browserPromise;
}

async function closeBrowserIfIdle(): Promise<void> {
  if (openPages > 0 || !browserPromise) return;
  const browser = await browserPromise.catch(() => null);
  browserPromise = null;
  if (browser?.connected) await browser.close().catch(() => undefined);
}

export async function newRealtimeKitPage(): Promise<Page> {
  const browser = await sharedBrowser();
  const page = await browser.newPage();
  openPages++;
  page.once('close', () => {
    openPages = Math.max(0, openPages - 1);
    void closeBrowserIfIdle();
  });
  return page;
}

export async function closeRealtimeKitBrowser(): Promise<void> {
  openPages = 0;
  await closeBrowserIfIdle();
}
