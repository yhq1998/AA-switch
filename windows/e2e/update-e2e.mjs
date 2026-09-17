// 端到端验证应用内更新（只能在 Windows 上跑）：本机起一个“官网”，放 latest.json 和新版本的 exe，让旧版本自己更新自己。
//   node e2e/update-e2e.mjs <旧版本 exe> <新版本 exe> <新版本号>
// 会把旧版本复制到临时目录再操作，不动传进来的文件。
import http from 'node:http';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const [oldSrc, newSrc, newVersion] = process.argv.slice(2);
if (!oldSrc || !newSrc || !newVersion) { console.error('用法：node update-e2e.mjs <旧 exe> <新 exe> <新版本号>'); process.exit(2); }
const sha = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aaswitch-update-'));
const exe = path.join(dir, 'AA Switch.exe');
fs.copyFileSync(oldSrc, exe);
const oldSha = sha(exe), newSha = sha(newSrc);

let advertisedSha = newSha;
const server = http.createServer((req, res) => {
  if (req.url.endsWith('/latest.json')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ version: '99.0.0', windows: { version: newVersion, date: '2026-01-01', url: `http://127.0.0.1:${server.address().port}/download/AA%20Switch.exe`, sha256: advertisedSha } }));
  }
  res.writeHead(200, { 'content-type': 'application/octet-stream' });
  fs.createReadStream(newSrc).pipe(res);
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const env = { ...process.env, AASWITCH_UPDATE_URL: `http://127.0.0.1:${server.address().port}/download/latest.json` };

let failed = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || !detail ? '' : '\n      ' + detail}`); if (!ok) failed++; };
const run = (args, timeoutMs = 180000) => new Promise(resolve => {
  const child = spawn(exe, args, { env, windowsHide: true });
  const timer = setTimeout(() => child.kill(), timeoutMs);
  child.on('error', e => { clearTimeout(timer); resolve(-1); });
  child.on('close', code => { clearTimeout(timer); resolve(code); });
});

advertisedSha = 'f'.repeat(64);
let code = await run(['--update-now']);
check('校验值对不上：拒绝更新，现有程序没被动过', code === 1 && sha(exe) === oldSha && !fs.existsSync(exe + '.old'), `exit ${code}`);

advertisedSha = newSha;
code = await run(['--update-now']);
check('下载、校验、替换成功', code === 0, `exit ${code}`);
check('原位置现在是新版本，旧版本改名成 .old', sha(exe) === newSha && fs.existsSync(exe + '.old') && sha(exe + '.old') === oldSha);

const log = path.join(process.env.LOCALAPPDATA ?? '', 'AA Switch', 'aa-switch.log');
code = await run(['--update-now']);
const lastLine = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').pop() : '';
check('新版本能启动，并且认为自己已是最新', code === 1 && lastLine.includes('没有比当前更新的版本') && sha(exe) === newSha, `exit ${code}，日志：${lastLine}`);

server.close();
if (failed && fs.existsSync(log)) console.log(fs.readFileSync(log, 'utf8').split('\n').slice(-25).join('\n'));
console.log(failed ? `\n${failed} 项失败` : '\n全部通过');
process.exit(failed ? 1 : 0);
