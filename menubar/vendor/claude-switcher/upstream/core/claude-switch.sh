#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A|B | checkdetail | fix | set-region | update [--auto] | diagnose-proxy
set -u
export LC_ALL=en_US.UTF-8

# 随现有单脚本更新分发;在任何账号状态读写、审计/修复/启动之前分派。
if [ "${1:-}" = "diagnose-proxy" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_PROXY_DIAGNOSE'
"""Read-only transport diagnostics for an explicitly selected HTTP/SOCKS proxy."""
import argparse
import concurrent.futures
import ipaddress
import json
import math
import os
import subprocess
from urllib.parse import urlsplit


TARGETS = (
    ("anthropic_api", "https://api.anthropic.com/v1/models"),
    ("claude_web", "https://claude.ai/"),
)


def select_proxy(args, environ):
    if args.proxy is not None:
        value, source = args.proxy, "argument"
    elif args.config is not None:
        with open(args.config, encoding="utf-8") as handle:
            config = json.load(handle)
        if not isinstance(config, dict):
            raise ValueError("invalid config")
        value, source = config.get("proxy_url"), "config"
    else:
        value, source = environ.get("CLAUDE_SWITCHER_PROXY_URL"), "environment"
    if not isinstance(value, str) or not value.strip():
        raise ValueError("proxy required")
    value = value.strip()
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid proxy")
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https", "socks5", "socks5h")
            or not parsed.hostname or parsed.port is None
            or not 0 < parsed.port < 65536
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("invalid proxy")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    # Do not include proxy addresses, credentials, or private config paths in reports.
    public = {"scheme": parsed.scheme, "port": parsed.port,
              "host_scope": "loopback" if loopback else "remote",
              "authentication_configured": parsed.username is not None,
              "source": source}
    return value, public


def probe(name, url, proxy, environ):
    # -q ignores curlrc. Pass proxy credentials over stdin, never in argv/reports.
    quoted = proxy.replace("\\", "\\\\").replace('"', '\\"')
    config = 'proxy = "' + quoted + '"\n'
    args = ["curl", "-q", "--config", "-", "-sS", "-o", os.devnull,
            "--proto", "=https", "--noproxy", "", "--connect-timeout", "6",
            "--max-time", "12", "-w",
            "%{http_code}\t%{http_connect}\t%{ssl_verify_result}\t%{time_appconnect}\t%{time_total}",
            url]
    keep = {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "SYSTEMROOT"}
    clean_env = {k: v for k, v in environ.items() if k in keep}
    result = {"name": name, "url": url, "transport_reached": False,
              "access": "unknown"}
    try:
        process = subprocess.run(args, input=config, env=clean_env, capture_output=True,
                                 text=True, timeout=15)
        fields = process.stdout.strip().split()
        status, connect, verify = map(int, fields[:3])
        tls, elapsed = map(float, fields[3:5])
        if (not 0 <= status <= 599 or not 0 <= connect <= 599 or verify < 0
                or not math.isfinite(tls) or not math.isfinite(elapsed)
                or tls < 0 or elapsed < 0):
            raise ValueError("invalid probe metrics")
        reached = process.returncode == 0 and status > 0 and verify == 0 and tls > 0
        access = ("unauthenticated" if status == 401 else
                  "access_restricted" if status in (403, 407) else
                  "server_error" if status >= 500 else "http_response")
        result.update(curl_exit=process.returncode, http_status=status,
                      proxy_connect_status=connect, tls_verified=reached,
                      elapsed_seconds=elapsed, transport_reached=reached,
                      access=access if reached else "unknown")
    except subprocess.TimeoutExpired:
        result["error"] = "probe_timeout"
    except OSError:
        result["error"] = "curl_unavailable"
    except (ValueError, IndexError):
        result["error"] = "invalid_probe_output"
    return result


class DiagnosticParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default error can echo private URLs or paths from argv.
        raise ValueError("invalid arguments")


def main(argv=None, environ=None):
    parser = DiagnosticParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--proxy", help="explicit proxy URL including a port")
    choice.add_argument("--config", help="private JSON file containing proxy_url")
    environ = os.environ if environ is None else environ
    report = {"schema_version": 1, "mode": "proxy_diagnostics",
              "scope": "unauthenticated_transport_only",
              "account_status": "not_evaluated", "leak_protection": "not_evaluated",
              "launch_allowed": None, "application_started": False,
              "system_modified": False}
    try:
        args = parser.parse_args(argv)
        proxy, public = select_proxy(args, environ)
    except (OSError, ValueError, TypeError):
        report.update(state="configuration_error", error="invalid_or_missing_proxy",
                      hint="Use --proxy, --config, or CLAUDE_SWITCHER_PROXY_URL; an explicit port is required.")
        print(json.dumps(report, ensure_ascii=False))
        return 2
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(probe, name, url, proxy, environ) for name, url in TARGETS]
        checks = [f.result() for f in futures]
    reached = all(check["transport_reached"] for check in checks)
    report.update(proxy=public, checks=checks,
                  state="transport_reached" if reached else "transport_failed")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if reached else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY_PROXY_DIAGNOSE
fi

# ============ 安装时可配置项(安装程序会自动改写) ============
PROXY_MODE="clash-verge"       # 代理客户端: clash-verge|shadowrocket|sing-box|clashx|surge|auto
PROXY_GROUP="IpEqual"          # Clash 代理组名(安装时自动探测)
COUNTRY_TARGET="US"            # 目标出口国家(安装时按出口自动识别)
TZ_TARGET="America/New_York"   # 锁定时区,应与出口IP所在城市一致
LOCALE_TARGET="en_US"          # 锁定地区格式
# ============================================================

DATA="$HOME/Library/Application Support/Claude"
BASE="$HOME/.claude-switcher"
LOG="$HOME/Library/Logs/claude-switch.log"
CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
ROUTE_MISSED=""
mkdir -p "$BASE/accounts"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管(兼容各种 TUN 设备名)
tun_up() { ifconfig 2>/dev/null | grep -q 'inet 198\.18\.'; }

# 代理客户端显示名(供检查细节输出)
proxy_name() {
    case "$PROXY_MODE" in
        clash-verge)  echo "Clash Verge" ;;
        shadowrocket) echo "Shadowrocket" ;;
        sing-box)     echo "sing-box" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        auto)         echo "代理客户端" ;;
        *)            echo "$PROXY_MODE" ;;
    esac
}

# 可 open -a 启动的客户端 App 名(sing-box/auto 无标准 App,返回空)
proxy_app_name() {
    case "$PROXY_MODE" in
        clash-verge)  echo "Clash Verge" ;;
        shadowrocket) echo "Shadowrocket" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        *)            echo "" ;;
    esac
}

# Shadowrocket 在 Mac 上表现为 VPN 配置;launchd/非图形环境下 scutil 可能查不到该行,此时以 TUN 判定为准(避免误杀)
shadowrocket_up() {
    nc=$(scutil --nc list 2>/dev/null)
    if echo "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
        echo "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)'
    else
        tun_up
    fi
}

# 代理内核在线判定:按安装时识别的客户端分派;auto 时任一命中即活
proxy_alive() {
    case "$PROXY_MODE" in
        clash-verge)  pgrep -f verge-mihomo >/dev/null 2>&1 ;;
        shadowrocket) shadowrocket_up ;;
        sing-box)     pgrep -f sing-box >/dev/null 2>&1 ;;
        clashx)       pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1 ;;
        surge)        pgrep -f Surge >/dev/null 2>&1 ;;
        auto)         pgrep -f verge-mihomo >/dev/null 2>&1 || shadowrocket_up \
                      || pgrep -f sing-box >/dev/null 2>&1 \
                      || pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1 \
                      || pgrep -f Surge >/dev/null 2>&1 ;;
        *)            pgrep -f verge-mihomo >/dev/null 2>&1 ;;
    esac
}

# 置顶规则配置检查(仅 Clash Verge):合并配置里是否含置顶规则
merge_ok() {
    grep -q "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" "$CLASH_DIR/clash-verge.yaml" 2>/dev/null
}

# 置顶规则行为检测:三个生态域名全部解析到 fake-ip 段(198.18.x.x)即视为已置顶;未命中域名记入 ROUTE_MISSED
route_ok() {
    ROUTE_MISSED=""
    local d a
    for d in claude.ai api.anthropic.com claudeusercontent.com; do
        a=$(dig +short +time=3 +tries=1 "$d" 2>/dev/null | head -1)
        case "$a" in
            198.18.*) ;;
            *) ROUTE_MISSED="$ROUTE_MISSED $d" ;;
        esac
    done
    [ -z "$ROUTE_MISSED" ]
}

# 国家代码 → 地区格式映射(未收录的国家回退 en_US)
locale_for() {
    case "$1" in
        US) echo en_US ;; JP) echo ja_JP ;; TW) echo zh_TW ;; HK) echo zh_HK ;;
        SG) echo en_SG ;; GB) echo en_GB ;; DE) echo de_DE ;; FR) echo fr_FR ;;
        KR) echo ko_KR ;; AU) echo en_AU ;; CA) echo en_CA ;; *) echo en_US ;;
    esac
}

# IP 审查:记录出口IP并统计最近48h内不同IP个数(账号画像风险指标)
iphist_count() {
    [ -z "$1" ] && { echo 0; return; }
    local HIST="$BASE/iphistory.log"
    local now=$(date +%s)
    echo "$1 $now" >>"$HIST"
    # 裁掉48小时(172800秒)以前的记录
    awk -v cutoff=$((now-172800)) '$2>=cutoff' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    # 统计48h内不同IP个数
    awk '{print $1}' "$HIST" | sort -u | wc -l | tr -d ' '
}

# ---------- 安全检查 ----------
check() {
    fails=""

    proxy_alive || fails="$fails;代理内核未运行"
    tun_up || fails="$fails;TUN网卡不在线"

    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    [ "$loc" = "$COUNTRY_TARGET" ] || fails="$fails;出口IP异常(${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET)"
    ipwarn=""
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -n "$ip" ] && [ -n "$lastip" ] && [ "$ip" != "$lastip" ]; then
        ipwarn="注意:出口IP与上次不同($lastip -> $ip)"
    fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"

    # IP 审查:48h 内出口 IP 变化 ≥3 次追加警告(只 warn 不 fail)
    ipn=$(iphist_count "$ip")
    if [ "$ipn" -ge 3 ] 2>/dev/null; then
        ipwarn="${ipwarn:+$ipwarn; }注意:48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
    fi

    tz=$(readlink /etc/localtime 2>/dev/null)
    [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ] || fails="$fails;时区异常($tz)"

    locale=$(defaults read -g AppleLocale 2>/dev/null)
    [ "$locale" = "$LOCALE_TARGET" ] || fails="$fails;地区异常($locale)"

    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    echo "$v6" | grep -qi 'off' || fails="$fails;IPv6未关闭"

    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) ;;
        *) fails="$fails;DNS未走隧道(返回${dnsip:-空})" ;;
    esac

    wr=$(webrtc_test)
    if [ "$wr" != "RESULT:NONE" ]; then
        case "$wr" in
            RESULT:*)
                wips=${wr#RESULT:}
                leak=""
                OLDIFS=$IFS; IFS=','
                for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
                IFS=$OLDIFS
                [ -n "$leak" ] && fails="$fails;WebRTC泄漏($leak)" ;;
            *) fails="$fails;WebRTC检测异常" ;;
        esac
    fi

    launchctl print system/local.claude-bodyguard >/dev/null 2>&1 || fails="$fails;保镖未运行"

    # 置顶规则:Clash Verge 看配置或行为任一通过;其他客户端只看行为检测
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        merge_ok || route_ok || fails="$fails;置顶规则缺失"
    else
        route_ok || fails="$fails;置顶规则缺失(未命中:${ROUTE_MISSED# })"
    fi

    defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' || {
        syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
        [[ "$syslang" == en* ]] || fails="$fails;客户端语言为中文"
    }

    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    { [ "$r1" = "000" ] || [ "$r2" = "000" ]; } && fails="$fails;Anthropic生态不可达($r1/$r2)"

    if [ -n "$fails" ]; then
        echo "FAIL:${fails#;}"
        return 1
    fi
    echo "OK:$ip${ipwarn:+|$ipwarn}"
    return 0
}

# WebRTC/STUN 探测:返回 RESULT:ip,ip 或 RESULT:NONE 或空
webrtc_test() {
    python3 "$BASE/stun-probe.py" 2>/dev/null
}

# 逐项输出检查结果(供UI使用): 名称=ok|fail:细节
checkdetail() {
    if proxy_alive; then
        case "$PROXY_MODE" in
            shadowrocket) echo '代理内核=ok:Shadowrocket 已连接' ;;
            *) echo "代理内核=ok:$(proxy_name) 运行中" ;;
        esac
    else
        echo "代理内核=fail:$(proxy_name) 未运行"
    fi
    if tun_up; then echo 'TUN网卡=ok'; else echo 'TUN网卡=fail:不在线'; fi
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then echo "出口IP=ok:$ip/$loc"; else echo "出口IP=fail:${ip:-无}/${loc:-未知}(期望$COUNTRY_TARGET)"; fi
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    ipst=""; ipdt=""
    if [ -z "$ip" ]; then echo 'IP一致=fail:未获取到出口IP'
    elif [ -z "$lastip" ]; then ipst="ok"; ipdt="首次记录"
    elif [ "$ip" = "$lastip" ]; then ipst="ok"
    else ipst="warn"; ipdt="$lastip → $ip"; fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"
    # IP 审查:48h 内出口 IP 变化 ≥3 次提示账号画像风险(只 warn 不 fail)
    if [ -n "$ipst" ]; then
        ipn=$(iphist_count "$ip")
        if [ "$ipn" -ge 3 ] 2>/dev/null; then
            if [ "$ipst" = "ok" ]; then
                ipst="warn"; ipdt="48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
            else
                ipdt="$ipdt;48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
            fi
        fi
        if [ -z "$ipdt" ]; then echo "IP一致=$ipst"; else echo "IP一致=$ipst:$ipdt"; fi
    fi
    tz=$(readlink /etc/localtime 2>/dev/null)
    if [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ]; then echo '时区=ok'; else echo "时区=fail:$tz"; fi
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" = "$LOCALE_TARGET" ]; then echo '地区=ok'; else echo "地区=fail:$locale"; fi
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    if echo "$v6" | grep -qi 'off'; then echo 'IPv6=ok:已关闭'; else echo 'IPv6=fail:未关闭'; fi
    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) echo 'DNS=ok:走隧道' ;;
        *) echo "DNS=fail:未走隧道(${dnsip:-空})" ;;
    esac
    wr=$(webrtc_test)
    case "$wr" in
        RESULT:NONE) echo 'WebRTC=ok:UDP不出网,零暴露' ;;
        RESULT:*)
            wips=${wr#RESULT:}
            leak=""
            OLDIFS=$IFS; IFS=','
            for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
            IFS=$OLDIFS
            if [ -n "$leak" ]; then echo "WebRTC=fail:暴露非代理IP:$leak"; else echo 'WebRTC=ok:仅暴露代理IP'; fi ;;
        *) echo 'WebRTC=fail:检测异常' ;;
    esac
    if launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        lastkill=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null | cut -c1-40)
        echo "保镖=ok:${lastkill:-待命}"
    else
        echo '保镖=fail:未安装'
    fi
    # 置顶规则:Clash Verge 配置/行为双保险,其他客户端只看行为
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if merge_ok; then
            echo '规则置顶=ok'
        elif route_ok; then
            echo '规则置顶=ok:行为检测通过'
        else
            echo '规则置顶=fail:未生效'
        fi
    else
        if route_ok; then
            echo '规则置顶=ok:行为检测通过'
        else
            echo "规则置顶=fail:未命中(${ROUTE_MISSED# }),请在 $(proxy_name) 中自行加置顶规则"
        fi
    fi
    # 12. Claude 客户端语言(单独设为英文,或系统首选语言为英文均可;防止 JS 层读出中文)
    clang=$(defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | head -2)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if echo "$clang" | grep -q 'en-US'; then
        echo '客户端语言=ok:en-US'
    elif [[ "$syslang" == en* ]]; then
        echo '客户端语言=ok:跟随系统(英文)'
    else
        echo '客户端语言=fail:跟随系统(中文)'
    fi
    # 13. ASN 网络属性(住宅宽带 vs 机房,按目标地区收录主流运营商)
    org=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    case "$org" in
        '') echo 'ASN属性=warn:未获取' ;;
        *Comcast*|*AT\&T*|*Verizon*|*Spectrum*|*Charter*|*Cox*|*T-Mobile*|*Cable*|*esidential*|\
        *NTT*|*KDDI*|*SoftBank*|*IIJ*|*OCN*|*So-net*|\
        *HiNet*|*Chunghwa*|*CHT*|*kbro*|*Taiwan*|*FarEasTone*|*Data\ Communication*|\
        *Singtel*|*StarHub*|*M1*|\
        *HKT*|*PCCW*|*HKBN*|*HGC*|\
        *BT*|*Sky*|*Virgin*|*TalkTalk*|*Vodafone*|\
        *Deutsche\ Telekom*|*1\&1*|*O2*) echo "ASN属性=ok:$org" ;;
        *) echo "ASN属性=warn:疑似机房($org)" ;;
    esac
    # 14. Anthropic 生态可达性
    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    if [ "$r1" != "000" ] && [ "$r2" != "000" ]; then
        echo "生态可达性=ok:claude.ai:$r1 api:$r2"
    else
        echo "生态可达性=fail:claude.ai:$r1 api:$r2"
    fi
}

# 置顶规则写入(智能合并):不整文件覆盖,用户已有的 Merge 配置原样保留
# 标记块自包含 prepend-rules 键+全部规则,重复执行幂等
write_merge_rules() {
    M="$CLASH_DIR/profiles/Merge.yaml"
    B0="# >>> claude-switcher pinned rules >>>"
    B1="# <<< claude-switcher pinned rules <<<"
    mkdir -p "$CLASH_DIR/profiles"
    # 置顶规则清单(缩进两格)
    rules=""
    for d in claude.ai claude.com anthropic.com claudeusercontent.com challenges.cloudflare.com datadoghq.com segment.io stripe.com stripe.network stripecdn.com intercom.io intercomcdn.com intercomassets.com; do
        rules="$rules  - DOMAIN-SUFFIX,$d,$PROXY_GROUP
"
    done

    # 首次:文件不存在,整文件写入
    if [ ! -f "$M" ]; then
        cat > "$M" <<MEOF
# Profile Enhancement Merge Template for Clash Verge

profile:
  store-selected: true

# Claude 全家族及生态域名置顶强制走代理(优先级高于任何国内规则集)
$B0
prepend-rules:
$rules$B1
MEOF
        return 0
    fi

    # 已存在:备份后幂等替换(只在将要修改时备份)
    cp "$M" "$M.bak.$(date +%Y%m%d%H%M%S)"
    tmp="$M.cs.tmp"
    cp "$M" "$tmp"
    # 删除旧标记块(含标记行,兼容块在 prepend-rules 下缩进的情形)
    if grep -qF "$B0" "$tmp"; then
        awk -v b0="$B0" -v b1="$B1" '
            index($0, b0) {inblock=1; next}
            inblock && index($0, b1) {inblock=0; next}
            !inblock
        ' "$tmp" > "$tmp.out" && mv "$tmp.out" "$tmp"
        # 清理孤立的 prepend-rules: 键(其后没有规则行,只剩空行/注释/EOF)
        awk '
            { L[NR]=$0 }
            END {
                for (i=1; i<=NR; i++) {
                    if (L[i] ~ /^prepend-rules:/) {
                        has=0
                        for (j=i+1; j<=NR; j++) {
                            if (L[j] ~ /^[ \t]*- /) { has=1; break }
                            if (L[j] ~ /^[ \t]*$/ || L[j] ~ /^[ \t]*#/) continue
                            break
                        }
                        if (!has) continue
                    }
                    print L[i]
                }
            }
        ' "$tmp" > "$tmp.out" && mv "$tmp.out" "$tmp"
    fi
    # 注入:已有 prepend-rules: 则标记规则块(不带键)插到该行之后,否则文件顶部插入完整块
    # 注意:多行文本走环境变量传递(macOS awk 的 -v 不支持含换行的字符串);先写中间文件再替换,失败不碰原文件
    if grep -q '^prepend-rules:' "$tmp"; then
        if MARK0="$B0" MARK1="$B1" RULES="$rules" awk '
            /^prepend-rules:/ && !done {
                print
                print "  " ENVIRON["MARK0"]
                printf "%s", ENVIRON["RULES"]
                print "  " ENVIRON["MARK1"]
                done=1
                next
            }
            { print }
        ' "$tmp" > "$tmp.out"; then
            mv "$tmp.out" "$M" && rm -f "$tmp"
        else
            rm -f "$tmp" "$tmp.out"
            return 1
        fi
    else
        {
            echo "# Claude 全家族及生态域名置顶强制走代理(优先级高于任何国内规则集)"
            echo "$B0"
            echo "prepend-rules:"
            printf "%s" "$rules"
            echo "$B1"
            echo ""
            cat "$tmp"
        } > "$tmp.out" && mv "$tmp.out" "$M" && rm -f "$tmp"
    fi
    rm -f "$tmp"
}

# 一键修复:按项自动修复,每步输出结果
fix() {
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if ! pgrep -f verge-mihomo >/dev/null 2>&1; then
            echo "FIX:正在启动 Clash Verge..."
            open -a "Clash Verge"
        fi
        for i in $(seq 1 40); do
            pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up && break
            sleep 1
        done
        if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            V="$CLASH_DIR/verge.yaml"
            if [ -f "$V" ] && grep -q '^enable_tun_mode: false' "$V"; then
                echo "FIX:检测到 TUN 开关被关闭,正在恢复..."
                osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
                sleep 3
                sed -i '' 's/^enable_tun_mode: false/enable_tun_mode: true/' "$V"
                open -a "Clash Verge"
                for i in $(seq 1 40); do
                    tun_up && break
                    sleep 1
                done
            fi
            if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
                echo "FIX:代理内核+TUN ✓(已恢复TUN开关)"
            else
                echo "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)"
            fi
        fi
    else
        app=$(proxy_app_name)
        if ! proxy_alive && [ -n "$app" ]; then
            echo "FIX:正在启动 $app..."
            open -a "$app" >/dev/null 2>&1
        fi
        for i in $(seq 1 40); do
            proxy_alive && tun_up && break
            sleep 1
        done
        if proxy_alive && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            echo "FIX:代理内核/TUN ✗(请打开 $(proxy_name) 手动检查节点/线路及TUN模式)"
        fi
    fi

    # B. 时区/IPv6/DNS缓存/保镖(需管理员权限,会弹一次密码框)
    tz=$(readlink /etc/localtime 2>/dev/null)
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    adminCmds=""
    [ "$tz" != "/var/db/timezone/zoneinfo/$TZ_TARGET" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $TZ_TARGET; "
    echo "$v6" | grep -qi 'off' || adminCmds="${adminCmds}networksetup -setv6off Wi-Fi; "
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        adminCmds="${adminCmds}cp $HOME/.local/bin/local.claude-bodyguard.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist && launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist; "
    fi
    if [ -n "$adminCmds" ]; then
        adminCmds="${adminCmds}dscacheutil -flushcache; killall -HUP mDNSResponder"
        echo "FIX:修复时区/IPv6/DNS/保镖(需要密码)..."
        if osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "一键修复需要管理员权限" with administrator privileges
ASEOF
        then
            echo "FIX:时区/IPv6/DNS/保镖 ✓"
        else
            echo "FIX:时区/IPv6/保镖 ✗(取消或失败)"
        fi
    else
        echo "FIX:时区/IPv6/保镖 无需修复 ✓"
    fi

    # B3. Claude 客户端单独设英文(用户级,无需密码;系统首选语言已是英文则跳过)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if ! defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' && [[ "$syslang" != en* ]]; then
        defaults write com.anthropic.claudefordesktop AppleLanguages -array en-US
        echo "FIX:Claude 客户端语言 → en-US ✓(重启 Claude 后生效)"
    fi

    # B4. 地区格式(用户级,无需密码)
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" != "$LOCALE_TARGET" ]; then
        defaults write -g AppleLocale "$LOCALE_TARGET"
        echo "FIX:地区格式 → $LOCALE_TARGET ✓"
    fi

    # B2. 置顶规则缺失 → Clash Verge 智能合并写入 Merge 配置并重启;其他客户端提示自行配置
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if ! merge_ok && ! route_ok; then
            echo "FIX:写入置顶规则(智能合并,不动你的已有配置)..."
            write_merge_rules
            osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
            sleep 3
            open -a "Clash Verge"
            for i in $(seq 1 40); do
                tun_up && break
                sleep 1
            done
            grep -q "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" "$CLASH_DIR/clash-verge.yaml" 2>/dev/null \
                && echo "FIX:置顶规则 ✓" || echo "FIX:置顶规则 ✗"
        fi
    else
        if ! route_ok; then
            echo "FIX:置顶规则 ✗(未命中:${ROUTE_MISSED# }) — 请在 $(proxy_name) 中自行添加 DOMAIN-SUFFIX 置顶规则"
        fi
    fi

    # C. 出口IP最终验证
    sleep 2
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then
        echo "FIX:出口IP ✓ ($ip/$loc)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET) — 可能是节点故障,请到 $(proxy_name) 里换条线路"
    fi
    echo "FIX:修复流程结束"
}

# 地区自适应:按当前出口国家一键重设 国家/时区/地区格式(换了国家节点后运行)
set_region() {
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    [ -z "$loc" ] && { echo "FAIL:无法获取出口国家(cloudflare trace 无结果,请先挂代理)"; return 1; }
    info=$(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null)
    ctry=$(echo "$info" | grep '"country"' | cut -d'"' -f4)
    ntz=$(echo "$info" | grep '"timezone"' | cut -d'"' -f4)
    if [ -z "$ctry" ] || [ -z "$ntz" ]; then
        echo "FAIL:ipinfo 未返回国家或时区"; return 1
    fi
    if [ "$loc" != "$ctry" ]; then
        echo "FAIL:出口国家不一致(cloudflare=$loc ipinfo=$ctry),已中止"; return 1
    fi
    nlocale=$(locale_for "$ctry")

    # 改写脚本自身头部三个配置项
    sed -i '' \
        -e "s|^COUNTRY_TARGET=\".*\"|COUNTRY_TARGET=\"$ctry\"|" \
        -e "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$ntz\"|" \
        -e "s|^LOCALE_TARGET=\".*\"|LOCALE_TARGET=\"$nlocale\"|" \
        "$0"
    COUNTRY_TARGET="$ctry"; TZ_TARGET="$ntz"; LOCALE_TARGET="$nlocale"

    # 地区格式(用户级,无需密码)
    defaults write -g AppleLocale "$nlocale"

    # 时区(需管理员权限,会弹一次授权框);看门狗脚本在 root 目录下,顺道用同一次授权同步目标值
    WD="/Library/Application Support/claude-switcher/tz-watchdog.sh"
    adminCmds="/usr/sbin/systemsetup -settimezone $ntz"
    wdsync=0
    if [ -f "$WD" ] && [ ! -w "$WD" ]; then
        adminCmds="$adminCmds; /usr/bin/sed -i '' 's|^TARGET=.*|TARGET=$ntz|' '$WD'"
        wdsync=1
    fi
    if ! osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "set-region 需要管理员权限以锁定时区" with administrator privileges
ASEOF
    then
        echo "FAIL:时区设置被取消或失败(国家/地区格式已更新为 $ctry/$nlocale)"
        return 1
    fi
    # 看门狗目标同步兜底(可写的老版本安装直接 sed;失败则提示运行安装器刷新)
    if [ -f "$WD" ] && [ "$wdsync" -eq 0 ]; then
        sed -i '' "s|^TARGET=.*|TARGET=$ntz|" "$WD" 2>/dev/null || echo "WARN:看门狗目标未同步,请运行安装器刷新"
    fi

    echo "OK:region=$loc tz=$ntz locale=$nlocale"
}

# 自动更新:拉取 main 分支最新代码,SHA256 校验+配置注入+自检+失败回滚(--auto 供 LaunchAgent 每12小时调用)
self_update() {
    if [ "${1:-}" = "--auto" ]; then auto=1; else auto=0; fi
    # 路径全部从脚本自身位置推导,兼容旧版 LaunchDaemon(root) 混跑时 $HOME 不可靠的场景
    BIN=$(cd "$(dirname "$0")" && pwd)
    UHOME="${BIN%/.local/bin}"
    [ "$UHOME" = "$BIN" ] && UHOME="$HOME"
    if [ "$auto" -eq 1 ]; then
        mkdir -p "$BASE"
        exec >>"$BASE/update.log" 2>&1
        echo "# $(date '+%F %T') update --auto 开始"
    fi

    tmpd=$(mktemp -d)
    if ! curl -sL --max-time 30 "https://codeload.github.com/YOURSJEYO/claude-switcher/zip/refs/heads/main" -o "$tmpd/main.zip" \
        || ! unzip -q "$tmpd/main.zip" -d "$tmpd" 2>/dev/null; then
        echo "FAIL:下载或解压失败(网络问题,稍后再试)"; rm -rf "$tmpd"; return 1
    fi
    NEW="$tmpd/claude-switcher-main"
    if [ ! -f "$NEW/core/claude-switch.sh" ]; then
        echo "FAIL:远程包结构异常,已中止"; rm -rf "$tmpd"; return 1
    fi

    # 工件完整性校验:逐项比对仓库 SHA256SUMS,任一不符即中止(防传输篡改;信任根为 GitHub 仓库本身)
    if ! curl -sL --max-time 15 "https://raw.githubusercontent.com/YOURSJEYO/claude-switcher/main/SHA256SUMS" -o "$tmpd/SHA256SUMS" \
        || [ ! -s "$tmpd/SHA256SUMS" ]; then
        echo "FAIL:无法获取校验清单(SHA256SUMS),已中止"; rm -rf "$tmpd"; return 1
    fi
    bad=0
    while read -r sum rel; do
        [ -z "$sum" ] && continue
        if [ ! -f "$NEW/$rel" ] || [ "$(shasum -a 256 "$NEW/$rel" | awk '{print $1}')" != "$sum" ]; then
            bad=1; break
        fi
    done < "$tmpd/SHA256SUMS"
    if [ "$bad" -eq 1 ]; then
        echo "FAIL:工件校验失败,已中止(不排除网络篡改,可稍后重试或手动 update)"; rm -rf "$tmpd"; return 1
    fi

    # 跳过判断:剔除头部5个配置行后与本地已安装版本比对,无差异即已是最新
    strip_cfg() { grep -vE '^(PROXY_MODE|PROXY_GROUP|COUNTRY_TARGET|TZ_TARGET|LOCALE_TARGET)="' "$1"; }
    if [ -f "$BIN/claude-switch.sh" ] && \
       diff <(strip_cfg "$BIN/claude-switch.sh") <(strip_cfg "$NEW/core/claude-switch.sh") >/dev/null 2>&1; then
        echo "OK:已是最新版本"; rm -rf "$tmpd"; return 0
    fi

    # 备份现有核心脚本
    [ -f "$BIN/claude-switch.sh" ] && cp "$BIN/claude-switch.sh" "$BIN/claude-switch.sh.bak"

    # 替换核心脚本 + 从 .bak 读出5个配置值注入新脚本
    cp "$NEW/core/claude-switch.sh" "$BIN/claude-switch.sh"
    PM=""; PG=""; CT=""; TZV=""; LCT=""
    if [ -f "$BIN/claude-switch.sh.bak" ]; then
        get_cfg() { grep "^$1=\"" "$BIN/claude-switch.sh.bak" | head -1 | cut -d'"' -f2; }
        PM=$(get_cfg PROXY_MODE); PG=$(get_cfg PROXY_GROUP); CT=$(get_cfg COUNTRY_TARGET)
        TZV=$(get_cfg TZ_TARGET); LCT=$(get_cfg LOCALE_TARGET)
        inject_cfg() { grep -q "^$1=\"" "$BIN/claude-switch.sh.bak" && sed -i '' "s|^$1=\".*\"|$1=\"$2\"|" "$BIN/claude-switch.sh"; }
        inject_cfg PROXY_MODE "$PM"; inject_cfg PROXY_GROUP "$PG"; inject_cfg COUNTRY_TARGET "$CT"
        inject_cfg TZ_TARGET "$TZV"; inject_cfg LOCALE_TARGET "$LCT"
    fi
    chmod +x "$BIN/claude-switch.sh"

    # 守护进程脚本(root 所有,用户态不可写):与远程模板比对,有差异只提示不自动改
    APPDIR="/Library/Application Support/claude-switcher"
    if [ -f "$APPDIR/claude-bodyguard.sh" ] || [ -f "$APPDIR/tz-watchdog.sh" ]; then
        [ -z "$PM" ] && PM="clash-verge"
        [ -z "$TZV" ] && TZV="America/New_York"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__PROXY_MODE__|$PM|g" "$NEW/daemons/claude-bodyguard.sh" > "$tmpd/bg.new"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__TZ_TARGET__|$TZV|g" "$NEW/daemons/tz-watchdog.sh" > "$tmpd/tz.new"
        if ! diff -q "$tmpd/bg.new" "$APPDIR/claude-bodyguard.sh" >/dev/null 2>&1 || \
           ! diff -q "$tmpd/tz.new" "$APPDIR/tz-watchdog.sh" >/dev/null 2>&1; then
            echo "INFO:守护进程脚本有更新,请运行 installer/安装.command 刷新(需要密码)"
        fi
    fi
    rm -rf "$tmpd"

    # 更新后自检:root(旧版 LaunchDaemon)下切回真实用户执行,避免 defaults 读到 root 的配置
    if [ "$(id -u)" -eq 0 ]; then
        owner=$(stat -f '%Su' "$UHOME" 2>/dev/null)
        if [ -n "$owner" ]; then out=$(sudo -H -u "$owner" "$BIN/claude-switch.sh" checkdetail 2>&1); else out=""; fi
    else
        out=$("$BIN/claude-switch.sh" checkdetail 2>&1)
    fi
    if [ -z "$out" ] || echo "$out" | grep -q '=fail'; then
        [ -f "$BIN/claude-switch.sh.bak" ] && cp "$BIN/claude-switch.sh.bak" "$BIN/claude-switch.sh"
        echo "FAIL:新版自检未通过,已自动回滚"
        return 1
    fi
    echo "OK:更新完成 $(date '+%Y-%m-%d')"
    return 0
}

status() {
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    hasA=0; [ -d "$BASE/accounts/A" ] && hasA=1
    hasB=0; [ -d "$BASE/accounts/B" ] && hasB=1
    echo "current=$cur hasA=$hasA hasB=$hasB"
}

quit_claude() {
    pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

archive_current() {
    cur="$1"
    t0=$(date +%s)
    # 归档=把当前数据目录整体移走(同卷瞬时,跨卷 mv 自动退化为复制),不再全量深拷贝
    rm -rf "$BASE/accounts/$cur.new"
    if mv "$DATA" "$BASE/accounts/$cur.new" 2>/dev/null; then
        rm -rf "$BASE/accounts/$cur"
        mv "$BASE/accounts/$cur.new" "$BASE/accounts/$cur"
    else
        rm -rf "$BASE/accounts/$cur.tmp"
        copy_tree "$DATA" "$BASE/accounts/$cur.tmp" && rm -rf "$BASE/accounts/$cur" && mv "$BASE/accounts/$cur.tmp" "$BASE/accounts/$cur"
    fi
    log "已存档账号$cur ($(( $(date +%s) - t0 ))s)"
}

# 快照复制:APFS 上用 clonefile(COW) 近乎瞬时,不改写已有快照;不支持时回退 ditto 全量复制
copy_tree() {
    src="$1"; dst="$2"
    if [ "${CLAUDE_SWITCHER_NO_CLONE:-0}" != "1" ] && cp -cRp "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dst"
    ditto "$src" "$dst"
}

switch_to() {
    target="$1"
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    just_archived=0

    # 首次运行:把当前登录中的状态收编为账号A
    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
        archive_current A
        just_archived=1
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前登录状态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        # 归档是移动语义,首次收编后需把当前账号还原回 DATA
        if [ "$just_archived" = "1" ] && [ ! -d "$DATA" ] && [ -d "$BASE/accounts/$target" ]; then
            copy_tree "$BASE/accounts/$target" "$DATA"
        fi
        open -a "Claude"
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }

    [ "$just_archived" = "0" ] && [ "$cur" != "none" ] && [ -d "$DATA" ] && archive_current "$cur"

    rm -rf "$DATA.new"
    t0=$(date +%s)
    if [ -d "$BASE/accounts/$target" ]; then
        copy_tree "$BASE/accounts/$target" "$DATA.new"
        log "已载入账号$target 存档 ($(( $(date +%s) - t0 ))s)"
    else
        mkdir -p "$DATA.new"
        log "账号$target 无存档，将以全新状态初始化"
    fi
    rm -rf "$DATA" && mv "$DATA.new" "$DATA"
    echo "$target" > "$BASE/current"

    open -a "Claude"
    log "已切换到账号$target 并启动 ($(( $(date +%s) - t0 ))s)"
    echo "OK:已切换到账号$target ($(( $(date +%s) - t0 ))s)"
    return 0
}

case "${1:-}" in
    check)  check ;;
    checkdetail)
        OUT_FILE="$BASE/last-check.txt"
        {
            echo "# $(date '+%F %T') pid=$$ 开始"
            checkdetail
            echo "# 结束"
        } > "$OUT_FILE" 2>&1
        cat "$OUT_FILE"
        ;;
    fix) fix ;;
    status) status ;;
    switch) switch_to "${2:-}" ;;
    set-region) set_region ;;
    update) self_update "${2:-}" ;;
    write-merge-rules) write_merge_rules ;;  # 隐藏入口:供安装器调用,保证两处合并逻辑一致
    *) echo "用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|set-region|update [--auto]|diagnose-proxy [--proxy URL|--config FILE]"; exit 2 ;;
esac
