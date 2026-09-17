// 端到端验证：真的 codex 命令行 + 本地假网关（OpenAI Responses 接口），确认 aaswitch 切换后 Codex 的请求确实换了去向。
//   node e2e/codex-e2e.mjs <aaswitch 可执行文件路径>
// GitHub Actions 的 windows-latest 上用真实的 ~\.codex 和凭据管理器；本机调试时设 E2E_ISOLATED=1，改用临时目录、不检查 Codex 进程。
import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const exe = path.resolve(process.argv[2] ?? '');
if (!fs.existsSync(exe)) { console.error('用法：node codex-e2e.mjs <aaswitch 路径>'); process.exit(2); }

const KEY = 'sk-e2e-not-a-real-key';
const REPLY = 'pong-from-mock-gateway';
const env = { ...process.env };
for (const k of ['OPENAI_API_KEY', 'OPENAI_BASE_URL', 'CODEX_API_KEY']) delete env[k];
let home = path.join(os.homedir(), '.codex');
if (process.env.E2E_ISOLATED === '1') {
  home = env.CODEX_HOME = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'aaswitch-e2e-')), '.codex');
  env.CODEX_MODE_FORCE = '1';   // 本机可能开着 Codex 应用
}
const codexBin = env.CODEX_BIN || 'codex';

// ---------- 假网关 ----------
const seen = [];
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    seen.push({ method: req.method, url: req.url, auth: req.headers.authorization ?? '', xtest: req.headers['x-e2e-test'] ?? '' });
    if (req.method === 'GET') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"object":"list","data":[]}'); }
    const events = [
      { type: 'response.created', response: { id: 'resp_e2e' } },
      { type: 'response.output_item.done', item: { type: 'message', role: 'assistant', id: 'msg_e2e', content: [{ type: 'output_text', text: REPLY }] } },
      { type: 'response.completed', response: { id: 'resp_e2e', usage: { input_tokens: 1, input_tokens_details: null, output_tokens: 1, output_tokens_details: null, total_tokens: 2 } } },
    ];
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end(events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''));
  });
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/v1`;

// ---------- 工具 ----------
let failed = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || !detail ? '' : '\n      ' + detail}`); if (!ok) failed++; };
const run = (cmd, args, input = '', timeoutMs = 120000) => new Promise(resolve => {
  const child = spawn(cmd, args, { env, shell: process.platform === 'win32' && !cmd.endsWith('.exe'), windowsHide: true });
  let out = '';
  child.stdout.on('data', d => out += d); child.stderr.on('data', d => out += d);
  const timer = setTimeout(() => { out += '\n[e2e: timeout]'; child.kill(); }, timeoutMs);
  child.on('error', e => { clearTimeout(timer); resolve({ code: -1, out: String(e) }); });
  child.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
  child.stdin.end(input);
});
const config = () => { try { return fs.readFileSync(path.join(home, 'config.toml'), 'utf8'); } catch { return ''; } };
const responses = () => seen.filter(r => r.method === 'POST' && r.url.startsWith('/v1/responses'));

// ---------- 准备：一条账号时期的会话（文件 + 状态库），切换后应改记为默认 provider ----------
fs.mkdirSync(path.join(home, 'sessions', '2026', '01', '02'), { recursive: true });
const session = path.join(home, 'sessions', '2026', '01', '02', 'rollout-e2e.jsonl');
fs.writeFileSync(session, '{"timestamp":"2026-01-02T00:00:00Z","type":"session_meta","payload":{"id":"e2e","model_provider":"openai"}}\n{"type":"event_msg","model_provider":"openai"}\n');
fs.writeFileSync(path.join(home, 'config.toml'), '# e2e\nmodel = "gpt-5"\n\n[features]\n');
let db = null;
try {
  const { DatabaseSync } = await import('node:sqlite');
  db = path.join(home, 'state_5.sqlite');
  const d = new DatabaseSync(db);
  d.exec("pragma journal_mode=wal; create table if not exists threads(id integer primary key, model_provider text); delete from threads; insert into threads(model_provider) values ('openai'),('other');");
  d.close();
} catch (e) { console.log('      （这个 node 没有 node:sqlite，跳过状态库检查：' + e.message + '）'); }
const dbProviders = async () => { const { DatabaseSync } = await import('node:sqlite'); const d = new DatabaseSync(db, { readOnly: true }); const r = d.prepare('select model_provider p from threads order by id').all().map(x => x.p); d.close(); return r; };

// ---------- 步骤 ----------
let r = await run(exe, ['codex', 'mode']);
check('还没切换过：mode 输出 none', r.out.trim().split(/\r?\n/).pop() === 'none', r.out);
r = await run(exe, ['codex', 'configure'], `${base}\nx-e2e-test=yes\n${KEY}\n`);
check('configure 保存地址、请求头和 key', r.code === 0, r.out);

// 非 Windows 调试时 key 只在内存里，api 会再问一次，所以也从标准输入给
r = await run(exe, ['codex', 'api'], `${KEY}\n`);
check('切到 API', r.code === 0, r.out);
check('切换前用 key 探测了 /v1/models', seen.some(x => x.method === 'GET' && x.url === '/v1/models' && x.auth === `Bearer ${KEY}` && x.xtest === 'yes'), JSON.stringify(seen));
let c = config();
check('config.toml：默认 provider 固定、地址生效、原有内容保留',
  /^model_provider = "127_0_0_1"/.test(c) && c.includes(`base_url = "${base}"`) && c.includes('http_headers = { "x-e2e-test" = "yes" }') && c.includes('# e2e\nmodel = "gpt-5"') && c.includes('[features]'), c);
r = await run(codexBin, ['login', 'status']);
check('Codex 自己认为是 API key 登录', /api key/i.test(r.out), r.out);
check('会话文件第一行改记为默认 provider，第二行没动',
  (() => { const l = fs.readFileSync(session, 'utf8').split('\n'); return l[0].includes('"model_provider":"127_0_0_1"') && l[1].includes('"model_provider":"openai"'); })(), fs.readFileSync(session, 'utf8'));
if (db) check('状态库里记成 openai 的会话也改了，别的没动', JSON.stringify(await dbProviders()) === '["127_0_0_1","other"]', JSON.stringify(await dbProviders()));
if (process.platform === 'win32') {
  r = await run('cmdkey', ['/list:codex-mode:127.0.0.1']);
  check('key 在 Windows 凭据管理器里（codex-mode:127.0.0.1）', /codex-mode:127\.0\.0\.1/i.test(r.out), r.out);
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aaswitch-e2e-work-'));
r = await run(codexBin, ['exec', '--skip-git-repo-check', '-C', work, 'ping'], '', 180000);
const viaGateway = responses();
check('Codex 的请求打到了网关（/v1/responses）', viaGateway.length > 0, r.out.slice(-800));
check('请求带着我们的 key 和额外请求头', viaGateway.length > 0 && viaGateway.every(x => x.auth === `Bearer ${KEY}` && x.xtest === 'yes'), JSON.stringify(viaGateway.slice(0, 3)));
check('Codex 输出了网关的回复', r.out.includes(REPLY), r.out.slice(-800));

r = await run(exe, ['codex', 'chatgpt']);
check('切回 ChatGPT 账号', r.code === 0, r.out);
c = config();
check('config.toml：默认 provider 不变，地址和请求头注释掉', /^model_provider = "127_0_0_1"/.test(c) && c.includes(`# base_url = "${base}"`) && c.includes('# http_headers =') && !/^base_url/m.test(c), c);
r = await run(exe, ['codex', 'mode']);
check('mode 输出 chatgpt', r.out.trim().split(/\r?\n/).pop() === 'chatgpt', r.out);
r = await run(codexBin, ['login', 'status']);
check('没有存档的账号登录态：已登出，等用户在 Codex 里登录', /not logged in/i.test(r.out), r.out);
const before = seen.length;
r = await run(codexBin, ['exec', '--skip-git-repo-check', '-C', work, 'ping'], '', 60000);
check('切回后 Codex 不再请求网关', seen.length === before, JSON.stringify(seen.slice(before)));
check('备份目录里有切换前的 config.toml', fs.readdirSync(path.join(home, 'codex-mode-backups')).some(d => fs.existsSync(path.join(home, 'codex-mode-backups', d, 'config.toml'))));

await run(exe, ['codex', 'forget-key']);
server.close();
console.log(failed ? `\n${failed} 项失败` : '\n全部通过');
process.exit(failed ? 1 : 0);
