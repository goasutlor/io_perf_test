/**
 * Generates README screenshots for io_compare.html.
 * Requires: python -m http.server 8765 (repo root) and npm install (playwright).
 * Usage: node scripts/capture-readme-screenshots.mjs
 */
import { chromium } from 'playwright';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const outDir = path.join(root, 'docs', 'screenshots');
const base = 'http://127.0.0.1:8765/io_compare.html';
const csvA = path.join(root, 'sweep_results_1.csv');
const csvB = path.join(root, 'sweep_results2.csv');

fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

async function shot(name, fullPage = false) {
  const p = path.join(outDir, name);
  await page.screenshot({ path: p, fullPage, type: 'png' });
  console.log('Wrote', p);
}

// Landing (release + profile table)
await page.goto(base, { waitUntil: 'networkidle' });
await page.waitForTimeout(400);
await shot('io_compare-01-landing.png', true);

// Single-system report
await page.setInputFiles('#fileA', csvA);
await page.waitForTimeout(200);
await page.click('#btnRun');
await page.waitForSelector('#results', { state: 'visible', timeout: 15000 });
await page.waitForTimeout(800);
await shot('io_compare-02-overview.png', false);

// Latency tab
await page.waitForSelector('#tabBar .tab', { timeout: 5000 });
await page.locator('#tabBar .tab').nth(1).click();
await page.waitForTimeout(600);
await shot('io_compare-03-latency-tab.png', false);

// Compare mode
await page.goto(base, { waitUntil: 'networkidle' });
await page.getByRole('button', { name: 'Compare 2 Systems' }).click();
await page.setInputFiles('#fileA', csvA);
await page.setInputFiles('#fileB', csvB);
await page.waitForTimeout(200);
await page.click('#btnRun');
await page.waitForSelector('#results', { state: 'visible', timeout: 15000 });
await page.waitForTimeout(800);
await shot('io_compare-04-compare-overview.png', false);

await browser.close();
console.log('Done.');
