#!/bin/bash
# 发版前的冒烟测试：在一个空的临时家目录里（模拟刚装上的新用户）把 codex-mode.sh 和 claude-mode.sh 的主要路径各跑一遍，
# 任何一步退出码或写出的文件不对就失败。menubar/build.sh 打包前会先跑它，不通过就不出包。
#
#   ./smoke-test.sh                      测仓库里的两个脚本
#   SMOKE_SCRIPTS_DIR=某目录 ./smoke-test.sh   测别处的脚本（比如验证这个测试拦得住某个旧版本的 bug）
#   SMOKE_KEEP=1 ./smoke-test.sh         失败后保留临时目录，方便看现场
#
# 不碰真实环境：HOME、CODEX_HOME、CLAUDE_CONFIG_DIR、桌面应用数据目录都指到临时目录；钥匙串（security）、网关探测（curl）、
# 进程检查（pgrep）、打开应用（open）和 codex 命令行都用 PATH 最前面的假替身；osascript 只放行读写 JSON 的 JavaScript，
# “让某个应用退出”那种一律不执行。用系统自带的 /bin/bash（3.2）跑，和用户机器上一致。
# 测不到的：菜单和弹窗、真实网关、真的 Codex / Claude 对配置的反应。
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${SMOKE_SCRIPTS_DIR:-$ROOT}"
T="$(mktemp -d "${TMPDIR:-/tmp}/aaswitch-smoke.XXXXXX")"
FAILED=0; PASSED=0
cleanup() { if [ "$FAILED" -gt 0 ] && [ "${SMOKE_KEEP:-}" = 1 ]; then echo "现场保留在 $T" >&2; else rm -rf "$T"; fi; }
trap cleanup EXIT

# ---------- 假替身 ----------
mkdir -p "$T/bin" "$T/keychain" "$T/home/Applications/Claude.app" "$T/codex" "$T/claude"
cat > "$T/bin/security" <<'EOF'
#!/bin/bash
# 假钥匙串：每个条目一个文件
cmd="${1:-}"; shift || true; svc=""; pw=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -a) shift 2 ;;
    -w) if [ "$cmd" = add-generic-password ]; then pw="$2"; shift 2; else shift; fi ;;
    *) shift ;;
  esac
done
f="$SMOKE_KEYCHAIN/$(printf '%s' "$svc" | tr -c 'A-Za-z0-9._-' '_')"
case "$cmd" in
  find-generic-password) [ -f "$f" ] && cat "$f" || exit 44 ;;
  add-generic-password) printf '%s\n' "$pw" > "$f" ;;
  delete-generic-password) [ -f "$f" ] && rm -f "$f" || exit 44 ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
# 假网关：只回一个 HTTP 状态码（脚本用 -w '%{http_code}' 取它）
printf '%s' "${SMOKE_HTTP_CODE:-200}"
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
# 假进程表：默认什么都没在运行。$SMOKE_PROC/app 存在 = 应用开着；codex_forever 存在 = 一直有 codex 进程；
# codex_until 里是个时间戳，到点之前算有 codex 进程（模拟应用自带的子进程比主进程晚退）
case "${2:-}" in
  Codex) [ -f "$SMOKE_PROC/app" ] ;;
  Claude) [ -f "$SMOKE_PROC/claude_app" ] ;;
  codex)
    [ -f "$SMOKE_PROC/codex_forever" ] && exit 0
    [ -f "$SMOKE_PROC/codex_until" ] && [ "$(date +%s)" -lt "$(cat "$SMOKE_PROC/codex_until")" ] ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/open" <<'EOF'
#!/bin/bash
echo "$*" >> "$SMOKE_PROC/open.log"
EOF
cat > "$T/bin/osascript" <<'EOF'
#!/bin/bash
# 只放行 JavaScript（读写 JSON 用）；AppleScript（让应用退出）不执行，只在假进程表里记一笔
if [ "${1:-}" = -l ] && [ "${2:-}" = JavaScript ]; then exec /usr/bin/osascript "$@"; fi
case "$*" in *"to quit"*)
  rm -f "$SMOKE_PROC/app"
  [ -n "${SMOKE_LINGER:-}" ] && echo $(( $(date +%s) + SMOKE_LINGER )) > "$SMOKE_PROC/codex_until" ;;
esac
exit 0
EOF
cat > "$T/bin/codex" <<'EOF'
#!/bin/bash
# 假 codex 命令行：登录态就是 $CODEX_HOME/auth.json
auth="$CODEX_HOME/auth.json"
case "$*" in
  "login status")
    if grep -q '"OPENAI_API_KEY"' "$auth" 2>/dev/null; then echo "Logged in using an API key - sk-***"
    elif grep -q '"refresh_token"' "$auth" 2>/dev/null; then echo "Logged in using ChatGPT"
    else echo "Not logged in"; exit 1; fi ;;
  "login --with-api-key")
    [ "${SMOKE_LOGIN_FAIL:-}" = 1 ] && exit 1
    IFS= read -r key || true
    printf '{ "OPENAI_API_KEY": "%s" }\n' "$key" > "$auth" ;;
  "logout") rm -f "$auth" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin"/*

export HOME="$T/home" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8
unset LC_ALL 2>/dev/null || true
export SMOKE_KEYCHAIN="$T/keychain" SMOKE_PROC="$T/proc"; mkdir -p "$SMOKE_PROC"
export CODEX_HOME="$T/codex" CODEX_BIN="$T/bin/codex" CODEX_APP_NAME=Codex
export CODEX_MODE_NONINTERACTIVE=1 CODEX_MODE_NO_REOPEN=1 CODEX_MODE_FORCE=1
export CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_DESKTOP_DATA_DIR="$T/desktop/Claude"
export CLAUDE_MODE_NONINTERACTIVE=1 CLAUDE_MODE_NO_REOPEN=1

# ---------- 断言 ----------
OUT=""; ERR=""; CODE=0
run() {  # run codex|claude 参数…：结果放进 OUT / ERR / CODE
  local script="$SCRIPTS/$1-mode.sh"; shift
  OUT="$(/bin/bash "$script" "$@" 2>"$T/stderr" </dev/null)"; CODE=$?
  ERR="$(cat "$T/stderr")"
}
run_stdin() { local input="$1" script="$SCRIPTS/$2-mode.sh"; shift 2; OUT="$(printf '%s\n' "$input" | /bin/bash "$script" "$@" 2>"$T/stderr")"; CODE=$?; ERR="$(cat "$T/stderr")"; }
pass() { PASSED=$((PASSED+1)); }
fail() { FAILED=$((FAILED+1)); echo "  ✗ $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /' >&2; return 0; }
ok() {  # ok 说明：上一条 run 的退出码应为 0
  if [ "$CODE" -eq 0 ]; then pass; else fail "$1（退出码 ${CODE}）" "${ERR:-（脚本没有输出）}"; fi
}
fails() { if [ "$CODE" -ne 0 ]; then pass; else fail "$1（本该失败，却成功了）" "$OUT"; fi; }
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1" "期望：$3"$'\n'"实际：$2"; fi; }
has() { case "$2" in *"$3"*) pass ;; *) fail "$1" "没有找到：$3"$'\n'"实际：$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "不该出现：$3" ;; *) pass ;; esac; }
json() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }   # json 文件 键路径
sum() { cksum < "$1"; }

GW="https://gw.example.test"; KEY="sk-smoke-0123456789abcdef"

# ==================== Codex ====================
echo "· codex-mode $(/bin/bash "$SCRIPTS/codex-mode.sh" version 2>/dev/null)"
run codex mode;   ok "全新环境 mode"; eq "全新环境是 none" "$OUT" none
run codex status; ok "全新环境 status"; has "status 说明还没切换过" "$OUT" "尚未切换过"
run codex has-key "$GW/v1"; fails "还没存 key 时 has-key"

CODEX_MODE_BASE_URL="$GW" CODEX_MODE_HEADERS="x-smoke=1, x-other=two" CODEX_MODE_KEY_STDIN=1 run_stdin "$KEY" codex configure
ok "configure（图形界面的非交互方式）"
run codex config; ok "config"; has "地址自动补 /v1" "$OUT" "base_url=$GW/v1"; has "请求头存下来了" "$OUT" "headers=x-smoke=1, x-other=two"
run codex key "$GW/v1"; eq "key 能读回来" "$OUT" "$KEY"
run codex has-key "$GW/v1"; ok "has-key"
run codex find-key "$GW/v1"; ok "find-key"

# 用户原有的东西：自己的配置、一条账号时期的会话（文件 + 数据库）、ChatGPT 登录态
cat > "$CODEX_HOME/config.toml" <<'EOF'
model = "gpt-5"

[projects."/Users/someone/work"]
trust_level = "trusted"
EOF
mkdir -p "$CODEX_HOME/sessions/2026/09/01"
SESSION="$CODEX_HOME/sessions/2026/09/01/rollout-smoke.jsonl"
printf '%s\n%s\n' '{"type":"session_meta","payload":{"id":"s1","model_provider":"openai"}}' '{"type":"message","text":"model_provider openai"}' > "$SESSION"
sqlite3 "$CODEX_HOME/state_1.sqlite" "create table threads(id text, model_provider text); insert into threads values('s1','openai');"
printf '{ "tokens": { "refresh_token": "rt-smoke" } }\n' > "$CODEX_HOME/auth.json"

run codex api; ok "第一次切到 API（备份不足 20 份，2.2.3 的 bug 就坏在这里）"
run codex mode; eq "切完是 api" "$OUT" api
CFG="$(cat "$CODEX_HOME/config.toml")"
has "config.toml 写了网关地址" "$CFG" "base_url = \"$GW/v1\""
has "config.toml 写了请求头" "$CFG" 'http_headers = { "x-smoke" = "1", "x-other" = "two" }'
has "用户自己的配置还在" "$CFG" 'model = "gpt-5"'
has "用户的 projects 段还在" "$CFG" '[projects."/Users/someone/work"]'
has "用 key 登录了" "$(cat "$CODEX_HOME/auth.json")" "$KEY"
hasnt "会话文件首行改记了 provider" "$(head -n1 "$SESSION")" '"model_provider":"openai"'
has "会话文件正文没动" "$(sed -n 2p "$SESSION")" 'model_provider openai'
eq "数据库里的会话改记了" "$(sqlite3 "$CODEX_HOME/state_1.sqlite" "select count(*) from threads where model_provider='openai'")" 0
[ -f "$CODEX_HOME/codex-mode-auth/chatgpt.json" ] && pass || fail "ChatGPT 登录态没有存档"
[ -n "$(find "$CODEX_HOME/codex-mode-backups" -name config.toml 2>/dev/null | head -n1)" ] && pass || fail "切换前没有备份 config.toml"
run codex status; ok "API 模式 status"; has "status 显示 API" "$OUT" "模式：API"; has "status 显示已保存 key" "$OUT" "已保存 key"

run codex chatgpt; ok "切回账号"
run codex mode; eq "切完是 chatgpt" "$OUT" chatgpt
has "恢复了 ChatGPT 登录态" "$(cat "$CODEX_HOME/auth.json")" "rt-smoke"
has "账号模式下地址被注释掉" "$(cat "$CODEX_HOME/config.toml")" "# base_url = \"$GW/v1\""
has "用户自己的配置还在（切回后）" "$(cat "$CODEX_HOME/config.toml")" 'model = "gpt-5"'
run codex status; ok "账号模式 status"; has "status 显示账号" "$OUT" "模式：ChatGPT 账号"

BEFORE="$(sum "$CODEX_HOME/config.toml")"
SMOKE_HTTP_CODE=401 run codex api; fails "key 被网关拒绝（401）时切 API"; has "401 的报错说清楚了" "$ERR" "无效"
eq "401 时配置没动" "$(sum "$CODEX_HOME/config.toml")" "$BEFORE"
SMOKE_LOGIN_FAIL=1 run codex api; fails "codex 登录失败时切 API"
eq "登录失败后配置回滚了" "$(sum "$CODEX_HOME/config.toml")" "$BEFORE"
has "登录失败后登录态回滚了" "$(cat "$CODEX_HOME/auth.json")" "rt-smoke"
run codex mode; eq "登录失败后仍是 chatgpt" "$OUT" chatgpt

# 真的走一遍“退出应用 → 切换 → 重新打开”（上面都用 CODEX_MODE_FORCE=1 跳过了这一段）
touch "$SMOKE_PROC/app"; rm -f "$SMOKE_PROC/open.log"
CODEX_MODE_FORCE="" CODEX_MODE_NO_REOPEN="" SMOKE_LINGER=2 run codex fix-threads
ok "应用自带的 codex 子进程晚 2 秒退出时，等它而不是报错"
has "切完重新打开了应用" "$(cat "$SMOKE_PROC/open.log" 2>/dev/null)" "-a Codex"
touch "$SMOKE_PROC/app" "$SMOKE_PROC/codex_forever"; rm -f "$SMOKE_PROC/open.log"
CODEX_MODE_FORCE="" CODEX_MODE_NO_REOPEN="" run codex fix-threads
fails "还有外部 codex 会话时切换"; has "报错说清楚了" "$ERR" "codex 命令行或 IDE"
has "切换失败也把应用重新打开" "$(cat "$SMOKE_PROC/open.log" 2>/dev/null)" "-a Codex"
rm -f "$SMOKE_PROC/codex_forever"; touch "$SMOKE_PROC/app"; rm -f "$SMOKE_PROC/open.log"
CODEX_MODE_FORCE="" CODEX_MODE_NO_REOPEN="" SMOKE_LOGIN_FAIL=1 run codex api
fails "应用开着、登录失败时切 API"; has "登录失败也把应用重新打开" "$(cat "$SMOKE_PROC/open.log" 2>/dev/null)" "-a Codex"
rm -f "$SMOKE_PROC"/*

for i in $(seq 10 34); do mkdir -p "$CODEX_HOME/codex-mode-backups/20200101-0000$i"; done   # 25 份老备份
sleep 1   # 备份目录名精确到秒，和上面几次错开
run codex api; ok "备份超过 20 份时切 API"
eq "备份只留 20 份" "$(ls -1d "$CODEX_HOME"/codex-mode-backups/[0-9]*-[0-9]* | wc -l | tr -d ' ')" 20
run codex fix-threads; ok "fix-threads"
run codex forget-key; ok "forget-key"
run codex has-key "$GW/v1"; fails "forget-key 之后 has-key"
printf '%s\n' "$KEY" > "$SMOKE_KEYCHAIN/codex-mode_gw.example.test"   # 放回去，Claude 那边共用这个 key

# ==================== Claude Code ====================
echo "· claude-mode $(/bin/bash "$SCRIPTS/claude-mode.sh" version 2>/dev/null)"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
run claude mode; ok "全新环境 mode"; eq "没用过 Claude Code 是 absent" "$OUT" absent
printf '{ "oauthAccount": { "emailAddress": "smoke@example.test", "accountUuid": "11111111-1111-1111-1111-111111111111", "organizationUuid": "22222222-2222-2222-2222-222222222222" } }\n' > "$HOME/.claude.json"
run claude mode; ok "mode"; eq "用过但没切过是 account" "$OUT" account
run claude config; ok "config"; has "沿用 codex-mode 的网关并去掉 /v1" "$OUT" "base_url=$GW"; hasnt "去掉了 /v1" "$OUT" "/v1"
run claude status; ok "全新环境 status"; has "status 显示账号" "$OUT" "模式：Claude 账号"

CLAUDE_MODE_BASE_URL="$GW/v1" CLAUDE_MODE_HEADERS="x-smoke=1" CLAUDE_MODE_KEY_STDIN=1 run_stdin "" claude configure
ok "configure（key 留空 = 沿用已保存的）"
run claude config; has "configure 去掉了 /v1" "$OUT" "base_url=$GW"$'\n'; has "请求头存下来了" "$OUT" "headers=x-smoke=1"
run claude key "$GW"; eq "和 codex-mode 共用同一个 key" "$OUT" "$KEY"

run claude api; ok "第一次切到 API（还没有 settings.json）"
eq "写了网关地址" "$(json "$SETTINGS" env.ANTHROPIC_BASE_URL)" "$GW"
eq "写了 key" "$(json "$SETTINGS" env.ANTHROPIC_AUTH_TOKEN)" "$KEY"
eq "写了请求头" "$(json "$SETTINGS" env.ANTHROPIC_CUSTOM_HEADERS)" "x-smoke: 1"
run claude mode; eq "切完是 api" "$OUT" api
run claude status; ok "API 模式 status"; has "status 显示 API" "$OUT" "模式：API"
run claude account; ok "切回账号"
run claude mode; eq "切完是 account" "$OUT" account

printf '{ "theme": "dark", "env": { "FOO": "1" }, "permissions": { "allow": ["Bash(ls:*)"] } }\n' > "$SETTINGS"   # 用户自己的设置
run claude api; ok "已有 settings.json 时切到 API"
eq "用户的 theme 还在" "$(json "$SETTINGS" theme)" dark
eq "用户的 env.FOO 还在" "$(json "$SETTINGS" env.FOO)" 1
eq "用户的 permissions 还在" "$(json "$SETTINGS" permissions.allow.0)" "Bash(ls:*)"
[ -n "$(find "$CLAUDE_CONFIG_DIR/claude-mode-backups" -name settings.json 2>/dev/null | head -n1)" ] && pass || fail "切换前没有备份 settings.json"
run claude account; ok "再切回账号"
eq "网关地址删掉了" "$(json "$SETTINGS" env.ANTHROPIC_BASE_URL)" ""
eq "key 删掉了" "$(json "$SETTINGS" env.ANTHROPIC_AUTH_TOKEN)" ""
eq "用户的 env.FOO 还在（切回后）" "$(json "$SETTINGS" env.FOO)" 1
eq "用户的 theme 还在（切回后）" "$(json "$SETTINGS" theme)" dark

BEFORE="$(sum "$SETTINGS")"
SMOKE_HTTP_CODE=403 run claude api; fails "key 被网关拒绝（403）时切 API"
eq "403 时 settings.json 没动" "$(sum "$SETTINGS")" "$BEFORE"
cp "$SETTINGS" "$T/settings.good"; printf '{ 这不是 JSON' > "$SETTINGS"; BEFORE="$(sum "$SETTINGS")"
run claude api; fails "settings.json 坏了时切 API"; has "报错说清楚了" "$ERR" "JSON"
eq "坏的 settings.json 没被覆盖" "$(sum "$SETTINGS")" "$BEFORE"
cp "$T/settings.good" "$SETTINGS"

# 桌面应用：两边各有一条会话，切到网关后互相补齐
A="$CLAUDE_DESKTOP_DATA_DIR/claude-code-sessions/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222"
B="$CLAUDE_DESKTOP_DATA_DIR-3p/claude-code-sessions/33333333-3333-3333-3333-333333333333/44444444-4444-4444-4444-444444444444"
mkdir -p "$A" "$B"; echo '{}' > "$A/local_aaa.json"; echo '{}' > "$B/local_bbb.json"
# Cowork：账号模式两条会话（ccc、ddd），网关模式一条（eee）；会话里的路径都指向自己所在的位置
CA="$CLAUDE_DESKTOP_DATA_DIR/local-agent-mode-sessions/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222"
CB="$CLAUDE_DESKTOP_DATA_DIR-3p/local-agent-mode-sessions/33333333/00000000"
dashes() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'; }
cowork() {  # cowork 目录 名字 lastActivityAt 对话内容
  local d="$1/local_$2" p; p="$(dashes "$1/local_$2/outputs")"
  mkdir -p "$d/outputs" "$d/.claude/projects/$p"
  printf '{ "sessionId": "local_%s", "cwd": "%s/outputs", "lastActivityAt": %s }\n' "$2" "$d" "$3" > "$d.json"
  printf '{ "cwd": "%s/outputs", "text": "%s" }\n' "$d" "$4" > "$d/.claude/projects/$p/chat.jsonl"
  printf '%s\n' "$d" > "$d/audit.jsonl"; echo "产物" > "$d/outputs/result.txt"
}
cowork "$CA" ccc 100 "ccc 第一轮"; cowork "$CA" ddd 100 "ddd 第一轮"; cowork "$CB" eee 100 "eee 第一轮"
run claude desktop-mode; ok "desktop-mode"; eq "桌面应用一开始是 account" "$OUT" account
run claude desktop gateway; ok "桌面应用切到网关"
run claude desktop-mode; eq "切完是 gateway" "$OUT" gateway
LIB="$CLAUDE_DESKTOP_DATA_DIR-3p/configLibrary"
ENTRY="$LIB/$(json "$LIB/_meta.json" appliedId).json"
eq "网关配置里的地址" "$(json "$ENTRY" inferenceGatewayBaseUrl)" "$GW"
eq "网关配置里的 key" "$(json "$ENTRY" inferenceGatewayApiKey)" "$KEY"
eq "带 key 的文件权限是 600" "$(stat -f %Lp "$ENTRY" 2>/dev/null)" 600
[ -f "$A/local_bbb.json" ] && [ -f "$B/local_aaa.json" ] && pass || fail "两边的会话列表没有互相补齐"
run claude desktop account; ok "桌面应用切回账号"
run claude desktop-mode; eq "切完是 account" "$OUT" account

# Cowork：切到网关时互相补齐，路径改到新位置，对话记录目录跟着改名，签名的 audit.jsonl 和产物原样
[ -f "$CB/local_ccc.json" ] && [ -f "$CB/local_ddd.json" ] && [ -f "$CA/local_eee.json" ] && pass || fail "两边的 Cowork 会话没有互相补齐"
eq "复制过去的 cwd 指向新位置" "$(json "$CB/local_ccc.json" cwd)" "$CB/local_ccc/outputs"
has "对话记录里的路径改到新位置" "$(cat "$CB/local_ccc/.claude/projects/$(dashes "$CB/local_ccc/outputs")/chat.jsonl" 2>/dev/null)" "\"cwd\": \"$CB/local_ccc/outputs\""
eq "audit.jsonl 原样复制" "$(cat "$CB/local_ccc/audit.jsonl" 2>/dev/null)" "$CA/local_ccc"
eq "产物原样复制" "$(cat "$CB/local_ccc/outputs/result.txt" 2>/dev/null)" "产物"
eq "反方向也改了路径" "$(json "$CA/local_eee.json" cwd)" "$CA/local_eee/outputs"
# 网关模式下接着聊 ccc（变新），切回账号时账号那份被更新，旧的进了备份
cowork "$CB" ccc 200 "ccc 第二轮"
run claude desktop sync; ok "desktop sync（只有一边变新）"
eq "账号那份更新成新的" "$(json "$CA/local_ccc.json" lastActivityAt)" 200
has "账号那份的对话记录是新的、路径是账号这边的" "$(cat "$CA/local_ccc/.claude/projects/$(dashes "$CA/local_ccc/outputs")/chat.jsonl" 2>/dev/null)" "\"cwd\": \"$CA/local_ccc/outputs\", \"text\": \"ccc 第二轮\""
[ -n "$(find "$CLAUDE_CONFIG_DIR/claude-mode-backups" -path '*/cowork/*' -name local_ccc.json 2>/dev/null | head -n1)" ] && pass || fail "被覆盖的旧会话没有进备份"
# 两边都接着聊了 ddd：冲突，不动
cowork "$CA" ddd 300 "ddd 账号这边"; cowork "$CB" ddd 301 "ddd 网关这边"
run claude desktop sync; ok "desktop sync（两边都变新）"; has "冲突说清楚了" "$ERR" "没法合并"
eq "冲突时账号那份没被覆盖" "$(json "$CA/local_ddd.json" lastActivityAt)" 300
eq "冲突时网关那份没被覆盖" "$(json "$CB/local_ddd.json" lastActivityAt)" 301
# 在网关模式下删掉 eee：不再从账号那边补回去
rm -rf "$CB/local_eee" "$CB/local_eee.json"
run claude desktop sync; ok "desktop sync（一边删了）"
[ ! -e "$CB/local_eee.json" ] && [ -f "$CA/local_eee.json" ] && pass || fail "删掉的 Cowork 会话被补回去了，或另一边的被删了"
# 桌面应用开着时手动 sync 不碰 Cowork
touch "$SMOKE_PROC/claude_app"; cowork "$CA" fff 100 "fff"
run claude desktop sync; ok "应用开着时 desktop sync"; has "说明了为什么跳过" "$ERR" "退出后才能同步"
[ ! -e "$CB/local_fff.json" ] && pass || fail "应用开着时同步了 Cowork 会话"
rm -f "$SMOKE_PROC/claude_app"

echo
if [ "$FAILED" -gt 0 ]; then echo "冒烟测试没有通过：$FAILED 项失败，$PASSED 项通过。" >&2; exit 1; fi
echo "冒烟测试通过（$PASSED 项）。"
