// 端到端验证：真的 Claude Code + 本地假网关，确认 aaswitch 切换后请求确实换了去向。
//   node e2e/claude-e2e.mjs <aaswitch 可执行文件路径>
// GitHub Actions 的 windows-latest 上用真实的 ~\.claude 和凭据管理器；本机调试时设 E2E_ISOLATED=1，改用临时目录，不碰自己的配置。
// 假网关只监听 127.0.0.1，回一段固定的流式回复；全程不需要任何真实的 key。
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const exe = path.resolve(process.argv[2] ?? '');
if (!fs.existsSync(exe)) { console.error('用法：node claude-e2e.mjs <aaswitch 路径>'); process.exit(2); }

const KEY = 'sk-e2e-not-a-real-key';
const REPLY = 'pong-from-mock-gateway';
const env = { ...process.env, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_AUTOUPDATER: '1' };
for (const k of ['ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_CUSTOM_HEADERS']) delete env[k];
let claudeHome = path.join(os.homedir(), '.claude');
if (process.env.E2E_ISOLATED === '1') {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'aaswitch-e2e-'));
  claudeHome = env.CLAUDE_CONFIG_DIR = path.join(tmp, '.claude');
  env.CODEX_HOME = path.join(tmp, '.codex');
}
const settings = path.join(claudeHome, 'settings.json');

// ---------- 假网关 ----------
const seen = [];
const sse = (events) => events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    seen.push({ method: req.method, url: req.url, auth: req.headers.authorization ?? '', xtest: req.headers['x-e2e-test'] ?? '' });
    if (req.method === 'GET') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"data":[]}'); }
    let stream = false, model = 'mock';
    try { const j = JSON.parse(body); stream = !!j.stream; model = j.model ?? model; } catch { }
    if (req.url.includes('count_tokens')) { res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"input_tokens":1}'); }
    const message = { id: 'msg_e2e', type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } };
    if (!stream) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ ...message, content: [{ type: 'text', text: REPLY }], stop_reason: 'end_turn' }));
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end(sse([
      { type: 'message_start', message },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: REPLY } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]));
  });
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

// ---------- 工具 ----------
let failed = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || !detail ? '' : '\n      ' + detail}`); if (!ok) failed++; };
// 注意：假网关跑在本进程里，所以子进程必须异步等（spawnSync 会卡住事件循环，网关就没法应答了）
const { spawn } = await import('node:child_process');
const run = (cmd, args, input = '', timeoutMs = 120000) => new Promise(resolve => {
  const child = spawn(cmd, args, { env, shell: process.platform === 'win32' && !cmd.endsWith('.exe'), windowsHide: true });
  let out = '';
  child.stdout.on('data', d => out += d); child.stderr.on('data', d => out += d);
  const timer = setTimeout(() => { out += '\n[e2e: timeout]'; child.kill(); }, timeoutMs);
  child.on('error', e => { clearTimeout(timer); resolve({ code: -1, out: String(e) }); });
  child.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
  child.stdin.end(input);
});
const readEnv = () => { try { return JSON.parse(fs.readFileSync(settings, 'utf8')).env ?? {}; } catch { return {}; } };
const messages = () => seen.filter(r => r.method === 'POST' && r.url.startsWith('/v1/messages') && !r.url.includes('count_tokens'));

// ---------- 步骤 ----------
fs.mkdirSync(claudeHome, { recursive: true });
fs.writeFileSync(settings, JSON.stringify({ theme: 'dark', env: { KEEP_ME: '1' } }, null, 2));

let r = await run(exe, ['claude', 'configure'], `${base}/v1\nx-e2e-test=yes\n${KEY}\n`);
check('configure 保存地址（去掉 /v1）、请求头和 key', r.code === 0, r.out);

// 非 Windows 调试时 key 只在内存里，api 会再问一次，所以这里也从标准输入给；Windows 上凭据管理器里已有，不会读
r = await run(exe, ['claude', 'api'], `${KEY}\n`);
check('切到 API', r.code === 0, r.out);
check('切换前用 key 探测了 /v1/models', seen.some(x => x.method === 'GET' && x.url === '/v1/models' && x.auth === `Bearer ${KEY}` && x.xtest === 'yes'), JSON.stringify(seen));
let e = readEnv();
check('settings.json 的 env 写对了，原有内容保留',
  e.ANTHROPIC_BASE_URL === base && e.ANTHROPIC_AUTH_TOKEN === KEY && e.ANTHROPIC_CUSTOM_HEADERS === 'x-e2e-test: yes' && e.KEEP_ME === '1'
  && JSON.parse(fs.readFileSync(settings, 'utf8')).theme === 'dark', JSON.stringify(e));
r = await run(exe, ['claude', 'mode']);
check('mode 输出 api', r.out.trim().split(/\r?\n/).pop() === 'api', r.out);
if (process.platform === 'win32') {
  r = await run('cmdkey', ['/list:codex-mode:127.0.0.1']);
  check('key 在 Windows 凭据管理器里（codex-mode:127.0.0.1）', /codex-mode:127\.0\.0\.1/i.test(r.out), r.out);
}

r = await run('claude', ['-p', 'ping'], '', 180000);
const viaGateway = messages();
check('Claude Code 的请求打到了网关', viaGateway.length > 0, r.out);
check('请求带着我们的 key 和额外请求头', viaGateway.length > 0 && viaGateway.every(x => x.auth === `Bearer ${KEY}` && x.xtest === 'yes'), JSON.stringify(viaGateway.slice(0, 3)));
check('Claude Code 输出了网关的回复', r.out.includes(REPLY), r.out.slice(0, 600));

r = await run(exe, ['claude', 'account']);
check('切回账号', r.code === 0, r.out);
e = readEnv();
check('env 里的三项已删除，别的还在', !('ANTHROPIC_BASE_URL' in e) && !('ANTHROPIC_AUTH_TOKEN' in e) && !('ANTHROPIC_CUSTOM_HEADERS' in e) && e.KEEP_ME === '1', JSON.stringify(e));
const before = seen.length;
r = await run('claude', ['-p', 'ping'], '', 60000);   // 虚拟机上没登录账号，这里会报未登录；要确认的只是它不再找网关
check('切回后 Claude Code 不再请求网关', seen.length === before, JSON.stringify(seen.slice(before)));
console.log('      （账号模式下 claude 的输出：' + r.out.trim().split(/\r?\n/)[0]?.slice(0, 120) + '）');
check('备份目录里有切换前的 settings.json', fs.existsSync(path.join(claudeHome, 'claude-mode-backups')) && fs.readdirSync(path.join(claudeHome, 'claude-mode-backups')).length > 0);

r = await run(exe, ['claude', 'forget-key']);
server.close();
console.log(failed ? `\n${failed} 项失败` : '\n全部通过');
process.exit(failed ? 1 : 0);
