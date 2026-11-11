// 管理画面(React + Astryx)のE2E UIテスト。使い方: node ui-test.mjs <phase: A|B> [user]
// A: ユーザ追加 → コピー → ダウンロード検証  /  B: 再発行 → 削除
import { chromium } from 'playwright';
import fs from 'node:fs';

const BASE = process.env.BASE || 'https://localhost:8443';
const OUT = process.env.OUT || '/evidence';
const PASS = process.env.ADMIN_PASSWORD;
const phase = process.argv[2] || 'A';
const USER = process.argv[3] || 'uitest';
const log = [];
let failed = 0;
const rec = (name, ok, detail = '') => {
  if (!ok) failed++;
  const line = `${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`;
  console.log(line); log.push(line);
};
const shot = (page, n) => page.screenshot({ path: `${OUT}/${n}.png`, fullPage: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({
  ignoreHTTPSErrors: true,
  httpCredentials: { username: 'admin', password: PASS },
  acceptDownloads: true,
  viewport: { width: 1180, height: 900 },
  permissions: ['clipboard-read', 'clipboard-write'],
});
const page = await ctx.newPage();
page.on('pageerror', (e) => rec('no page JS error', false, e.message));
await page.goto(BASE + '/');
await page.getByRole('heading', { name: 'VPN ユーザ管理' }).waitFor();

async function saveDownload(trigger, expectName) {
  const [dl] = await Promise.all([page.waitForEvent('download'), trigger()]);
  const p = `${OUT}/dl-${dl.suggestedFilename()}`;
  await dl.saveAs(p);
  const buf = fs.readFileSync(p);
  rec(`download ${expectName}`, dl.suggestedFilename() === expectName && buf.length > 100, `${dl.suggestedFilename()} ${buf.length}B`);
  return buf;
}

process.on('uncaughtException', async () => {});
async function diag(e) {
  console.log('ERROR', String(e).split('\n')[0]);
  await page.screenshot({ path: `${OUT}/fail-${phase}.png`, fullPage: true });
  console.log('dialog elements:', await page.locator('dialog').count(), 'role=dialog:', await page.locator('dialog[open]').count());
  console.log((await page.locator('body').innerText()).slice(0, 600));
  await browser.close(); process.exit(2);
}
try {
if (phase === 'A') {
  await shot(page, '01-list');
  rec('一覧表示 (既存ユーザ)', await page.getByRole('row').count() > 1);

  // 不正なユーザ名 → エラー表示
  await page.getByRole('textbox', { name: /^ユーザ名/ }).fill('bad name!');
  await page.getByRole('button', { name: '追加' }).click();
  await page.getByText('ユーザ名は英数字').waitFor();
  rec('不正なユーザ名はエラー表示', true);
  await shot(page, '02-invalid-username');

  // 追加
  await page.getByRole('textbox', { name: /^ユーザ名/ }).fill(USER);
  await page.getByRole('button', { name: '追加' }).click();
  const dlg = page.locator('dialog[open]');
  await dlg.getByText(`${USER} を追加しました`).waitFor();
  const code = dlg.locator('code');
  const vpnPw = (await code.nth(0).innerText()).trim();
  const p12Pw = (await code.nth(1).innerText()).trim();
  rec('追加ダイアログにVPNパスワード/p12パスワード表示', vpnPw.length >= 12 && p12Pw.length >= 8, `pw=${vpnPw.length}文字 p12pw=${p12Pw.length}文字`);
  await page.waitForTimeout(700);
  await shot(page, '03-issued-dialog');

  // コピー
  const copyBtns = dlg.getByRole('button', { name: 'コピー' });
  await copyBtns.nth(0).click();
  rec('VPNパスワードをクリップボードへコピー', (await page.evaluate(() => navigator.clipboard.readText())) === vpnPw);
  await dlg.getByRole('button', { name: 'コピー' }).nth(0).waitFor({ state: 'visible' }).catch(() => {});
  await copyBtns.nth(1).click();
  rec('p12パスワードをクリップボードへコピー', (await page.evaluate(() => navigator.clipboard.readText())) === p12Pw);
  await shot(page, '04-copied');

  // ダウンロード(ダイアログ内)
  const p12 = await saveDownload(() => dlg.getByRole('button', { name: '.p12' }).click(), `${USER}.p12`);
  const crt = await saveDownload(() => dlg.getByRole('button', { name: '証明書 PEM' }).click(), `${USER}.crt.pem`);
  const key = await saveDownload(() => dlg.getByRole('button', { name: '秘密鍵 PEM' }).click(), `${USER}.key.pem`);
  rec('PEM証明書の形式', crt.toString().startsWith('-----BEGIN CERTIFICATE-----'));
  rec('PEM秘密鍵の形式', key.toString().startsWith('-----BEGIN PRIVATE KEY-----'));
  rec('p12はDER(0x30)で始まる', p12[0] === 0x30);
  fs.writeFileSync(`${OUT}/.creds-${USER}`, JSON.stringify({ vpnPw, p12Pw }));

  await dlg.getByRole('button', { name: '閉じる' }).click();
  const row = page.getByRole('row', { name: new RegExp(USER) });
  await row.waitFor();
  rec('一覧に新規ユーザが表示', true);
  await shot(page, '05-list-after-add');

  // パスワード再表示 (ダイアログを閉じた後でも確認できる)
  await row.getByRole('button', { name: 'パスワード' }).click();
  const view = page.locator('dialog[open]');
  await view.getByText(`${USER} の認証情報`).waitFor();
  const vcode = view.locator('code');
  rec('再表示: VPNパスワードが追加時と一致', (await vcode.nth(0).innerText()).trim() === vpnPw);
  rec('再表示: p12パスワードが追加時と一致', (await vcode.nth(1).innerText()).trim() === p12Pw);
  await page.waitForTimeout(700);
  await shot(page, '05b-redisplay');
  await view.getByRole('button', { name: 'コピー' }).nth(0).click();
  rec('再表示: コピーボタンで取得したパスワードが一致', (await page.evaluate(() => navigator.clipboard.readText())) === vpnPw);
  await view.getByRole('button', { name: '閉じる' }).click();

  // 一覧からのダウンロード + CA
  await saveDownload(() => row.getByRole('button', { name: '.p12' }).click(), `${USER}.p12`);
  const ca = await saveDownload(() => page.getByRole('button', { name: /CA 証明書/ }).click(), 'ca.crt');
  rec('CA証明書の形式', ca.toString().startsWith('-----BEGIN CERTIFICATE-----'));
}

if (phase === 'B') {
  const before = JSON.parse(fs.readFileSync(`${OUT}/.creds-${USER}`, 'utf8'));
  const row = page.getByRole('row', { name: new RegExp(USER) });
  await row.getByRole('button', { name: '再発行' }).click();
  await page.waitForTimeout(700);
  await shot(page, '06-reissue-confirm');
  await page.locator('dialog[open]').getByRole('button', { name: '再発行' }).click();
  const dlg = page.locator('dialog[open]');
  await dlg.getByText(`${USER} を再発行しました`).waitFor();
  const pw2 = (await dlg.locator('code').nth(0).innerText()).trim();
  rec('再発行でパスワードが変わる', pw2 !== before.vpnPw && pw2.length >= 12);
  await shot(page, '07-reissued');
  fs.writeFileSync(`${OUT}/.creds-${USER}`, JSON.stringify({ vpnPw: pw2, p12Pw: (await dlg.locator('code').nth(1).innerText()).trim() }));
  await dlg.getByRole('button', { name: '閉じる' }).click();
}

if (phase === 'D') {
  // 認証情報付きURLで開いても一覧が表示される (fetch の "includes credentials" エラーの回帰テスト)
  const c2 = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1180, height: 900 } });
  const p2 = await c2.newPage();
  const errs = [];
  p2.on('pageerror', (e) => errs.push(e.message));
  const u = new URL(BASE + '/'); u.username = 'admin'; u.password = PASS;
  await p2.goto(u.toString());
  await p2.getByRole('heading', { name: 'VPN ユーザ管理' }).waitFor();
  await p2.getByRole('row').nth(1).waitFor();
  rec('認証情報付きURLでも一覧が表示される', await p2.getByRole('row').count() > 1);
  rec('エラーバナーが出ない', await p2.getByText('Request cannot be constructed').count() === 0 && errs.length === 0, errs.join('|'));
  const href = await p2.evaluate(() => location.href);   // パスワードをログに出さないため値は表示しない
  rec('URLから認証情報が除去される', !href.includes('@') && !href.includes(PASS));
  await p2.screenshot({ path: `${OUT}/10-url-credentials.png`, fullPage: true });
}

if (phase === 'C') {
  const row = page.getByRole('row', { name: new RegExp(USER) });
  await row.getByRole('button', { name: '削除' }).click();
  await page.waitForTimeout(700);
  await shot(page, '08-delete-confirm');
  await page.locator('dialog[open]').getByRole('button', { name: '削除' }).click();
  await row.waitFor({ state: 'detached' });
  rec('削除後に一覧から消える', true);
  await shot(page, '09-after-delete');
}

} catch (e) { await diag(e); }
fs.writeFileSync(`${OUT}/ui-phase-${phase}.log`, log.join('\n') + '\n');
await browser.close();
process.exit(failed ? 1 : 0);
