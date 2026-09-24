#!/bin/bash
# claude-mode — 在「Claude 账号」和「自定义 API」之间切换 Claude Code（终端和 IDE 插件）。会话记录在本机，两种模式下都能继续。
#   Claude 桌面应用里的 Code 标签不看 settings.json：它启动会话时注入自己的 OAuth token，引擎在这种入口下强制使用该 token
#   （实测，见 DEVELOPMENT.md）。让它走网关的唯一途径是把整个桌面应用切到第三方推理模式（desktop gateway 命令），
#   那是桌面应用级别的开关，会重启应用，且网关模式用独立的数据目录。侧边栏的会话列表按数据目录各存一份（每个会话一个
#   local_<id>.json，指向共享的 ~/.claude/projects 记录），切换时脚本把两边互相补齐，所以两种模式下都能看到全部会话；
#   Cowork 会话也一样，只是它的记录不共享，要整份复制过去（见 desktop_sync_cowork）。
#
#   claude-mode api          切到自定义 API：把网关地址和 key 写进 ~/.claude/settings.json 的 env 块（新会话立即生效）
#   claude-mode account      切回 Claude 账号：从 env 块删掉网关地址和 key（账号登录态一直都在，不用重新登录）
#   claude-mode desktop gateway   Claude 桌面应用（Code 标签）也走网关：写入桌面应用的第三方推理配置并重启它
#   claude-mode desktop account   Claude 桌面应用切回账号：重启它
#   claude-mode desktop sync      把账号模式和网关模式两边的 Code 会话列表互相补齐、Cowork 会话互相同步（切换时会自动做，这是手动触发）
#   claude-mode desktop-mode 只输出一个词 gateway / account / absent（桌面应用当前走哪边），供程序读取
#   claude-mode status       查看当前模式（不显示 key）
#   claude-mode configure    设置或修改 API 地址、额外请求头和 key（图形界面可用环境变量非交互传入，见下）
#   claude-mode set-key      只更换 key（存入 macOS 钥匙串）
#   claude-mode forget-key   从钥匙串删除保存的 key
#   claude-mode mode         只输出一个词 api / account / absent，供菜单栏小工具等程序读取
#   claude-mode version      输出脚本版本号
#   claude-mode config       输出已保存的地址和请求头（不含 key），供程序读取
#   claude-mode has-key URL  钥匙串里有没有该地址的 key（退出码 0 表示有）
#   claude-mode key URL      输出钥匙串里该地址的 key（供配置表单回填）
#
# 原理：Claude Code 的凭据优先级里，环境变量 ANTHROPIC_AUTH_TOKEN 排在账号登录之前；settings.json 的 env 块会被
#   终端和 IDE 里的每个新会话读取。所以切到 API 只需写入 ANTHROPIC_BASE_URL 和
#   ANTHROPIC_AUTH_TOKEN（有额外请求头时再写 ANTHROPIC_CUSTOM_HEADERS），切回账号只需删掉它们。settings.json
#   里的其他内容（hooks、权限、主题等）原样保留。
# 依赖：macOS 自带的 bash、osascript（用 JavaScript 读写 JSON）、security、curl，不需要 Python。
# 配置：~/.claude/claude-mode.conf 保存地址和请求头；key 只存在 macOS 钥匙串（条目名 codex-mode:域名，与 codex-mode
#   共用，同一网关只需配一次 key）。首次运行若没配过地址，会从 ~/.codex/codex-mode.conf 的地址推断（去掉末尾 /v1）。
# 备份：每次写 settings.json 之前先复制到 ~/.claude/claude-mode-backups/<时间>/，只留最近 20 次。
# 环境变量：CLAUDE_CONFIG_DIR（Claude Code 的配置目录，默认 ~/.claude）、CODEX_HOME（推断地址时读 codex-mode.conf）、
#   CLAUDE_MODE_NONINTERACTIVE=1（需要输入时直接报错，供图形界面调用）、CLAUDE_MODE_NO_REOPEN=1（切桌面模式时只退出不重开）、
#   CLAUDE_DESKTOP_DATA_DIR（桌面应用数据目录，默认 ~/Library/Application Support/Claude，测试用）。
# 桌面应用的第三方推理模式：地址和 key 写在 <数据目录>-3p/configLibrary/<id>.json，账号 / 网关的选择写在
#   <数据目录>-3p/claude_desktop_config.json 的 deploymentMode（1p 账号，3p 网关），启动时生效。配置项 desktop_base_url（默认同
#   base_url，不带 /v1）和 desktop_models（逗号分隔的模型名，默认 claude-fable-5-1,claude-fable-5,claude-opus-5，第一个是默认模型）可在 claude-mode.conf 里改。
#   非交互配置：CLAUDE_MODE_BASE_URL、CLAUDE_MODE_HEADERS（名称=值，逗号分隔）、CLAUDE_MODE_KEY_STDIN=1（从标准输入读
#   key，可为空表示沿用已保存的）；三者任一设置时 configure 不再提问。
set -eu
CLAUDE_MODE_VERSION="1.3.0"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_HOME/settings.json"
CONF="$CLAUDE_HOME/claude-mode.conf"
BK="$CLAUDE_HOME/claude-mode-backups/$(date +%Y%m%d-%H%M%S)"
CODEX_CONF="${CODEX_HOME:-$HOME/.codex}/codex-mode.conf"
CRED_SERVICE="Claude Code-credentials"   # Claude Code 存账号登录态的钥匙串条目
DESKTOP_DATA="${CLAUDE_DESKTOP_DATA_DIR:-$HOME/Library/Application Support/Claude}"
DESKTOP_CONF="${DESKTOP_DATA}-3p/claude_desktop_config.json"   # 注意：在 -3p 目录，不在主目录（应用代码里 hl() 固定加 -3p 后缀）
DESKTOP_LIB="${DESKTOP_DATA}-3p/configLibrary"
DESKTOP_APP="Claude"

say() { echo "$*" >&2; }
die() { echo "错误：$*" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---------- 配置文件（key=value，不会被 source 执行） ----------
conf_get() { if [ -f "$CONF" ]; then sed -n "s/^$1=//p" "$CONF" | head -n1; fi; }
conf_set() {
  local tmp; mkdir -p "$CLAUDE_HOME"; tmp="$(mktemp "$CLAUDE_HOME/.claude-mode.XXXXXX")"
  if [ -f "$CONF" ]; then grep -v "^$1=" "$CONF" > "$tmp" || true; fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$CONF"
}
other_conf_get() { if [ -f "$CODEX_CONF" ]; then sed -n "s/^$1=//p" "$CODEX_CONF" | head -n1; fi; }

# ---------- 交互输入 ----------
ask() {  # ask 提示 默认值
  local ans
  [ "${CLAUDE_MODE_NONINTERACTIVE:-}" = 1 ] && die "需要交互输入（$1），请在终端运行 claude-mode configure。"
  printf '%s' "$1" >&2; [ -n "$2" ] && printf ' [%s]' "$2" >&2; printf ': ' >&2
  IFS= read -r ans < /dev/tty || die "输入已取消。"
  printf '%s' "${ans:-$2}"
}
ask_secret() {
  local ans
  [ "${CLAUDE_MODE_NONINTERACTIVE:-}" = 1 ] && die "需要输入 API key，请在终端运行 claude-mode set-key。"
  printf '%s（输入不回显）: ' "$1" >&2
  IFS= read -r -s ans < /dev/tty || true; echo >&2
  printf '%s' "$ans"
}

# ---------- 地址、请求头、钥匙串 ----------
valid_url() { case "$1" in http://?*|https://?*) [[ "$1" != *[[:space:]\"\\]* ]] ;; *) return 1 ;; esac; }
url_host() { local h="${1#*://}"; h="${h%%/*}"; h="${h%%:*}"; printf '%s' "${h#*@}"; }
kc_service() { printf 'codex-mode:%s' "$(url_host "$1")"; }
kc_get() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null || true; }
kc_set() { security add-generic-password -a "$USER" -s "$1" -w "$2" -U >/dev/null 2>&1 || die "无法写入 macOS 钥匙串。"; }
kc_del() { security delete-generic-password -a "$USER" -s "$1" >/dev/null 2>&1; }
pairs_to_header_lines() {  # "a=b, c=d" → "a: b\nc: d"（ANTHROPIC_CUSTOM_HEADERS 的格式）
  local out="" pair name value
  IFS=',' read -r -a pairs <<< "$1"
  for pair in "${pairs[@]+"${pairs[@]}"}"; do
    pair="${pair#"${pair%%[![:space:]]*}"}"; pair="${pair%"${pair##*[![:space:]]}"}"
    [ -n "$pair" ] || continue
    case "$pair" in *=*) ;; *) die "请求头格式应为 名称=值：$pair" ;; esac
    name="${pair%%=*}"; value="${pair#*=}"
    name="${name%"${name##*[![:space:]]}"}"; value="${value#"${value%%[![:space:]]*}"}"
    [ -n "$name" ] || die "请求头名称不能为空：$pair"
    out="${out:+$out
}${name}: ${value}"
  done
  printf '%s' "$out"
}

# ---------- settings.json 的 env 块（用系统自带的 JavaScript 读写，其他内容原样保留） ----------
json_env() {  # json_env get|set|clear [地址 token 请求头行]
  [ "$1" = get ] || mkdir -p "$CLAUDE_HOME"
  osascript -l JavaScript - "$SETTINGS" "$@" <<'EOF'
ObjC.import('Foundation');
function run(argv) {
  const [file, op, url, token, headers] = argv;
  const s = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
  let obj = {};
  if (!s.isNil()) {
    const text = ObjC.unwrap(s);
    if (text.trim() !== '') obj = JSON.parse(text);
    if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) throw new Error('settings.json 的顶层不是对象');
  }
  const env = (obj.env && typeof obj.env === 'object') ? obj.env : {};
  if (op === 'get') {   // 逐行 key=value，方便 shell 用 sed 取值
    return 'base_url=' + (env.ANTHROPIC_BASE_URL || '') + '\nhas_token=' + (env.ANTHROPIC_AUTH_TOKEN ? 'true' : 'false')
         + '\napi_key=' + (env.ANTHROPIC_API_KEY ? 'true' : 'false');
  }
  if (op === 'set') {
    obj.env = env;
    env.ANTHROPIC_BASE_URL = url; env.ANTHROPIC_AUTH_TOKEN = token;
    if (headers) env.ANTHROPIC_CUSTOM_HEADERS = headers; else delete env.ANTHROPIC_CUSTOM_HEADERS;
  } else if (op === 'clear') {
    for (const k of ['ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_CUSTOM_HEADERS']) delete env[k];
    if (Object.keys(env).length === 0) delete obj.env; else obj.env = env;
  } else { throw new Error('未知操作 ' + op); }
  const out = $.NSString.alloc.initWithUTF8String(JSON.stringify(obj, null, 2) + '\n');
  if (!out.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) throw new Error('写入失败：' + file);
  return 'ok';
}
EOF
}
env_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1; }
read_env() { ENVJSON="$(json_env get 2>/dev/null)" || die "读取 ${SETTINGS} 失败（文件不是合法的 JSON？请修好或删掉它再试）。"; }
current_mode() { read_env; if [ -n "$(env_field "$ENVJSON" base_url)" ]; then echo api; else echo account; fi; }
# 备份只留最近 20 次切换的和最近 3 份旧脚本，再老的删掉，免得越积越多
prune_backups() {
  local root="${BK%/*}" n
  [ -d "$root" ] || return 0
  # 注意脚本开着 set -e：循环体最后一条不能是可能为假的 && 列表，否则整个管道返回 1 会让脚本静默退出
  n=0; ls -1d "$root"/[0-9]*-[0-9]* 2>/dev/null | sort -r | while IFS= read -r d; do n=$((n+1)); if [ "$n" -gt 20 ]; then rm -rf "$d"; fi; done || true
  n=0; ls -1 "$root"/*.old-* 2>/dev/null | sort -r | while IFS= read -r f; do n=$((n+1)); if [ "$n" -gt 3 ]; then rm -f "$f"; fi; done || true
  return 0
}
backup_settings() {
  [ -f "$SETTINGS" ] || return 0
  mkdir -p "$BK"; cp -p "$SETTINGS" "$BK/settings.json"; prune_backups
}

# ---------- 账号登录态（只读，不改） ----------
account_email() {  # 从 ~/.claude.json 取登录邮箱，取不到输出空
  local f="$HOME/.claude.json"
  [ -f "$f" ] || return 0
  osascript -l JavaScript - "$f" <<'EOF' 2>/dev/null || true
ObjC.import('Foundation');
function run(argv) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (s.isNil()) return '';
  try { const o = JSON.parse(ObjC.unwrap(s)); return (o.oauthAccount && o.oauthAccount.emailAddress) || ''; } catch (e) { return ''; }
}
EOF
}
account_logged_in() { [ -n "$(kc_get "$CRED_SERVICE")" ] || [ -f "$CLAUDE_HOME/.credentials.json" ]; }
claude_installed() {  # 用过 Claude Code 的痕迹：全局状态文件、会话目录、桌面版内置引擎、命令行
  [ -f "$HOME/.claude.json" ] || [ -d "$CLAUDE_HOME/projects" ] || [ -d "$HOME/Library/Application Support/Claude/claude-code" ] \
    || command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]
}

# ---------- 地址与 key ----------
load_conf() {
  BASE_URL="$(conf_get base_url)"; HEADERS="$(conf_get headers)"
  if [ -z "$BASE_URL" ]; then  # 首次运行：沿用 codex-mode 配的网关，去掉 OpenAI 风格的 /v1 后缀
    local other; other="$(other_conf_get base_url)"
    if [ -n "$other" ]; then
      BASE_URL="${other%/}"; BASE_URL="${BASE_URL%/v1}"
      conf_set base_url "$BASE_URL"
      say "已沿用 codex-mode 的网关地址 ${BASE_URL}，保存到 ${CONF}。"
    fi
  fi
}
check_key() {  # check_key URL KEY：先用 key 探测地址，明确被拒（401/403）就停下，其他情况放行
  local code hdrs=() line
  while IFS= read -r line; do [ -n "$line" ] && hdrs+=(-H "$line"); done <<< "$(pairs_to_header_lines "$HEADERS")"
  code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${1%/}/v1/models" -H "Authorization: Bearer $2" ${hdrs[@]+"${hdrs[@]}"} 2>/dev/null || echo 000)"
  case "$code" in
    401|403) die "这个 API key 在 ${1} 上无效（HTTP ${code}）。每个网关的 key 不通用，请在“配置 Claude Code API”里填写该地址对应的 key。" ;;
  esac
}
get_key() {  # 钥匙串里这个地址的 key → 手动输入
  local svc key; svc="$(kc_service "$BASE_URL")"
  key="$(kc_get "$svc")"
  if [ -z "$key" ]; then
    key="$(ask_secret "请输入 $(url_host "$BASE_URL") 的 API key")" || exit 1
    [ -n "$key" ] || die "未输入 key，已取消。"
    case "$(ask '是否存入钥匙串，以后切换不用再输？(Y/n)' Y)" in n|N) ;; *) kc_set "$svc" "$key"; say "已存入钥匙串。" ;; esac
  fi
  printf '%s' "$key"
}

# ---------- Claude 桌面应用（第三方推理模式） ----------
desktop_installed() { [ -d "/Applications/$DESKTOP_APP.app" ] || [ -d "$HOME/Applications/$DESKTOP_APP.app" ]; }
desktop_json() {  # desktop_json mode | set-mode 1p|3p | write-gateway URL KEY 模型列表(逗号分隔)
  osascript -l JavaScript - "$DESKTOP_CONF" "$DESKTOP_LIB" "$@" <<'EOF'
ObjC.import('Foundation');
function readJSON(file, fallback) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
  if (s.isNil()) return fallback;
  const text = ObjC.unwrap(s).trim();
  if (text === '') return fallback;
  const o = JSON.parse(text);
  if (o === null || typeof o !== 'object' || Array.isArray(o)) throw new Error(file + ' 的顶层不是对象');
  return o;
}
function writeJSON(file, obj) {
  const dir = $.NSString.alloc.initWithUTF8String(file).stringByDeletingLastPathComponent;
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  const out = $.NSString.alloc.initWithUTF8String(JSON.stringify(obj, null, 2) + '\n');
  if (!out.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) throw new Error('写入失败：' + file);
}
function run(argv) {
  const [conf, lib, op, a, b, c] = argv;
  const meta = lib + '/_meta.json';
  if (op === 'mode') {
    const mode = readJSON(conf, {}).deploymentMode;
    const m = readJSON(meta, {});
    let provider = '', url = '';
    if (m.appliedId) { const g = readJSON(lib + '/' + m.appliedId + '.json', {}); provider = g.inferenceProvider || ''; url = g.inferenceGatewayBaseUrl || ''; }
    return 'deployment=' + (mode || '') + '\nprovider=' + provider + '\nurl=' + url;
  }
  if (op === 'set-mode') {
    const o = readJSON(conf, {}); o.deploymentMode = a; writeJSON(conf, o); return 'ok';
  }
  if (op === 'sync-trusted') {   // a = 主目录的 claude_desktop_config.json；两边 preferences.localAgentModeTrustedFolders 取并集
    const files = [a, conf], objs = files.map(f => readJSON(f, {}));
    const all = new Set();
    for (const o of objs) for (const d of ((o.preferences || {}).localAgentModeTrustedFolders || [])) if (typeof d === 'string') all.add(d);
    let changed = 0;
    objs.forEach((o, i) => {
      const cur = ((o.preferences || {}).localAgentModeTrustedFolders || []);
      if (cur.length === all.size) return;
      o.preferences = o.preferences || {}; o.preferences.localAgentModeTrustedFolders = [...all]; writeJSON(files[i], o); changed++;
    });
    return String(changed);
  }
  if (op === 'write-gateway') {
    const m = readJSON(meta, {});
    if (!Array.isArray(m.entries)) m.entries = [];
    let id = m.appliedId;
    if (!id || !m.entries.some(e => e && e.id === id)) {
      id = ObjC.unwrap($.NSUUID.UUID.UUIDString).toLowerCase();
      m.entries.push({ id: id, name: 'AA Switch' });
      m.appliedId = id;
    }
    const file = lib + '/' + id + '.json';
    const g = readJSON(file, {});
    g.inferenceProvider = 'gateway';
    g.inferenceGatewayBaseUrl = a;
    g.inferenceGatewayApiKey = b;
    g.inferenceGatewayAuthScheme = 'bearer';
    g.inferenceModels = c.split(',').map(x => x.trim()).filter(x => x);
    writeJSON(file, g); writeJSON(meta, m);
    return id;
  }
  throw new Error('未知操作 ' + op);
}
EOF
}
desktop_mode() {  # gateway | account | absent
  desktop_installed || { echo absent; return; }
  local info; info="$(desktop_json mode 2>/dev/null || true)"
  if [ "$(env_field "$info" deployment)" = 3p ] && [ "$(env_field "$info" provider)" = gateway ]; then echo gateway; else echo account; fi
}
desktop_running() { pgrep -x "$DESKTOP_APP" >/dev/null 2>&1; }
desktop_quit() {  # 桌面应用在运行就退出它，DESKTOP_WAS_RUNNING=1；没开着就什么都不做
  DESKTOP_WAS_RUNNING=0
  desktop_running || return 0
  DESKTOP_WAS_RUNNING=1
  say "正在退出 ${DESKTOP_APP}…"
  osascript -e "tell application \"$DESKTOP_APP\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do desktop_running || break; sleep 0.2; done   # 最多等 20 秒
  if desktop_running; then die "$DESKTOP_APP 没有退出，请手动 ⌘Q 后重新打开。"; fi
  sleep 0.5
}
desktop_reopen() {  # 配合 desktop_quit：原来开着才重开；没开着就只改配置，下次打开生效
  if [ "$DESKTOP_WAS_RUNNING" != 1 ]; then say "${DESKTOP_APP} 没有在运行，下次打开时生效。"; return 0; fi
  if [ "${CLAUDE_MODE_NO_REOPEN:-}" != 1 ]; then open -a "$DESKTOP_APP" >/dev/null 2>&1 || say "请手动打开 ${DESKTOP_APP}。"; fi
}
desktop_sessions_dir() {  # desktop_sessions_dir <数据目录> [账号 uuid] [组织 uuid]：该 profile 的 Code 会话记录目录；找不到输出空
  local root="$1/claude-code-sessions" acct="${2:-}" org="${3:-}" d best="" bestn=-1 n
  [ -d "$root" ] || return 0
  if [ -z "$acct" ] || [ ! -d "$root/$acct" ]; then acct="$(ls "$root" 2>/dev/null | grep -E '^[0-9a-f-]{36}$' | head -n1)"; fi
  [ -n "$acct" ] && [ -d "$root/$acct" ] || return 0
  if [ -n "$org" ] && [ -d "$root/$acct/$org" ]; then printf '%s' "$root/$acct/$org"; return 0; fi
  for d in "$root/$acct"/*/; do   # 没指定组织就取会话记录最多的那个组织目录
    d="${d%/}"; [ -d "$d" ] || continue
    n=$(ls "$d"/local_*.json 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt "$bestn" ]; then best="$d"; bestn=$n; fi
  done
  [ -n "$best" ] && printf '%s' "$best"
}
oauth_ids() {  # 账号模式的 "账号uuid 组织uuid"（取自 ~/.claude.json 的 oauthAccount），取不到输出空
  osascript -l JavaScript -e 'ObjC.import("Foundation"); const s=$.NSString.stringWithContentsOfFileEncodingError($("'"$HOME/.claude.json"'"),$.NSUTF8StringEncoding,null); if (s.isNil()) ""; else { const o=JSON.parse(ObjC.unwrap(s)).oauthAccount||{}; (o.accountUuid||"")+" "+(o.organizationUuid||"") }' 2>/dev/null || true
}
desktop_sync_sessions() {  # 两个 profile 的会话记录互相补齐：只补缺的，不覆盖，目标已标记 deleted_ 的不补
  local a b ids acct org src dst f name id n=0
  ids="$(oauth_ids)"
  acct="${ids%% *}"; org="${ids#* }"; [ "$org" = "$ids" ] && org=""
  a="$(desktop_sessions_dir "$DESKTOP_DATA" "$acct" "$org")"
  b="$(desktop_sessions_dir "${DESKTOP_DATA}-3p")"
  if [ -z "$a" ] || [ -z "$b" ]; then
    say "会话列表暂时没法同步（$( [ -z "$b" ] && echo "网关模式还没初始化过数据目录，第一次进入网关模式后再切一次即可" || echo "账号模式的会话目录没找到" )）。"
    return 0
  fi
  for pair in "$a|$b" "$b|$a"; do
    src="${pair%%|*}"; dst="${pair#*|}"
    for f in "$src"/local_*.json; do
      [ -f "$f" ] || continue
      name="$(basename "$f")"; id="${name#local_}"; id="${id%.json}"
      [ -e "$dst/$name" ] && continue
      [ -e "$dst/deleted_$id" ] && continue
      cp -p "$f" "$dst/$name" && n=$((n+1))
    done
  done
  desktop_json sync-trusted "$DESKTOP_DATA/claude_desktop_config.json" >/dev/null 2>&1 || true
  say "会话列表已同步（补齐 ${n} 条）。"
}
# Cowork 会话：<数据目录>/local-agent-mode-sessions/<账号>/<组织>/ 下每个会话一个 local_<id>.json 加一个同名目录（对话记录在
#   目录里的 .claude/projects/<按路径命名>/，还有 outputs、uploads、audit.jsonl）。和 Code 标签不同，记录不共享，所以整份复制，
#   并把里面指向原位置的绝对路径（以及按路径命名的目录）改成新位置；audit.jsonl 带签名，原样保留。两份复制后会各自往下走，
#   所以用 $CLAUDE_HOME/claude-mode-cowork-sync 记下每个会话上次同步时的 lastActivityAt：只有一边比它新就用那边覆盖另一边
#   （旧的挪进备份），两边都新了算冲突、不动；记录里有但某一边没了，当作在那边删掉了，不再补回去。
cowork_dir() {  # cowork_dir <数据目录> [账号 uuid] [组织 uuid]：该 profile 的 Cowork 会话目录；找不到输出空
  local root="$1/local-agent-mode-sessions" acct="${2:-}" org="${3:-}" d best="" bestn=-1 n
  [ -d "$root" ] || return 0
  if [ -n "$acct" ] && [ -n "$org" ] && [ -d "$root/$acct/$org" ]; then printf '%s' "$root/$acct/$org"; return 0; fi
  for d in "$root"/*/*/; do   # 否则取会话最多的那个（网关模式是 <账号前 8 位>/<组织前 8 位>，比如 c0062ea9/00000000）
    d="${d%/}"; [ -d "$d" ] || continue
    case "$d" in "$root"/skills-plugin/*) continue ;; esac
    n=$(ls "$d"/local_*.json 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt "$bestn" ]; then best="$d"; bestn=$n; fi
  done
  if [ -n "$best" ]; then printf '%s' "$best"; fi
  return 0
}
cowork_js() {  # cowork_js plan <A> <B> <记录文件> | rewrite <源目录> <目标目录> <临时目录> <源 json> <目标 json>
  osascript -l JavaScript - "$@" <<'EOF'
ObjC.import('Foundation');
const fm = $.NSFileManager.defaultManager;
function read(f) { const s = $.NSString.stringWithContentsOfFileEncodingError(f, $.NSUTF8StringEncoding, null); return s.isNil() ? null : ObjC.unwrap(s); }
function write(f, text, like) {   // 保留 like 的修改时间和权限（应用可能按修改时间排序）
  const a = fm.attributesOfItemAtPathError(like, null);
  if (!$.NSString.alloc.initWithUTF8String(text).writeToFileAtomicallyEncodingError(f, true, $.NSUTF8StringEncoding, null)) throw new Error('写入失败：' + f);
  if (a.isNil()) return;
  const d = $.NSMutableDictionary.dictionary;   // 键名就是常量的值；JXA 里拿不到 NSFileModificationDate 这类常量
  for (const k of ['NSFileModificationDate', 'NSFilePosixPermissions']) { const v = a.objectForKey(k); if (!v.isNil()) d.setObjectForKey(v, k); }
  fm.setAttributesOfItemAtPathError(d, f, null);
}
function list(dir) { const a = fm.contentsOfDirectoryAtPathError(dir, null); return a.isNil() ? [] : ObjC.deepUnwrap(a); }
function sessions(dir) {   // 名字 → lastActivityAt
  const out = {};
  for (const f of list(dir)) {
    const m = /^(local_[0-9A-Za-z-]+)\.json$/.exec(f); if (!m) continue;
    let last = 0; try { last = Number(JSON.parse(read(dir + '/' + f)).lastActivityAt) || 0; } catch (e) {}
    out[m[1]] = last;
  }
  return out;
}
const san = p => p.replace(/[^A-Za-z0-9]/g, '-');   // Claude Code 给 .claude/projects 下的目录起名的规则
function run(argv) {
  const [op] = argv;
  if (op === 'plan') {   // 每行：动作 名字 新记录 旧记录（- 表示没有）
    const [, A, B, ledger] = argv, a = sessions(A), b = sessions(B), led = {}, out = [];
    for (const line of (read(ledger) || '').split('\n')) { const [n, v] = line.trim().split(/\s+/); if (n) led[n] = Number(v) || 0; }
    for (const n of new Set([...Object.keys(a), ...Object.keys(b), ...Object.keys(led)])) {
      const inA = n in a, inB = n in b, has = n in led, L = led[n], old = has ? String(L) : '-';
      if (!inA && !inB) continue;                                      // 两边都没了，记录也不要了
      if (inA !== inB) {
        if (has) out.push('gone ' + n + ' ' + L + ' ' + old);          // 同步过、某一边删掉了：不补回去
        else out.push((inA ? 'a2b ' : 'b2a ') + n + ' ' + (inA ? a[n] : b[n]) + ' -');
        continue;
      }
      if (a[n] === b[n]) { out.push('keep ' + n + ' ' + a[n] + ' ' + old); continue; }
      const newA = !has || a[n] > L, newB = !has || b[n] > L;
      if (has && newA && newB) out.push('conflict ' + n + ' ' + L + ' ' + old);
      else if (has ? newA : a[n] > b[n]) out.push('a2b ' + n + ' ' + a[n] + ' ' + old);
      else out.push('b2a ' + n + ' ' + b[n] + ' ' + old);
    }
    return out.join('\n');
  }
  if (op === 'rewrite') {
    const [, srcDir, dst, tmp, srcJson, dstJson] = argv;
    let src = srcDir;   // 记录里的旧路径以会话自己的 cwd（<目录>/<local_id>/outputs）为准，它不一定是现在所在的目录
    try { const cwd = JSON.parse(read(srcJson)).cwd || '', mark = '/' + srcJson.split('/').pop().replace(/\.json$/, '') + '/';
          if (cwd.indexOf(mark) > 0) src = cwd.slice(0, cwd.indexOf(mark)); } catch (e) {}
    const pairs = [[src, dst], [san(src), san(dst)]];
    const fix = t => pairs.reduce((t, [x, y]) => t.split(x).join(y), t);
    const cl = tmp + '/.claude';
    if (fm.fileExistsAtPath(cl)) {
      const projects = cl + '/projects';
      for (const d of list(projects)) if (fix(d) !== d) fm.moveItemAtPathToPathError(projects + '/' + d, projects + '/' + fix(d), null);
      const e = fm.enumeratorAtPath(cl); let r;
      while (!(r = e.nextObject).isNil()) {
        const rel = ObjC.unwrap(r), f = cl + '/' + rel, base = rel.split('/').pop();
        if (!/\.jsonl?$|\.json\.backup/.test(base)) continue;
        const t = read(f); if (t === null || fix(t) === t) continue;
        write(f, fix(t), f);
      }
    }
    const meta = fix(read(srcJson) || ''); JSON.parse(meta);   // 会话信息必须还是合法 JSON，否则整个会话不复制
    write(dstJson, meta, srcJson);
    return 'ok';
  }
  throw new Error('未知操作 ' + op);
}
EOF
}
cowork_copy() {  # cowork_copy <源目录> <目标目录> <local_id>：复制到目标的临时名下改好路径再换进去，目标原有的一份挪进备份
  local src="$1" dst="$2" name="$3" tmp="$2/.aa-switch-$3"
  rm -rf "$tmp" "$tmp.json"
  if [ -d "$src/$name" ]; then   # APFS 上用克隆（cp -c），大会话也不额外占空间；不支持时退回普通复制
    cp -cRp "$src/$name" "$tmp" 2>/dev/null || { rm -rf "$tmp"; cp -Rp "$src/$name" "$tmp" || { rm -rf "$tmp"; return 1; }; }
  fi
  if ! cowork_js rewrite "$src" "$dst" "$tmp" "$src/$name.json" "$tmp.json" >/dev/null 2>&1; then rm -rf "$tmp" "$tmp.json"; return 1; fi
  if [ -e "$dst/$name.json" ] || [ -e "$dst/$name" ]; then
    mkdir -p "$BK/cowork/$(basename "$dst")"
    if [ -e "$dst/$name" ]; then mv "$dst/$name" "$BK/cowork/$(basename "$dst")/"; fi
    if [ -e "$dst/$name.json" ]; then mv "$dst/$name.json" "$BK/cowork/$(basename "$dst")/"; fi
  fi
  if [ -d "$tmp" ]; then mv "$tmp" "$dst/$name"; fi
  mv "$tmp.json" "$dst/$name.json"
}
desktop_sync_cowork() {  # 两个 profile 的 Cowork 会话互相同步（规则见上）；应该在桌面应用退出后调用
  local ids acct org a b plan act name new old n=0 c=0 f=0 ledger="$CLAUDE_HOME/claude-mode-cowork-sync" led=""
  a="$DESKTOP_DATA/local-agent-mode-sessions"; b="${DESKTOP_DATA}-3p/local-agent-mode-sessions"
  if [ ! -d "$a" ] && [ ! -d "$b" ]; then return 0; fi   # 没用过 Cowork
  ids="$(oauth_ids)"; acct="${ids%% *}"; org="${ids#* }"; [ "$org" = "$ids" ] && org=""
  a="$(cowork_dir "$DESKTOP_DATA" "$acct" "$org")"
  b="$(cowork_dir "${DESKTOP_DATA}-3p")"
  if [ -z "$a" ] || [ -z "$b" ]; then
    say "Cowork 会话暂时没法同步（$( [ -z "$b" ] && echo "网关模式还没初始化过 Cowork，在网关模式下打开一次 Cowork 标签后再切一次即可" || echo "账号模式的 Cowork 目录没找到" )）。"
    return 0
  fi
  plan="$(cowork_js plan "$a" "$b" "$ledger" 2>/dev/null)" || { say "读取 Cowork 会话列表失败，这次没有同步。"; return 0; }
  while read -r act name new old; do
    [ -n "$act" ] || continue
    case "$act" in
      a2b|b2a)
        if { [ "$act" = a2b ] && cowork_copy "$a" "$b" "$name"; } || { [ "$act" = b2a ] && cowork_copy "$b" "$a" "$name"; }; then
          n=$((n+1)); led="$led$name $new
"
        else
          f=$((f+1)); if [ "$old" != - ]; then led="$led$name $old
"; fi
        fi ;;
      conflict) c=$((c+1)); led="$led$name $old
" ;;
      *) led="$led$name $new
" ;;
    esac
  done <<EOF
$plan
EOF
  printf '%s' "$led" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
  say "Cowork 会话已同步（更新 ${n} 条）。"
  if [ "$c" -gt 0 ]; then say "有 ${c} 条 Cowork 会话在两种模式下都继续聊过，没法合并，两边各自保留。"; fi
  if [ "$f" -gt 0 ]; then say "有 ${f} 条 Cowork 会话复制失败，下次切换时再试。"; fi
  return 0
}
backup_desktop() {
  mkdir -p "$BK/desktop"
  [ -f "$DESKTOP_CONF" ] && cp -p "$DESKTOP_CONF" "$BK/desktop/"
  [ -d "$DESKTOP_LIB" ] && cp -Rp "$DESKTOP_LIB" "$BK/desktop/configLibrary"
  prune_backups
}
mode_desktop_gateway() {
  desktop_installed || die "这台电脑上没有找到 ${DESKTOP_APP}.app。"
  load_conf
  if [ -z "$BASE_URL" ]; then say "还没有配置 API 地址，先配置一次："; do_configure; fi
  local key url models; key="$(get_key)" || exit 1
  check_key "$BASE_URL" "$key"
  url="$(conf_get desktop_base_url)"; url="${url:-${BASE_URL%/}}"   # 不带 /v1：桌面应用把地址交给 Claude Code 引擎，引擎自己加 /v1/messages
  models="$(conf_get desktop_models)"; models="${models:-claude-fable-5-1,claude-fable-5,claude-opus-5}"
  backup_desktop
  desktop_json write-gateway "$url" "$key" "$models" >/dev/null || die "写入桌面应用的网关配置失败。"
  chmod 600 "$DESKTOP_LIB"/*.json 2>/dev/null || true   # 里面有 key
  desktop_json set-mode 3p >/dev/null || die "写入 ${DESKTOP_CONF} 失败。"
  desktop_quit   # 先退出再同步：应用开着时会话文件可能正写到一半
  desktop_sync_sessions
  desktop_sync_cowork
  say "已把 ${DESKTOP_APP} 切到网关模式（${url}，模型：${models}）。"
  desktop_reopen
}
mode_desktop_account() {
  desktop_installed || die "这台电脑上没有找到 ${DESKTOP_APP}.app。"
  backup_desktop
  desktop_json set-mode 1p >/dev/null || die "写入 ${DESKTOP_CONF} 失败。"
  desktop_quit   # 先退出再同步：应用开着时会话文件可能正写到一半
  desktop_sync_sessions
  desktop_sync_cowork
  say "已把 ${DESKTOP_APP} 切回账号模式。"
  desktop_reopen
}

# ---------- 各命令 ----------
mode_api() {
  load_conf
  if [ -z "$BASE_URL" ]; then say "还没有配置 API 地址，先配置一次："; do_configure; fi
  local key; key="$(get_key)" || exit 1
  check_key "$BASE_URL" "$key"
  read_env
  backup_settings
  json_env set "$BASE_URL" "$key" "$(pairs_to_header_lines "$HEADERS")" >/dev/null || die "写入 ${SETTINGS} 失败。"
  say "已切到 API 模式（${BASE_URL}）。终端和 IDE 插件里新开的 Claude Code 会话立即生效；Claude 桌面应用的 Code 标签要另用 desktop gateway 切换。"
  if [ "$(env_field "$ENVJSON" api_key)" = true ]; then say "注意：settings.json 的 env 里另有 ANTHROPIC_API_KEY，不是本脚本写的；切回账号时它仍会盖过账号登录。"; fi
}
mode_account() {
  read_env
  backup_settings
  json_env clear >/dev/null || die "写入 ${SETTINGS} 失败。"
  if account_logged_in; then
    say "已切回 Claude 账号模式（账号仍在登录状态）。"
  else
    say "已切回 Claude 账号模式。当前没有账号登录态，请在 Claude Code 里运行 /login 登录。"
  fi
  if [ "$(env_field "$ENVJSON" api_key)" = true ]; then say "注意：settings.json 的 env 里另有 ANTHROPIC_API_KEY，不是本脚本写的，它会盖过账号登录；不需要的话请手动删掉。"; fi
}
mode_status() {
  load_conf >/dev/null 2>&1 || true
  read_env
  local active email; active="$(env_field "$ENVJSON" base_url)"
  if [ -n "$active" ]; then
    echo "模式：API（终端和 IDE 插件）"
    echo "请求发往：${active}"
    case "$(desktop_mode)" in
      gateway) echo "桌面应用：网关模式" ;;
      account) echo "桌面应用：账号模式（Code 标签不走上面的 API，见 desktop 命令）" ;;
    esac
    if [ -n "$BASE_URL" ] && [ "${BASE_URL%/}" != "${active%/}" ]; then echo "新地址尚未生效：${BASE_URL}（重新切换到 API 后生效）"; fi
  else
    echo "模式：Claude 账号"
    if [ -n "$BASE_URL" ]; then echo "API 地址（切换后使用）：${BASE_URL}"; else echo "API 地址（切换后使用）：未配置"; fi
  fi
  email="$(account_email)"
  # 注意：系统自带的 bash 3.2 在 UTF-8 locale 下，${x:+中文} 这类展开会把多字节字符当成变量名，所以用 if 拼
  if account_logged_in; then
    if [ -n "$email" ]; then echo "账号：已登录（${email}）"; else echo "账号：已登录"; fi
  else echo "账号：未登录"; fi
  if [ -n "$BASE_URL" ]; then
    if [ -n "$(kc_get "$(kc_service "$BASE_URL")")" ]; then echo "钥匙串：已保存 key"; else echo "钥匙串：未保存 key（切 API 模式时会提示输入）"; fi
  fi
  if [ "$(env_field "$ENVJSON" api_key)" = true ]; then echo "注意：settings.json 里另有 ANTHROPIC_API_KEY，会盖过账号登录"; fi
  return 0
}
mode_word() { if claude_installed; then current_mode; else echo absent; fi; }
do_configure() {
  load_conf
  local url hdr key=""
  if [ -n "${CLAUDE_MODE_BASE_URL:-}${CLAUDE_MODE_HEADERS:-}${CLAUDE_MODE_KEY_STDIN:-}" ]; then  # 非交互（图形界面）
    url="${CLAUDE_MODE_BASE_URL:-$BASE_URL}"; hdr="${CLAUDE_MODE_HEADERS-$HEADERS}"
    if [ "${CLAUDE_MODE_KEY_STDIN:-}" = 1 ]; then IFS= read -r key || true; fi
  else
    url="$(ask '请输入 API 地址（网关根地址，不带 /v1，例如 https://api.example.com）' "$BASE_URL")" || exit 1
    hdr="$(ask '额外请求头（格式 名称=值，多个用英文逗号分隔；通常留空，输入 - 表示清空）' "$HEADERS")" || exit 1
    [ "$hdr" = - ] && hdr=""
  fi
  url="${url%/}"; valid_url "$url" || die "地址格式不对：${url}（需要以 http:// 或 https:// 开头的完整地址）"
  case "$url" in */v1) say "提示：Claude Code 会自己在地址后面加 /v1/…，已去掉你填的 /v1。"; url="${url%/v1}" ;; esac
  pairs_to_header_lines "$hdr" >/dev/null   # 只做格式检查
  HEADERS="$hdr"; BASE_URL="$url"
  conf_set base_url "$BASE_URL"; conf_set headers "$HEADERS"
  say "已保存到 ${CONF}。"
  if [ -z "${CLAUDE_MODE_BASE_URL:-}${CLAUDE_MODE_HEADERS:-}${CLAUDE_MODE_KEY_STDIN:-}" ]; then
    if [ -n "$(kc_get "$(kc_service "$BASE_URL")")" ]; then
      key="$(ask_secret "API key（钥匙串里已有一个，回车沿用）")" || exit 1
    else
      key="$(ask_secret "API key（回车跳过，切 API 模式时再输）")" || exit 1
    fi
  fi
  if [ -n "$key" ]; then kc_set "$(kc_service "$BASE_URL")" "$key"; say "key 已存入钥匙串。"; fi
}
show_config() { load_conf >/dev/null 2>&1 || true; echo "base_url=$BASE_URL"; echo "headers=$HEADERS"; }
set_key() {
  load_conf; [ -n "$BASE_URL" ] || die "请先运行 claude-mode configure。"
  local key; key="$(ask_secret "请输入 $(url_host "$BASE_URL") 的 API key")" || exit 1
  [ -n "$key" ] || die "未输入 key。"
  kc_set "$(kc_service "$BASE_URL")" "$key"; say "已存入钥匙串。"
}
forget_key() {
  load_conf; [ -n "$BASE_URL" ] || die "请先运行 claude-mode configure。"
  if kc_del "$(kc_service "$BASE_URL")"; then say "已从钥匙串删除。"; else say "钥匙串里没有保存的 key。"; fi
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
case "$1" in
  api) mode_api ;;
  account) mode_account ;;
  status) mode_status ;;
  configure) do_configure ;;
  set-key) set_key ;;
  forget-key) forget_key ;;
  mode) mode_word ;;
  desktop-mode) desktop_mode ;;
  desktop) case "${2:-}" in gateway) mode_desktop_gateway ;; account) mode_desktop_account ;; sync) desktop_installed || die "没有找到 ${DESKTOP_APP}.app。"; backup_desktop; desktop_sync_sessions
      if desktop_running; then say "Cowork 会话要在 ${DESKTOP_APP} 退出后才能同步（切换时会自动做），这次跳过。"; else desktop_sync_cowork; fi ;; *) die "用法：claude-mode desktop gateway|account|sync" ;; esac ;;
  version) echo "$CLAUDE_MODE_VERSION" ;;
  config) show_config ;;
  has-key|find-key) [ -n "${2:-}" ] && valid_url "$2" || die "用法：claude-mode has-key URL"; [ -n "$(kc_get "$(kc_service "$2")")" ] ;;
  key) [ -n "${2:-}" ] && valid_url "$2" || die "用法：claude-mode key URL"; kc_get "$(kc_service "$2")" ;;
  *) usage ;;
esac
