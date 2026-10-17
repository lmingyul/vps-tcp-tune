#!/bin/bash
#=============================================================================
# 脚本名称: install-alias.sh
# 功能描述: 为 net-tcp-tune 脚本创建/卸载快捷别名
# 使用方法: 
#   安装: bash install-alias.sh [install]
#   卸载: bash install-alias.sh uninstall
#=============================================================================

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m' # No Color

# 检测操作模式（安装或卸载）
MODE="${1:-install}"
if [ "$MODE" != "install" ] && [ "$MODE" != "uninstall" ]; then
    echo -e "${RED}错误: 未知参数 '$MODE'${NC}"
    echo "使用方法:"
    echo "  安装: bash install-alias.sh [install]"
    echo "  卸载: bash install-alias.sh uninstall"
    exit 1
fi

# 检测当前使用的 shell
CURRENT_SHELL=$(basename "$SHELL")

# 根据不同的 shell 设置配置文件（检查多个可能的配置文件）
detect_rc_file() {
    if [ "$CURRENT_SHELL" = "zsh" ]; then
        RC_FILE="$HOME/.zshrc"
    elif [ "$CURRENT_SHELL" = "bash" ]; then
        RC_FILE="$HOME/.bashrc"
        # 如果 .bashrc 不存在，使用 .bash_profile
        if [ ! -f "$RC_FILE" ]; then
            RC_FILE="$HOME/.bash_profile"
        fi
    else
        RC_FILE="$HOME/.bashrc"
    fi
    
    # 如果文件不存在，创建它
    if [ ! -f "$RC_FILE" ]; then
        if ! touch "$RC_FILE"; then
            echo -e "${RED}错误: 无法创建配置文件 ${RC_FILE}${NC}"
            exit 1
        fi
    fi
}

detect_rc_file

alias_block_exists() {
    if [ ! -r "$RC_FILE" ]; then
        echo -e "${RED}错误: 无法读取配置文件 ${RC_FILE}${NC}" >&2
        return 2
    fi

    grep -qE '(^# >>> net-tcp-tune alias >>>|net-tcp-tune 快捷别名)' "$RC_FILE" 2>/dev/null && return 0

    awk '
    function strip_unquoted_comment(line,    i, c, out, in_single, in_double, escaped) {
        out = ""
        in_single = 0
        in_double = 0
        escaped = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (escaped) {
                out = out c
                escaped = 0
                continue
            }
            if (c == "\\" && in_double) {
                out = out c
                escaped = 1
                continue
            }
            if (c == "'"'"'" && !in_double) in_single = !in_single
            if (c == "\"" && !in_single) in_double = !in_double
            if (c == "#" && !in_single && !in_double) break
            out = out c
        }
        return out
    }
    function is_project_alias(line,    body) {
        body = strip_unquoted_comment(line)
        return body ~ /^[[:space:]]*alias[[:space:]]+(bbr|dog)=/ &&
               body ~ /(raw\.githubusercontent\.com|github\.com)\/Eric86777\/vps-tcp-tune\// &&
               body ~ /net-tcp-tune\.sh/
    }
    is_project_alias($0) { found = 1; exit }
    END { exit(found ? 0 : 1) }
    ' "$RC_FILE"
}

append_alias_block() {
    cat <<'ALIAS_EOF'
# >>> net-tcp-tune alias >>>
# ========================================
# net-tcp-tune 快捷别名 (自动添加)
# 使用 -q 忽略本机 curlrc，并用时间戳参数确保每次都获取最新版本，避免缓存
# ========================================
alias bbr="bash <(curl -q -fsSL \"https://raw.githubusercontent.com/lmingyul/vps-tcp-tune/refs/heads/main/net-tcp-tune.sh?\$(date +%s)\")"
# <<< net-tcp-tune alias <<<
ALIAS_EOF
}

strip_alias_blocks() {
    local file="$1"

    awk '
    function flush_pending(    i) {
        for (i = 1; i <= pending_count; i++) print pending[i]
        pending_count = 0
        candidate = 0
    }
    function add_pending(line) {
        pending[++pending_count] = line
    }
    function strip_unquoted_comment(line,    i, c, out, in_single, in_double, escaped) {
        out = ""
        in_single = 0
        in_double = 0
        escaped = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (escaped) {
                out = out c
                escaped = 0
                continue
            }
            if (c == "\\" && in_double) {
                out = out c
                escaped = 1
                continue
            }
            if (c == "'"'"'" && !in_double) in_single = !in_single
            if (c == "\"" && !in_single) in_double = !in_double
            if (c == "#" && !in_single && !in_double) break
            out = out c
        }
        return out
    }
    function is_project_alias(line,    body) {
        body = strip_unquoted_comment(line)
        return body ~ /^[[:space:]]*alias[[:space:]]+(bbr|dog)=/ &&
               body ~ /(raw\.githubusercontent\.com|github\.com)\/Eric86777\/vps-tcp-tune\// &&
               body ~ /net-tcp-tune\.sh/
    }
    function is_managed_comment(line) {
        return line ~ /^# >>> net-tcp-tune alias >>>/ ||
               line ~ /^# <<< net-tcp-tune alias <<</ ||
               line ~ /^# =+$/ ||
               line ~ /net-tcp-tune[[:space:]]+快捷别名/ ||
               line ~ /使用.*时间戳参数确保每次都获取最新版本/
    }
    function is_end_marker(line) {
        return line ~ /^# <<< net-tcp-tune alias <<</
    }
    BEGIN {
        pending_count = 0
        drop_next_end_marker = 0
    }
    drop_next_end_marker && is_end_marker($0) {
        drop_next_end_marker = 0
        next
    }
    is_managed_comment($0) {
        add_pending($0)
        if (pending_count >= 12) flush_pending()
        next
    }
    pending_count > 0 {
        if (is_project_alias($0)) {
            pending_count = 0
            drop_next_end_marker = 1
            next
        }
        flush_pending()
    }
    is_project_alias($0) { drop_next_end_marker = 1; next }
    {
        print
    }
    END {
        flush_pending()
    }
    ' "$file"
}

write_rc_safely() {
    local new_content="$1"
    local backup_file="${RC_FILE}.bak.$(date +%Y%m%d_%H%M%S).$$"

    if cmp -s "$RC_FILE" "$new_content"; then
        LAST_BACKUP_FILE=""
        return 2
    fi

    if ! cp -p "$RC_FILE" "$backup_file"; then
        echo -e "${RED}错误: 无法备份 ${RC_FILE}${NC}" >&2
        return 1
    fi

    if ! cat "$new_content" > "$RC_FILE"; then
        echo -e "${RED}错误: 写入 ${RC_FILE} 失败，正在尝试恢复备份${NC}" >&2
        cat "$backup_file" > "$RC_FILE" 2>/dev/null || true
        return 1
    fi

    if ! cmp -s "$new_content" "$RC_FILE"; then
        echo -e "${RED}错误: 写入校验失败，正在尝试恢复备份${NC}" >&2
        cat "$backup_file" > "$RC_FILE" 2>/dev/null || true
        return 1
    fi

    LAST_BACKUP_FILE="$backup_file"
    return 0
}

# 卸载功能
uninstall_alias() {
    echo -e "${CYAN}=== 卸载 net-tcp-tune 快捷别名 ===${NC}"
    echo ""
    echo -e "检测到 Shell: ${GREEN}${CURRENT_SHELL}${NC}"
    echo -e "配置文件: ${GREEN}${RC_FILE}${NC}"
    echo ""
    
    # 检查别名是否已存在
    alias_block_exists
    local exists_rc=$?
    if [ "$exists_rc" -eq 2 ]; then
        echo -e "${RED}❌ 无法读取配置文件，卸载别名失败${NC}"
        echo ""
        return 1
    fi
    if [ "$exists_rc" -ne 0 ]; then
        echo -e "${YELLOW}未找到已安装的别名，无需卸载${NC}"
        echo ""
        return 0
    fi

    local temp_file
    temp_file=$(mktemp "${RC_FILE}.tmp.XXXXXX") || {
        echo -e "${RED}错误: 无法创建临时文件${NC}"
        return 1
    }

    if ! strip_alias_blocks "$RC_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        echo -e "${RED}错误: 清理别名内容失败${NC}"
        return 1
    fi

    write_rc_safely "$temp_file"
    local write_rc=$?
    rm -f "$temp_file"

    case "$write_rc" in
        0)
        echo -e "${GREEN}✅ 别名已从 ${RC_FILE} 中移除${NC}"
        echo ""
            [ -n "$LAST_BACKUP_FILE" ] && echo -e "${YELLOW}提示: 原配置文件已备份为 ${LAST_BACKUP_FILE}${NC}"
        echo ""
        echo -e "${CYAN}=== 现在生效（执行以下命令）===${NC}"
        echo ""
        echo -e "${YELLOW}source ${RC_FILE}${NC}"
        echo ""
        echo "或者关闭终端重新打开，卸载即生效。"
        echo ""
            ;;
        2)
            echo -e "${YELLOW}未找到需要删除的内容${NC}"
            echo ""
            ;;
        *)
            echo -e "${RED}❌ 卸载别名失败${NC}"
            echo ""
            return 1
            ;;
    esac
}

# 安装功能
install_alias() {
    echo -e "${CYAN}=== 安装 net-tcp-tune 快捷别名 ===${NC}"
    echo ""
    echo -e "检测到 Shell: ${GREEN}${CURRENT_SHELL}${NC}"
    echo ""
    echo -e "配置文件: ${GREEN}${RC_FILE}${NC}"
    echo ""
    local had_alias=0
    alias_block_exists
    local exists_rc=$?
    if [ "$exists_rc" -eq 2 ]; then
        echo -e "${RED}❌ 无法读取配置文件，安装别名失败${NC}"
        return 1
    fi
    if [ "$exists_rc" -eq 0 ]; then
        had_alias=1
        echo -e "${YELLOW}配置已存在，正在更新...${NC}"
    fi

    local temp_file
    temp_file=$(mktemp "${RC_FILE}.tmp.XXXXXX") || {
        echo -e "${RED}错误: 无法创建临时文件${NC}"
        return 1
    }

    if ! strip_alias_blocks "$RC_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        echo -e "${RED}错误: 清理旧别名内容失败${NC}"
        return 1
    fi

    if [ -s "$temp_file" ] && [ "$(tail -c 1 "$temp_file" | wc -l | tr -d ' ')" -eq 0 ]; then
        printf '\n' >> "$temp_file"
    fi
    append_alias_block >> "$temp_file"

    write_rc_safely "$temp_file"
    local write_rc=$?
    rm -f "$temp_file"

    if [ "$write_rc" -eq 1 ]; then
        echo -e "${RED}❌ 写入别名失败${NC}"
        return 1
    fi

    if [ "$had_alias" -eq 1 ]; then
        echo -e "${GREEN}✅ 别名已更新到 ${RC_FILE}${NC}"
        echo ""
    else
        echo -e "${GREEN}✅ 别名已添加到 ${RC_FILE}${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}=== 快捷命令 ===${NC}"
    echo ""
    echo -e "  ${GREEN}bbr${NC}   - 一键运行系统优化脚本"
    echo ""
    echo -e "${CYAN}=== 使用方法 ===${NC}"
    echo ""
    echo "1. 重新加载配置："
    echo -e "   ${YELLOW}source ${RC_FILE}${NC}"
    echo ""
    echo "2. 或者关闭终端重新打开"
    echo ""
    echo "3. 然后直接输入快捷命令："
    echo -e "   ${GREEN}bbr${NC}  (系统优化)"
    echo ""
    echo -e "${CYAN}=== 卸载方法 ===${NC}"
    echo ""
    echo "如需卸载别名，请运行："
    echo -e "   ${YELLOW}bash install-alias.sh uninstall${NC}"
    echo ""
    echo -e "${CYAN}=== 现在就生效（执行以下命令）===${NC}"
    echo ""
    echo -e "${YELLOW}source ${RC_FILE}${NC}"
    echo ""
}

# 根据模式执行相应操作
case "$MODE" in
    install)
        install_alias
        ;;
    uninstall)
        uninstall_alias
        ;;
esac
