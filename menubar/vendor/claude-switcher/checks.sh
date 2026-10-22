#!/bin/bash
# Extracted verbatim from claude-switcher; see UPSTREAM.json and LICENSE.
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

