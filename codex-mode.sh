#!/bin/bash
# codex-mode — 在「ChatGPT 账号」和「自定义 API」之间切换 Codex 桌面应用，历史会话在两种模式下都能继续
#
#   codex-mode api          切到自定义 API（退出 Codex → 改配置 → 统一会话 provider → 用 key 登录 → 重开）
#   codex-mode chatgpt      切到 ChatGPT 账号（退出 Codex → 改配置 → 统一会话 provider → 重开，在应用里登录）
#   codex-mode status       查看当前模式（不显示 key）
#   codex-mode configure    设置或修改 API 地址、额外请求头和 key（图形界面可用环境变量非交互传入，见下）
#   codex-mode set-key      只更换 key（存入 macOS 钥匙串）
#   codex-mode forget-key   从钥匙串删除本脚本保存的 key
#   codex-mode fix-threads  只做「统一会话 provider」这一步，不改模式（会先退出 Codex）
#   codex-mode mode         只输出一个词 api / chatgpt / none，供菜单栏小工具等程序读取
#   codex-mode version      输出脚本版本号
#   codex-mode config       输出已保存的地址和请求头（不含 key），供程序读取
#   codex-mode has-key URL  钥匙串里有没有该地址的 key（退出码 0 表示有）
#
# 原理：Codex 把每条会话创建时用的 provider 名记在会话里，配置里必须有同名 provider 才能继续该会话。
#   本脚本把 config.toml 的默认 provider 固定为一个名字，两种模式都不改这一行，只改 provider 块里的
#   base_url / http_headers；历史上出现过的其他 provider 名都写成指向同一地址的别名块。指向其他服务且自带
#   密钥（env_key）的 provider 原样保留；没有自己密钥的 provider 依赖全局登录态，两种模式下本来都用不了，所以一并
#   统一。内置的 openai 不允许被覆盖，记成 openai 的会话会改记为默认 provider（改前有备份）。
# 依赖：macOS 自带的 bash、awk、sqlite3、security、osascript，不需要 Python。
# 配置：~/.codex/codex-mode.conf 保存地址、请求头、provider 名；key 只存在 macOS 钥匙串和 Codex 自己的登录态里。
# 备份：每次切换写入前，config.toml、auth.json、被修改的会话文件和数据库都复制到 ~/.codex/codex-mode-backups/<时间>/。
# 登录态：切换前若是 ChatGPT 登录，把 auth.json 存到 ~/.codex/codex-mode-auth/chatgpt.json；切回账号模式时直接恢复，
#   不用重新登录（token 过期时 Codex 会自己提示登录）。
# 环境变量：CODEX_HOME（数据目录）、CODEX_APP_NAME（应用名，默认自动找 ChatGPT / Codex）、CODEX_BIN（CLI 路径）、
#   CODEX_MODE_NO_REOPEN=1（切换后不重开应用）、CODEX_MODE_NONINTERACTIVE=1（需要输入时直接报错，供图形界面调用）、
#   CODEX_MODE_FORCE=1（不退出应用、不检查进程，仅测试用）。
#   非交互配置：CODEX_MODE_BASE_URL、CODEX_MODE_HEADERS（名称=值，逗号分隔）、CODEX_MODE_KEY_STDIN=1（从标准输入读 key，
#   可为空表示沿用已保存的）；三者任一设置时 configure 不再提问。
set -eu
CODEX_MODE_VERSION="2.1.0"

export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CFG="$CODEX_HOME/config.toml"
CONF="$CODEX_HOME/codex-mode.conf"
BK="$CODEX_HOME/codex-mode-backups/$(date +%Y%m%d-%H%M%S)"

APP_NAME="${CODEX_APP_NAME:-}"
if [ -z "$APP_NAME" ]; then
  for n in ChatGPT Codex; do
    if [ -d "/Applications/$n.app" ] || [ -d "$HOME/Applications/$n.app" ]; then APP_NAME=$n; break; fi
  done
  APP_NAME="${APP_NAME:-ChatGPT}"
fi
CODEX="${CODEX_BIN:-}"
if [ -z "$CODEX" ]; then
  for d in /Applications "$HOME/Applications"; do
    if [ -x "$d/$APP_NAME.app/Contents/Resources/codex" ]; then CODEX="$d/$APP_NAME.app/Contents/Resources/codex"; break; fi
  done
  [ -n "$CODEX" ] || CODEX="$(command -v codex || true)"
fi

say() { echo "$*" >&2; }
die() { echo "错误：$*" >&2; exit 1; }
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---------- 配置文件 ~/.codex/codex-mode.conf（key=value，不会被 source 执行） ----------
conf_get() { if [ -f "$CONF" ]; then sed -n "s/^$1=//p" "$CONF" | head -n1; fi; }
conf_set() {
  local tmp; tmp="$(mktemp "$CODEX_HOME/.codex-mode.XXXXXX")"
  if [ -f "$CONF" ]; then grep -v "^$1=" "$CONF" > "$tmp" || true; fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$CONF"
}

# ---------- 交互输入（都从 /dev/tty 读，curl | bash 下也能用） ----------
ask() {  # ask 提示 默认值
  local ans
  [ "${CODEX_MODE_NONINTERACTIVE:-}" = 1 ] && die "需要交互输入（$1），请在终端运行 codex-mode configure。"
  printf '%s' "$1" >&2; [ -n "$2" ] && printf ' [%s]' "$2" >&2; printf ': ' >&2
  IFS= read -r ans < /dev/tty || die "输入已取消。"
  printf '%s' "${ans:-$2}"
}
ask_secret() {
  local ans
  [ "${CODEX_MODE_NONINTERACTIVE:-}" = 1 ] && die "需要输入 API key，请在终端运行 codex-mode set-key。"
  printf '%s（输入不回显）: ' "$1" >&2
  IFS= read -r -s ans < /dev/tty || true; echo >&2
  printf '%s' "$ans"
}

# ---------- 地址、请求头、钥匙串 ----------
valid_url() { case "$1" in http://?*|https://?*) [[ "$1" != *[[:space:]\"\\]* ]] ;; *) return 1 ;; esac; }
url_host() { local h="${1#*://}"; h="${h%%/*}"; h="${h%%:*}"; printf '%s' "${h#*@}"; }
pairs_to_toml() {  # "a=b, c=d" → { "a" = "b", "c" = "d" }
  local out="" pair k v
  [ -n "$1" ] || return 0
  IFS=',' read -r -a pairs <<< "$1"
  for pair in "${pairs[@]}"; do
    [[ "$pair" == *=* ]] || die "请求头格式应为 名称=值：$pair"
    k="$(printf '%s' "${pair%%=*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    v="$(printf '%s' "${pair#*=}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$k" ] || die "请求头名称不能为空：$pair"
    case "$k$v" in *[\"\\]*) die "请求头不能包含引号或反斜杠：$pair" ;; esac
    case "$(printf '%s' "$k" | tr 'A-Z' 'a-z')" in authorization|host|content-length) die "请通过 API key 认证，不要手动设置 $k 请求头。" ;; esac
    out="$out${out:+, }\"$k\" = \"$v\""
  done
  printf '{ %s }' "$out"
}
toml_to_pairs() { printf '%s' "$1" | sed -E 's/^\{ *//; s/ *\}$//; s/" *= *"/=/g; s/"//g'; }
kc_service() { printf 'codex-mode:%s' "$(url_host "$1")"; }
kc_get() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null || true; }
kc_set() { security add-generic-password -a "$USER" -s "$1" -w "$2" -U >/dev/null 2>&1 || die "无法写入 macOS 钥匙串。"; }
kc_del() { security delete-generic-password -a "$USER" -s "$1" >/dev/null 2>&1; }

# ---------- 读取 config.toml ----------
AWK_HDR='
function header(line,   h) {
  h = line; sub(/^[[:space:]]*\[[[:space:]]*/, "", h); sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", h)
  pname = ""
  if (h ~ /^model_providers\./) { pname = substr(h, 17); gsub(/^"|"$/, "", pname) }
  return h
}'
preamble_provider() {  # 文件开头（第一个段之前）的 model_provider 值
  [ -f "$CFG" ] || return 0
  awk '/^[[:space:]]*\[/ { exit }
       /^[[:space:]]*model_provider[[:space:]]*=/ { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); print v; exit }' "$CFG"
}
section_value() {  # section_value provider 键 [active]：取 [model_providers.X] 里某键的值；默认连注释掉的行也算
  [ -f "$CFG" ] || return 0
  local comment='#?'; [ "${3:-}" = active ] && comment=''
  awk -v want="$1" -v key="$2" -v c="$comment" "$AWK_HDR"'
    /^[[:space:]]*\[/ { header($0); insec = (pname == want); next }
    insec && $0 ~ ("^[[:space:]]*" c "[[:space:]]*" key "[[:space:]]*=") {
      v = $0; sub("^[[:space:]]*" c "[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", v)
      if (key == "base_url") { sub(/^"/, "", v); sub(/".*$/, "", v) }
      else if (match(v, /^.*\}/)) { v = substr(v, 1, RLENGTH) }
      print v; exit }' "$CFG"
}
provider_inventory() {  # 每行：provider名<TAB>生效中的 base_url<TAB>env_key（没有则为空）
  [ -f "$CFG" ] || return 0
  awk "$AWK_HDR"'
    /^[[:space:]]*\[/ { header($0); cur = pname; if (cur != "" && !(cur in seen)) { seen[cur] = 1; order[++n] = cur; url[cur] = ""; env[cur] = "" }; next }
    cur != "" && /^[[:space:]]*base_url[[:space:]]*=/ { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); url[cur] = v }
    cur != "" && /^[[:space:]]*env_key[[:space:]]*=/ { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); env[cur] = v }
    END { for (i = 1; i <= n; i++) print order[i] "\t" url[order[i]] "\t" env[order[i]] }' "$CFG"
}
history_providers() {  # 历史会话里出现过的 provider 名（数据库 + 会话文件首行）
  local db
  for db in "$CODEX_HOME"/state_*.sqlite; do
    [ -f "$db" ] || continue
    sqlite3 -readonly -cmd '.timeout 5000' "$db" "select distinct model_provider from threads where model_provider is not null and model_provider != ''" 2>/dev/null || true
  done
  find "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions" -name '*.jsonl' -type f -print0 2>/dev/null |
    xargs -0 awk 'FNR == 1 { if (match($0, /"model_provider":"[^"]*"/)) print substr($0, RSTART + 18, RLENGTH - 19); nextfile }' 2>/dev/null || true
}

load_conf() {
  BASE_URL="$(conf_get base_url)"; HEADERS="$(conf_get headers)"; PROVIDER="$(conf_get provider)"; LEGACY_KC="$(conf_get legacy_keychain_service)"
  if [ -z "$BASE_URL" ]; then  # 首次运行：从现有配置的默认 provider 推断（兼容旧版脚本写出的配置）
    local cur; cur="$(preamble_provider)"
    if [ -n "$cur" ] && [ "$cur" != openai ]; then
      BASE_URL="$(section_value "$cur" base_url)"
      if [ -n "$BASE_URL" ]; then
        HEADERS="$(section_value "$cur" http_headers)"; PROVIDER="${PROVIDER:-$cur}"
        conf_set base_url "$BASE_URL"; conf_set headers "$HEADERS"; conf_set provider "$PROVIDER"
        say "已从现有配置读取 API 地址 ${BASE_URL}，保存到 ${CONF}。"
      fi
    fi
  fi
}

# ---------- 规划 provider：哪些名字写成别名（MANAGED），哪些指向别的服务且自带密钥要保留（KEPT） ----------
plan_providers() {
  local names inv name url env
  names="$( { printf '%s\n' "$PROVIDER"; provider_inventory | cut -f1; preamble_provider; history_providers; } |
            grep -v '^$' | grep -v '^openai$' | grep -v '[\\"]' | awk '!seen[$0]++' || true)"
  inv="$(provider_inventory)"
  MANAGED=""; KEPT=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url="$(printf '%s\n' "$inv" | awk -F '\t' -v n="$name" '$1 == n { print $2; exit }')"
    env="$(printf '%s\n' "$inv" | awk -F '\t' -v n="$name" '$1 == n { print $3; exit }')"
    if [ -n "$url" ] && [ "${url%/}" != "${BASE_URL%/}" ] && [ -n "$env" ]; then KEPT="$KEPT$name"$'\n'; else MANAGED="$MANAGED$name"$'\n'; fi
  done <<< "$names"
}
choose_provider() {  # 默认 provider 名：沿用配置里已有的；否则按地址域名生成；不能和保留的 provider 重名
  local p="$PROVIDER"
  if [ -z "$p" ] || [ "$p" = openai ]; then p="$(preamble_provider)"; fi
  if [ -z "$p" ] || [ "$p" = openai ] || ! [[ "$p" =~ ^[A-Za-z0-9_-]+$ ]]; then
    p="$(url_host "$BASE_URL" | tr -c 'A-Za-z0-9_-' '_')"; p="${p:-codex_mode}"
  fi
  while printf '%s' "$KEPT" | grep -qx "$p"; do p="${p}_api"; done
  PROVIDER="$p"; conf_set provider "$PROVIDER"
}

# ---------- 写 config.toml ----------
provider_block() {  # provider_block 名字 api|chatgpt
  local name="$1" mode="$2" key="$1"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || key="\"$name\""
  printf '\n[model_providers.%s]\nname = "%s"\n' "$key" "$name"
  if [ "$mode" = api ]; then printf 'base_url = "%s"\n' "$BASE_URL"
  else printf '# base_url = "%s"   # 账号模式不写地址，走 OpenAI 官方后端\n' "$BASE_URL"; fi
  printf 'wire_api = "responses"\nrequires_openai_auth = true\nsupports_websockets = false\n'
  if [ -n "$HEADERS" ]; then
    if [ "$mode" = api ]; then printf 'http_headers = %s\n' "$HEADERS"
    else printf '# http_headers = %s   # 仅 API 模式启用\n' "$HEADERS"; fi
  fi
}
write_config() {  # write_config api|chatgpt
  local mode="$1" tmp name
  tmp="$(mktemp "$CODEX_HOME/.config.toml.XXXXXX")"
  {
    printf 'model_provider = "%s"   # 两种模式都保持这一行；切换只改下面 provider 块里的 base_url / http_headers\n' "$PROVIDER"
    if [ -f "$CFG" ]; then
      MANAGED="$MANAGED" awk "$AWK_HDR"'
        BEGIN { n = split(ENVIRON["MANAGED"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") m[a[i]] = 1 }
        /^[[:space:]]*\[/ { header($0); insec = 1; skip = (pname != "" && (pname in m)); if (!skip) print; next }
        skip { next }
        !insec && /^[[:space:]]*#?[[:space:]]*model_provider[[:space:]]*=/ { next }
        { print }' "$CFG"
    fi
    printf '%s' "$MANAGED" | while IFS= read -r name; do [ -n "$name" ] && provider_block "$name" "$mode"; done
  } | cat -s > "$tmp"
  cat "$tmp" > "$CFG"; rm -f "$tmp"
}
current_mode() { if [ -n "$(section_value "$(preamble_provider)" base_url active)" ]; then echo api; else echo chatgpt; fi; }
mode_word() { local p; p="$(preamble_provider)"; if [ -z "$p" ] || [ "$p" = openai ]; then echo none; else current_mode; fi; }
check_config() {  # 让 Codex 自己读一遍新配置
  local out
  [ -n "$CODEX" ] || return 0
  out="$("$CODEX" doctor 2>&1 | sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | tr '\r' '\n' || true)"
  if printf '%s\n' "$out" | grep -q '✗ config'; then printf '%s\n' "$out" | grep -E 'config|^[[:space:]]+·' | sort -u >&2; return 1; fi
}

# ---------- 备份、恢复、会话 ----------
backup_file() { mkdir -p "$BK$(dirname "$1")"; cp -p "$1" "$BK$1"; }
backup_db() {  # 用 sqlite 自己的 backup 拿一致快照（包含 WAL 里已提交的内容），副本改成无边车文件的模式
  mkdir -p "$BK$(dirname "$1")"
  sqlite3 -cmd '.timeout 5000' "$1" ".backup '$BK$1'"
  sqlite3 "$BK$1" "pragma journal_mode=delete" >/dev/null
}
restore_backup() {
  [ -d "$BK" ] || return 0
  ( cd "$BK" && find . -type f | while IFS= read -r rel; do
      abs="${rel#.}"
      case "$abs" in
        *.sqlite-wal|*.sqlite-shm|*.sqlite-journal) ;;
        *.sqlite) sqlite3 -cmd '.timeout 5000' "$abs" ".restore '$BK$abs'" ;;
        *) cp -p "$BK$abs" "$abs" ;;
      esac
    done )
  say "已把配置和会话恢复到切换前的状态。"
}
fix_threads() {  # 把记成 openai 的会话改记为 ${PROVIDER}，只改文件第一行的 session_meta；改前备份
  local files f db n=0 changed
  files="$(find "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions" -name '*.jsonl' -type f -print0 2>/dev/null |
    xargs -0 awk 'FNR == 1 { if (/"type":"session_meta"/ && /"model_provider":"openai"/) print FILENAME; nextfile }' 2>/dev/null || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    backup_file "$f"
    sed -i '' '1 s/"model_provider":"openai"/"model_provider":"'"$PROVIDER"'"/' "$f"
    n=$((n + 1))
  done <<< "$files"
  for db in "$CODEX_HOME"/state_*.sqlite; do
    [ -f "$db" ] || continue
    backup_db "$db"
    changed="$(sqlite3 -cmd '.timeout 5000' "$db" "update threads set model_provider='$PROVIDER' where model_provider='openai'; select changes();")"
    n=$((n + changed))
  done
  if [ "$n" -gt 0 ]; then say "已把 $n 处账号时期的会话记录改记为 ${PROVIDER}（改前有备份）。"; else say "会话 provider 已统一，无需处理。"; fi
}

# ---------- 应用进程 ----------
app_running() { pgrep -x "$APP_NAME" >/dev/null 2>&1; }
quit_app() {
  [ "${CODEX_MODE_FORCE:-}" = 1 ] && return 0
  if app_running; then
    say "正在退出 ${APP_NAME}…"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do app_running || break; sleep 1; done
    if app_running; then die "$APP_NAME 没有退出，请手动 ⌘Q 后重试。"; fi
    sleep 1
  fi
  if pgrep -x codex >/dev/null 2>&1 || pgrep -x codex-app-server >/dev/null 2>&1; then
    die "还有 codex 命令行或 IDE 会话在运行，请先关闭它们再切换，避免同时写会话记录。"
  fi
}
reopen_app() { if [ "${CODEX_MODE_NO_REOPEN:-}" != 1 ]; then open -a "$APP_NAME" >/dev/null 2>&1 || say "请手动打开 ${APP_NAME}。"; fi; }
auth_mode() {
  local out; out="$("$CODEX" login status 2>&1 || true)"
  case "$out" in *ChatGPT*|*chatgpt*) echo chatgpt ;; *"API key"*|*"api key"*|*api_key*) echo api_key ;; *) echo "" ;; esac
}
AUTH_FILE="$CODEX_HOME/auth.json"
AUTH_STASH="$CODEX_HOME/codex-mode-auth/chatgpt.json"
stash_chatgpt_auth() {  # 当前是 ChatGPT 登录态（凭据存在文件里）就存一份最新的
  if [ "$(auth_mode)" = chatgpt ] && grep -q '"refresh_token"' "$AUTH_FILE" 2>/dev/null; then
    mkdir -p "$(dirname "$AUTH_STASH")"; chmod 700 "$(dirname "$AUTH_STASH")"
    cp -p "$AUTH_FILE" "$AUTH_STASH"; chmod 600 "$AUTH_STASH"
  fi
}
restore_chatgpt_auth() {  # 有存档就恢复并确认 Codex 认它；成功返回 0
  [ -f "$AUTH_STASH" ] || return 1
  cp -p "$AUTH_STASH" "$AUTH_FILE"; chmod 600 "$AUTH_FILE"
  [ "$(auth_mode)" = chatgpt ]
}
need_codex() { [ -n "$CODEX" ] && [ -x "$CODEX" ] || die "找不到 Codex 命令行（应用里自带的 codex 或 PATH 里的 codex）：${CODEX:-未找到}，可用 CODEX_BIN 指定。"; }

# ---------- 一次切换的公共部分：备份 → 规划 → 写配置 → 统一会话 → 校验 ----------
prepare_switch() {  # prepare_switch api|chatgpt
  mkdir -p "$BK"
  [ -f "$CFG" ] && backup_file "$CFG"
  [ -f "$AUTH_FILE" ] && backup_file "$AUTH_FILE"   # 登录态也备份，回滚时一起恢复
  stash_chatgpt_auth
  plan_providers; choose_provider; plan_providers
  write_config "$1"
  fix_threads
  if ! check_config; then restore_backup; die "新配置没有通过 Codex 校验，已恢复。备份在 ${BK}，请把上面的错误发给管理员。"; fi
  say "切换前的备份：$BK"
}
current_api_key() {  # Codex 当前用 API key 登录时，取这个正在用的 key（它对当前地址是有效的）
  [ "$(auth_mode)" = api_key ] || return 0
  sed -n 's/.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CODEX_HOME/auth.json" 2>/dev/null | head -n1
}
get_key() {  # 优先级：钥匙串里这个地址的 key → 当前正在用的 key → 旧版脚本的钥匙串条目 → 手动输入
  local svc key; svc="$(kc_service "$BASE_URL")"
  key="$(kc_get "$svc")"
  if [ -z "$key" ]; then
    key="$(current_api_key)"
    if [ -n "$key" ]; then kc_set "$svc" "$key"; say "已把当前正在使用的 API key 保存到钥匙串条目 ${svc}。"; fi
  fi
  if [ -z "$key" ] && [ -n "$LEGACY_KC" ]; then
    key="$(security find-generic-password -s "$LEGACY_KC" -w 2>/dev/null || true)"
    if [ -n "$key" ]; then kc_set "$svc" "$key"; say "已把旧版脚本保存的 key 迁移到钥匙串条目 ${svc}；若登录后提示 key 无效，请用 codex-mode set-key 换成正确的 key。"; fi
  fi
  if [ -z "$key" ]; then
    key="$(ask_secret "请输入 $(url_host "$BASE_URL") 的 API key")" || exit 1
    [ -n "$key" ] || die "未输入 key，已取消。"
    case "$(ask '是否存入钥匙串，以后切换不用再输？(Y/n)' Y)" in n|N) ;; *) kc_set "$svc" "$key"; say "已存入钥匙串。" ;; esac
  fi
  printf '%s' "$key"
}

# ---------- 各命令 ----------
mode_api() {
  need_codex; load_conf
  if [ -z "$BASE_URL" ]; then say "还没有配置 API 地址，先配置一次："; do_configure; fi
  local key; key="$(get_key)" || exit 1
  quit_app
  prepare_switch api
  if ! printf '%s' "$key" | "$CODEX" login --with-api-key >/dev/null; then
    restore_backup; die "用 API key 登录失败，已恢复到切换前。请检查 key（codex-mode set-key）后重试。"
  fi
  reopen_app
  say "已切到 API 模式（${BASE_URL}），$APP_NAME 已重新打开。"
}
mode_chatgpt() {
  need_codex; load_conf
  quit_app
  prepare_switch chatgpt
  if [ "$(auth_mode)" = chatgpt ]; then
    reopen_app
    say "已切到账号模式，$APP_NAME 已重新打开（账号仍在登录状态）。"
  elif restore_chatgpt_auth; then
    reopen_app
    say "已切到账号模式并恢复了之前的 ChatGPT 登录态，$APP_NAME 已重新打开。"
  else
    "$CODEX" logout >/dev/null 2>&1 || true
    reopen_app
    say "已切到账号模式，$APP_NAME 已重新打开，请在应用里用 ChatGPT 账号登录。"
  fi
}
mode_fix() { need_codex; load_conf; quit_app; prepare_switch "$(current_mode)"; reopen_app; }
mode_status() {
  load_conf
  local p login n=0 db active; p="$(preamble_provider)"
  active="$(section_value "$p" base_url active)"
  if [ -z "$p" ] || [ "$p" = openai ]; then
    echo "模式：尚未切换过"
    echo "API 地址：${BASE_URL:-未配置}"
  elif [ -n "$active" ]; then
    echo "模式：API"
    echo "请求发往：${active}"
    if [ -n "$BASE_URL" ] && [ "${BASE_URL%/}" != "${active%/}" ]; then echo "新地址尚未生效：${BASE_URL}（重新切换到 API 后生效）"; fi
  else
    echo "模式：ChatGPT 账号"
    echo "API 地址（切换后使用）：${BASE_URL:-未配置}"
  fi
  if [ -n "$CODEX" ]; then
    login="$(auth_mode)"; echo "登录：${login:-未登录}" | sed 's/api_key/API key/; s/chatgpt/ChatGPT 账号/'
  fi
  if [ -n "$BASE_URL" ]; then
    if [ -n "$(kc_get "$(kc_service "$BASE_URL")")" ]; then echo "钥匙串：已保存 key"; else echo "钥匙串：未保存 key（切 API 模式时会提示输入）"; fi
  fi
  for db in "$CODEX_HOME"/state_*.sqlite; do
    [ -f "$db" ] || continue
    n=$((n + $(sqlite3 -readonly -cmd '.timeout 5000' "$db" "select count(*) from threads where model_provider='openai'" 2>/dev/null || echo 0)))
  done
  [ "$n" -gt 0 ] && echo "待统一的会话：$n 条记成 openai，下次切换时会处理"
  return 0
}
do_configure() {
  load_conf
  local url hdr key
  if [ -n "${CODEX_MODE_BASE_URL:-}${CODEX_MODE_HEADERS:-}${CODEX_MODE_KEY_STDIN:-}" ]; then  # 非交互（图形界面）
    url="${CODEX_MODE_BASE_URL:-$BASE_URL}"; hdr="${CODEX_MODE_HEADERS-$(toml_to_pairs "$HEADERS")}"
    key=""; if [ "${CODEX_MODE_KEY_STDIN:-}" = 1 ]; then IFS= read -r key || true; fi
  else
    url="$(ask '请输入 API Base URL（服务商给的完整地址，例如 https://api.example.com/v1）' "$BASE_URL")" || exit 1
    hdr="$(ask '额外请求头（格式 名称=值，多个用英文逗号分隔；通常留空，输入 - 表示清空）' "$(toml_to_pairs "$HEADERS")")" || exit 1
    [ "$hdr" = - ] && hdr=""
  fi
  url="${url%/}"; valid_url "$url" || die "地址格式不对：${url}（需要以 http:// 或 https:// 开头的完整地址）"
  HEADERS="$(pairs_to_toml "$hdr")"; BASE_URL="$url"
  conf_set base_url "$BASE_URL"; conf_set headers "$HEADERS"
  say "已保存到 ${CONF}。"
  if [ -z "${CODEX_MODE_BASE_URL:-}${CODEX_MODE_HEADERS:-}${CODEX_MODE_KEY_STDIN:-}" ]; then
    if [ -n "$(kc_get "$(kc_service "$BASE_URL")")" ]; then
      key="$(ask_secret "API key（钥匙串里已有一个，回车沿用）")" || exit 1
    else
      key="$(ask_secret "API key（回车跳过，切 API 模式时再输）")" || exit 1
    fi
  fi
  if [ -n "$key" ]; then kc_set "$(kc_service "$BASE_URL")" "$key"; say "key 已存入钥匙串。"; fi
}
show_config() { load_conf >/dev/null 2>&1; echo "base_url=$BASE_URL"; echo "headers=$(toml_to_pairs "$HEADERS")"; }
set_key() {
  load_conf; [ -n "$BASE_URL" ] || die "请先运行 codex-mode configure。"
  local key; key="$(ask_secret "请输入 $(url_host "$BASE_URL") 的 API key")" || exit 1
  [ -n "$key" ] || die "未输入 key。"
  kc_set "$(kc_service "$BASE_URL")" "$key"; say "已存入钥匙串。"
}
forget_key() {
  load_conf; [ -n "$BASE_URL" ] || die "请先运行 codex-mode configure。"
  if kc_del "$(kc_service "$BASE_URL")"; then say "已从钥匙串删除。"; else say "钥匙串里没有保存的 key。"; fi
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
mkdir -p "$CODEX_HOME"
case "$1" in
  api) mode_api ;;
  chatgpt) mode_chatgpt ;;
  status) mode_status ;;
  configure) do_configure ;;
  set-key) set_key ;;
  forget-key) forget_key ;;
  fix-threads) mode_fix ;;
  mode) mode_word ;;
  version) echo "$CODEX_MODE_VERSION" ;;
  config) show_config ;;
  has-key) [ -n "${2:-}" ] && valid_url "$2" || die "用法：codex-mode has-key URL"; [ -n "$(kc_get "$(kc_service "$2")")" ] ;;
  *) usage ;;
esac
