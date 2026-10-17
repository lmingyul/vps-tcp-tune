#!/bin/bash
# Snell 一键升级补丁
# 适用：已经用 net-tcp-tune.sh 部署过 Snell 的机器
# 作用：把主脚本 fix（systemd start-limit + Restart=always + 内核保留端口）应用到现有 Snell 实例
#       + 加每日北京时间 04:00 自动重启 cron（只重启当前 active 的实例）
# 不会卸载/重装任何 Snell 实例，不影响 BBR/DNS/IPv6 等其他配置
#
# 用法（VPS root 上跑）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/lmingyul/vps-tcp-tune/refs/heads/main/snell-upgrade-patch.sh)
#
# 卸载本补丁带来的改动：
#   rm -f /etc/systemd/system/snell-*.service.d/99-net-tcp-tune-fix.conf /etc/systemd/system/snell.service.d/99-net-tcp-tune-fix.conf
#   rm -f /etc/sysctl.d/99-zzz-snell-reserved-ports.conf
#   rm -f /usr/local/bin/snell-daily-restart.sh
#   crontab -l | grep -v "# Snell每日重启" | crontab -
#   systemctl daemon-reload
#   for s in /etc/systemd/system/snell-*.service /etc/systemd/system/snell.service; do [ -f "$s" ] && systemctl restart "$(basename "$s")"; done

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 身份运行：sudo bash $0${NC}"
    exit 1
fi

echo -e "${CYAN}===================================================="
echo -e "  Snell 一键升级补丁"
echo -e "====================================================${NC}"
echo ""

snell_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

snell_list_units() {
    {
        local svc_file
        for svc_file in \
            /etc/systemd/system/snell-*.service \
            /lib/systemd/system/snell-*.service \
            /usr/lib/systemd/system/snell-*.service \
            /etc/systemd/system/snell.service \
            /lib/systemd/system/snell.service \
            /usr/lib/systemd/system/snell.service; do
            [ -f "$svc_file" ] || continue
            basename "$svc_file"
        done

        systemctl list-unit-files 'snell*.service' --no-legend --no-pager 2>/dev/null \
            | awk '{u=$1; if (u=="●") u=$2; print u}'
        systemctl list-units 'snell*.service' --all --no-legend --no-pager 2>/dev/null \
            | awk '{u=$1; if (u=="●") u=$2; print u}'
    } | awk '/^snell\.service$/ || /^snell-[0-9]+\.service$/ { if (!seen[$1]++) print $1 }'
}

snell_unit_port() {
    local unit="$1"
    local port=""
    case "$unit" in
        snell-[0-9]*.service)
            port="${unit#snell-}"
            port="${port%.service}"
            ;;
        snell.service)
            if [ -f "/etc/snell/snell-server.conf" ]; then
                port=$(grep -E '^[[:space:]]*listen[[:space:]]*=' /etc/snell/snell-server.conf 2>/dev/null \
                       | tail -n 1 | sed -E 's/.*:([0-9]+).*/\1/')
            fi
            ;;
    esac
    if snell_valid_port "$port"; then
        echo "$port"
        return 0
    fi
    return 1
}

snell_should_restart_unit() {
    local unit="$1"
    local active_state enabled_state
    active_state=$(systemctl is-active "$unit" 2>/dev/null)
    enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null)
    [ "$active_state" = "active" ] || { [ "$active_state" = "failed" ] && [ "$enabled_state" = "enabled" ]; }
}

normalize_reserved_ports() {
    tr ',' '\n' | sed 's/[[:space:]]//g' | awk '
        $0 == "" { next }
        /^[0-9]+$/ {
            port = $0 + 0
            if (port >= 1 && port <= 65535 && !seen[port]++) values[++n] = port
            next
        }
        /^[0-9]+-[0-9]+$/ {
            split($0, range, "-")
            start = range[1] + 0
            end = range[2] + 0
            if (start >= 1 && end <= 65535 && start <= end) {
                key = start "-" end
                if (!seen[key]++) values[++n] = key
            }
        }
        END {
            for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "," : ""), values[i]
        }
    '
}

# === 1. 给现有 Snell systemd 服务加 drop-in ===
echo -e "${YELLOW}[1/4] 修补 Snell systemd 服务配置（防止 5 次失败永久死锁）${NC}"
PORTS=""
PATCHED=0
while IFS= read -r name; do
    port=$(snell_unit_port "$name" 2>/dev/null || true)
    snell_valid_port "$port" || continue
    PORTS="${PORTS:+$PORTS,}${port}"
    drop_dir="/etc/systemd/system/${name}.d"
    mkdir -p "$drop_dir"
    if ! cat > "${drop_dir}/99-net-tcp-tune-fix.conf" <<EOF
# 由 snell-upgrade-patch.sh 自动写入
# 双写兼容：systemd 230+ 用 StartLimitIntervalSec，旧版(CentOS 7 systemd 219)用 StartLimitInterval
[Unit]
StartLimitIntervalSec=0
StartLimitInterval=0
StartLimitBurst=0

[Service]
Restart=always
RestartSec=10
EOF
    then
        echo -e "  ${RED}✗${NC} 写入 ${drop_dir}/99-net-tcp-tune-fix.conf 失败（磁盘满/只读 fs？）"
        continue
    fi
    PATCHED=$((PATCHED + 1))
    echo -e "  ${GREEN}✓${NC} 已修补 $name (端口 $port)"
done < <(snell_list_units)

if [ "$PATCHED" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠ 未找到任何 Snell systemd 服务，跳过${NC}"
fi
echo ""

# === 2. 写入内核保留端口（合并其他 sysctl.d 已设置的端口，避免覆盖丢失） ===
echo -e "${YELLOW}[2/4] 注册内核保留端口（防止内核临时端口抢占 Snell 监听端口）${NC}"
if [ -n "$PORTS" ]; then
    # 扫描其他 sysctl.d 文件和 /etc/sysctl.conf，收集已设置的 ip_local_reserved_ports
    EXTRA_PORTS=""
    for sysctl_file in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ -f "$sysctl_file" ] || continue
        [ "$(basename "$sysctl_file")" = "99-zzz-snell-reserved-ports.conf" ] && continue
        line=$(grep -E '^[[:space:]]*net\.ipv4\.ip_local_reserved_ports' "$sysctl_file" 2>/dev/null | tail -n 1)
        [ -z "$line" ] && continue
        val=$(echo "$line" | sed -E 's/^[^=]+=[[:space:]]*//' | tr -d ' ')
        [ -z "$val" ] && continue
        EXTRA_PORTS="${EXTRA_PORTS:+$EXTRA_PORTS,}${val}"
    done

    # 合并 Snell 端口 + 其他端口，去重排序
    if [ -n "$EXTRA_PORTS" ]; then
        ALL_PORTS=$(printf '%s,%s\n' "${PORTS}" "${EXTRA_PORTS}" | normalize_reserved_ports)
        echo -e "  ${CYAN}ℹ${NC} 检测到其他 sysctl 文件已设保留端口: ${EXTRA_PORTS}，已合并保留"
    else
        ALL_PORTS=$(printf '%s\n' "$PORTS" | normalize_reserved_ports)
    fi

    if ! cat > /etc/sysctl.d/99-zzz-snell-reserved-ports.conf <<EOF
# Snell 监听端口保留列表（由 snell-upgrade-patch.sh 自动管理）
# 作用：让内核 outbound 临时端口分配跳过这些端口，避免 bind 冲突
# 包含：所有 Snell 端口 + 其他 sysctl 文件中已设置的保留端口（合并去重）
net.ipv4.ip_local_reserved_ports = ${ALL_PORTS}
EOF
    then
        echo -e "  ${RED}✗${NC} 写入 /etc/sysctl.d/99-zzz-snell-reserved-ports.conf 失败"
    elif sysctl -p /etc/sysctl.d/99-zzz-snell-reserved-ports.conf >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} 已注册保留端口: ${ALL_PORTS}"
    else
        echo -e "  ${YELLOW}⚠${NC} 文件已写入但 sysctl -p 应用失败，重启后会自动生效"
    fi
else
    echo -e "  ${YELLOW}⚠ 没有 Snell 端口需要保护，跳过${NC}"
fi
echo ""

# === 3. 重载 systemd + 重启需要恢复的 Snell ===
# 修复 Bug 2: systemctl glob 'snell-*.service' 在 systemd <252 不展开,
# 在 Ubuntu 20.04 / Debian 11 / CentOS 8 / Rocky 8 上会静默失败。
# 改用 for 循环逐个处理,所有 systemd 版本通用。
echo -e "${YELLOW}[3/4] 应用配置 + 重启 active 或 failed+enabled 的 Snell 实例${NC}"
if [ "$PATCHED" -gt 0 ]; then
    systemctl daemon-reload
    while IFS= read -r svc_name; do
        systemctl reset-failed "$svc_name" 2>/dev/null
        if snell_should_restart_unit "$svc_name"; then
            systemctl restart "$svc_name"
        else
            echo -e "  ${CYAN}ℹ${NC} ${svc_name} 当前不是 active/failed+enabled，保持原状态"
        fi
    done < <(snell_list_units)
    sleep 2
    ACTIVE=0
    while IFS= read -r svc_name; do
        if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
            ACTIVE=$((ACTIVE + 1))
        fi
    done < <(snell_list_units)
    echo -e "  ${GREEN}✓${NC} 已重载 + 重启，当前 active 实例: ${ACTIVE}/${PATCHED}"
else
    echo -e "  ${YELLOW}⚠ 跳过${NC}"
fi
echo ""

# === 4. 加每日北京时间 04:00 自动重启 cron（兜底 Snell v5 mux fd 泄漏）===
echo -e "${YELLOW}[4/4] 注册每日北京时间 04:00 自动重启 cron${NC}"

if [ "$PATCHED" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} 没有 Snell 实例，跳过 cron 注册"
elif ! command -v crontab >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} 未安装 crontab 命令（需要 cron/cronie 包），跳过 cron 注册"
else
    # 北京时间 → 系统本地时间换算（修复 Bug 7: fallback 不再假设 UTC,
    # 而是用 date +%z 检测系统真实 UTC 偏移,中国机房 UTC+8 不再算错）
    bj2local() {
        local bh=$1 bm=$2 base td epoch lh lm
        base=$(TZ='Asia/Shanghai' date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
        td=$base
        epoch=$(TZ='Asia/Shanghai' date -d "$td $bh:$bm:00" +%s 2>/dev/null \
                || date -d "$td $bh:$bm:00" +%s 2>/dev/null)
        if [ -n "$epoch" ]; then
            lh=$(date -d "@$epoch" +%H 2>/dev/null || date -r "$epoch" +%H 2>/dev/null)
            lm=$(date -d "@$epoch" +%M 2>/dev/null || date -r "$epoch" +%M 2>/dev/null)
        fi
        if ! [[ "$lh" =~ ^[0-9]{1,2}$ ]]; then
            # fallback: 检测系统真实 UTC 偏移,而不是假设 UTC
            local sys_offset_str delta_h=-8
            sys_offset_str=$(date +%z 2>/dev/null)
            if [[ "$sys_offset_str" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]]; then
                local sign="${BASH_REMATCH[1]}"
                local off_h=$((10#${BASH_REMATCH[2]}))
                # 系统本地时间 = 北京时间(UTC+8) - 8 + 系统offset
                if [ "$sign" = "+" ]; then
                    delta_h=$((off_h - 8))
                else
                    delta_h=$((-off_h - 8))
                fi
            fi
            lh=$((10#$bh + delta_h))
            lm=$((10#$bm))
            while [ "$lh" -lt 0 ]; do lh=$((lh + 24)); done
            while [ "$lh" -ge 24 ]; do lh=$((lh - 24)); done
        fi
        printf "%02d %02d\n" $((10#$lh)) $((10#$lm))
    }

    # 修复 Bug 2: 写一个 wrapper 脚本,cron 调它而不是用 systemctl glob
    cat > /usr/local/bin/snell-daily-restart.sh <<'WRAPPER'
#!/bin/sh
# Snell 每日重启 wrapper(由 snell-upgrade-patch.sh 自动生成,请勿手动修改)
# 只重启当前 active 的 Snell，不会拉起用户手动停止/禁用的实例。
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SYSTEMCTL_BIN=$(command -v systemctl 2>/dev/null || echo /bin/systemctl)
LOCK_FILE="/tmp/net-tcp-tune-snell.lock"

restart_active_snell() {
    seen_units=""
    for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        for svc in "$dir"/snell-*.service "$dir"/snell.service; do
            [ -f "$svc" ] || continue
            unit=$(basename "$svc")
            case "$unit" in
                snell.service) ;;
                snell-[0-9]*.service)
                    echo "$unit" | grep -Eq '^snell-[0-9]+\.service$' || continue
                    ;;
                *) continue ;;
            esac
            case " $seen_units " in
                *" $unit "*) continue ;;
            esac
            seen_units="$seen_units $unit"
            "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null && \
                "$SYSTEMCTL_BIN" restart "$unit" >/dev/null 2>&1
        done
    done
}

if command -v flock >/dev/null 2>&1; then
    (
        flock -n 9 || exit 0
        restart_active_snell
    ) 9>"$LOCK_FILE"
else
    restart_active_snell
fi
WRAPPER
    chmod +x /usr/local/bin/snell-daily-restart.sh

    read -r LOCAL_H LOCAL_M < <(bj2local 04 00)
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# Snell每日重启" > "$TMP_CRON" || true
    echo "${LOCAL_M} ${LOCAL_H} * * * /usr/local/bin/snell-daily-restart.sh >/dev/null 2>&1  # Snell每日重启" >> "$TMP_CRON"
    if crontab "$TMP_CRON" 2>/dev/null; then
        rm -f "$TMP_CRON"
        echo -e "  ${GREEN}✓${NC} 已注册：北京时间 04:00 = 本地时间 ${LOCAL_H}:${LOCAL_M}"
        # 检查 cron 服务是否运行
        if ! (systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null || systemctl is-active --quiet cronie 2>/dev/null || systemctl is-active --quiet cronie.service 2>/dev/null); then
            echo -e "  ${YELLOW}⚠${NC} cron 服务未运行，定时任务不会触发"
            echo -e "      Debian/Ubuntu: ${CYAN}systemctl enable --now cron${NC}"
            echo -e "      CentOS/Rocky:  ${CYAN}systemctl enable --now crond${NC}"
        fi
    else
        echo -e "  ${RED}✗${NC} 注册 cron 失败（临时文件保留: $TMP_CRON）"
    fi
fi
echo ""

# === 验证 ===
echo -e "${CYAN}===================================================="
echo -e "  ✅ 升级完成"
echo -e "====================================================${NC}"
echo ""
echo -e "${CYAN}Snell 实例状态:${NC}"
if [ "$PATCHED" -gt 0 ]; then
    # 修复 Bug 2: glob 在旧 systemd 不展开,改 for 循环
    while IFS= read -r svc_name; do
        active_state=$(systemctl is-active "$svc_name" 2>/dev/null)
        echo "  ${svc_name}: ${active_state}"
    done < <(snell_list_units)
else
    echo "  （无）"
fi
echo ""
echo -e "${CYAN}内核保留端口:${NC}"
sysctl net.ipv4.ip_local_reserved_ports 2>/dev/null || echo "  （无）"
echo ""
echo -e "${CYAN}每日重启 cron:${NC}"
crontab -l 2>/dev/null | grep "Snell每日重启" || echo "  （无）"
echo ""
echo -e "${GREEN}补丁已生效。如需后续装新 Snell，请先把 net-tcp-tune.sh 主脚本更新到最新版（重跑 bbr 命令即可拉最新）。${NC}"
