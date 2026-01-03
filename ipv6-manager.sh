#!/bin/bash

# IPv6 管理脚本
# 用于检查、启用或禁用 IPv6

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 sudo 运行此脚本${NC}"
    exit 1
fi

# 函数：检查 IPv6 状态
check_ipv6_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       IPv6 状态检查${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 检查 sysctl 参数
    local all_status=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    local default_status=$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)
    local lo_status=$(cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null)

    # 检查内核参数
    local kernel_param=$(cat /proc/cmdline | grep -o "ipv6.disable=[0-1]" | cut -d= -f2)

    # 检查 IPv6 地址
    local ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -c "inet6")

    echo -e "1. Sysctl 配置状态:"
    if [ "$all_status" = "1" ] && [ "$default_status" = "1" ]; then
        echo -e "   ${GREEN}✓${NC} IPv6 已通过 sysctl 禁用"
    else
        echo -e "   ${YELLOW}○${NC} IPv6 未通过 sysctl 禁用"
    fi
    echo "   - net.ipv6.conf.all.disable_ipv6 = $all_status"
    echo "   - net.ipv6.conf.default.disable_ipv6 = $default_status"
    echo "   - net.ipv6.conf.lo.disable_ipv6 = $lo_status"
    echo ""

    echo -e "2. 内核启动参数:"
    if [ "$kernel_param" = "1" ]; then
        echo -e "   ${GREEN}✓${NC} IPv6 在内核级别已禁用 (ipv6.disable=1)"
    elif [ -n "$kernel_param" ]; then
        echo -e "   ${YELLOW}○${NC} IPv6 内核参数: ipv6.disable=$kernel_param"
    else
        echo -e "   ${YELLOW}○${NC} 未设置 IPv6 内核启动参数"
    fi
    echo ""

    echo -e "3. IPv6 地址分配:"
    if [ "$ipv6_addrs" -gt 0 ]; then
        echo -e "   ${YELLOW}○${NC} 检测到 $ipv6_addrs 个 IPv6 地址"
        echo ""
        echo "   当前 IPv6 地址列表:"
        ip -6 addr show 2>/dev/null | grep "inet6" | head -5
    else
        echo -e "   ${GREEN}✓${NC} 未检测到 IPv6 地址"
    fi
    echo ""

    # 综合判断
    if [ "$all_status" = "1" ] && [ "$default_status" = "1" ]; then
        echo -e "${GREEN}当前状态: IPv6 已禁用${NC}"
        return 1
    else
        echo -e "${YELLOW}当前状态: IPv6 已启用${NC}"
        return 0
    fi
}

# 函数：启用 IPv6
enable_ipv6() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       启用 IPv6${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 检查 /etc/sysctl.d/99-disable-ipv6.conf 是否存在
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        echo "正在移除 sysctl IPv6 禁用配置..."
        rm -f /etc/sysctl.d/99-disable-ipv6.conf
    fi

    # 检查 /etc/sysctl.conf 中是否有禁用配置
    if grep -q "net.ipv6.conf.*disable_ipv6 = 1" /etc/sysctl.conf 2>/dev/null; then
        echo "正在从 /etc/sysctl.conf 中移除 IPv6 禁用配置..."
        sed -i '/net\.ipv6\.conf\..*\.disable_ipv6 = 1/d' /etc/sysctl.conf
    fi

    # 创建启用 IPv6 的配置
    echo "正在创建 IPv6 启用配置..."
    cat > /etc/sysctl.d/99-enable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF

    # 应用配置
    echo "正在应用 sysctl 配置..."
    sysctl -p /etc/sysctl.d/99-enable-ipv6.conf > /dev/null 2>&1

    # 为所有已存在的接口启用 IPv6
    echo "正在为所有已存在的网络接口启用 IPv6..."
    for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        iface_name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||' | sed 's|/disable_ipv6||')
        if [ "$iface_name" != "all" ] && [ "$iface_name" != "default" ] && [ "$iface_name" != "lo" ]; then
            if [ -f "$iface" ]; then
                current=$(cat "$iface")
                if [ "$current" = "1" ]; then
                    echo "  启用 $iface_name 的 IPv6"
                    sysctl "net.ipv6.conf.$iface_name.disable_ipv6=0" > /dev/null 2>&1
                fi
            fi
        fi
    done

    # 移除 NetworkManager 的 IPv6 禁用配置（让它重启时不禁用 IPv6）
    if systemctl is-active --quiet NetworkManager; then
        echo "正在移除 NetworkManager IPv6 禁用配置..."
        rm -f /etc/NetworkManager/conf.d/no-ipv6.conf

        # 恢复所有已存在的连接的 IPv6 配置
        echo "  正在恢复所有网络连接的 IPv6 配置..."
        local connections=$(nmcli -t -f NAME,TYPE connection show | grep -v "loopback" | awk -F: '{print $1}')

        while IFS= read -r conn; do
            if [ -n "$conn" ]; then
                # 恢复连接的 IPv6 方法为 auto
                nmcli connection modify "$conn" ipv6.method auto > /dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo "    • $conn: IPv6 已设置为自动"
                fi
            fi
        done <<< "$connections"

        # 重启 NetworkManager 以触发 IPv6 地址获取
        echo ""
        echo "正在重启 NetworkManager 以获取 IPv6 地址..."
        systemctl restart NetworkManager > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            echo "  ✓ NetworkManager 重启成功"
            echo "  等待 IPv6 地址分配..."
            sleep 3
        else
            echo "  ✗ NetworkManager 重启失败"
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ IPv6 已启用${NC}"
    echo ""
    echo "当前效果："
    echo "  • 立即生效：所有接口的 IPv6 已启用"
    echo "  • 持久化：配置文件已创建，重启后自动生效"
    echo "  • 自动化：NetworkManager 已重启并获取 IPv6 地址"
    echo ""
    echo "提示：如果之前在内核启动参数中禁用了 IPv6，需要手动编辑："
    echo "  1. 编辑 /etc/default/grub"
    echo "  2. 从 GRUB_CMDLINE_LINUX_DEFAULT 中移除 ipv6.disable=1"
    echo "  3. 运行 sudo update-grub"
    echo "  4. 重启系统"
}

# 函数：禁用 IPv6
disable_ipv6() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       禁用 IPv6${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 创建禁用 IPv6 的配置
    echo "正在创建 sysctl IPv6 禁用配置..."
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    # 移除启用 IPv6 的配置
    if [ -f "/etc/sysctl.d/99-enable-ipv6.conf" ]; then
        rm -f /etc/sysctl.d/99-enable-ipv6.conf
    fi

    # 应用配置
    echo "正在应用 sysctl 配置..."
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1

    # 关键：对每个已存在的接口单独设置 disable_ipv6
    echo "正在为所有已存在的网络接口禁用 IPv6..."

    # 获取所有支持 IPv6 的网络接口
    for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        iface_name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||' | sed 's|/disable_ipv6||')

        # 排除 all, default, lo
        if [ "$iface_name" != "all" ] && [ "$iface_name" != "default" ] && [ "$iface_name" != "lo" ]; then
            # 检查接口是否存在
            if [ -f "$iface" ]; then
                current=$(cat "$iface")
                if [ "$current" = "0" ]; then
                    echo "  禁用 $iface_name 的 IPv6"
                    sysctl "net.ipv6.conf.$iface_name.disable_ipv6=1" > /dev/null 2>&1
                fi
            fi
        fi
    done

    # 配置 NetworkManager - 让它重启时自动禁用 IPv6
    if systemctl is-active --quiet NetworkManager; then
        echo "正在配置 NetworkManager（重启时自动禁用 IPv6）..."

        # 1. 创建全局配置文件（影响新连接）
        cat > /etc/NetworkManager/conf.d/no-ipv6.conf <<EOF
[connection]
ipv6.method=disabled
EOF

        # 2. 修改所有已存在的连接，禁用 IPv6
        echo "  正在修改所有已存在的网络连接..."
        local connections=$(nmcli -t -f NAME,TYPE connection show | grep -v "loopback" | awk -F: '{print $1}')

        while IFS= read -r conn; do
            if [ -n "$conn" ]; then
                # 修改连接的 IPv6 方法为 disabled
                nmcli connection modify "$conn" ipv6.method disabled > /dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo "    • $conn: IPv6 已禁用"
                fi
            fi
        done <<< "$connections"

        echo "  ✓ NetworkManager 配置已更新，重启后会自动禁用 IPv6"
    fi

    echo ""
    echo -e "${GREEN}✓ IPv6 已禁用${NC}"
    echo ""
    echo "当前效果："
    echo "  • 立即生效：所有接口的 IPv6 已禁用"
    echo "  • 持久化：配置文件已创建，重启后自动生效"
    echo "  • 自动化：NetworkManager 重启后会自动禁用 IPv6"
    echo ""
    echo "提示：为了更彻底地禁用 IPv6，可以考虑添加内核启动参数："
    echo "  sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"ipv6.disable=1 /' /etc/default/grub"
    echo "  sudo update-grub"
    echo "  sudo reboot"
}

# 函数：重启 NetworkManager
restart_networkmanager() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    重启 NetworkManager${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 检查 NetworkManager 是否运行
    if ! systemctl is-active --quiet NetworkManager; then
        echo -e "${RED}错误: NetworkManager 未运行${NC}"
        return 1
    fi

    echo "正在重启 NetworkManager..."
    echo "警告：这会短暂中断网络连接"
    echo ""
    read -p "确认继续? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "正在重启 NetworkManager..."
        systemctl restart NetworkManager

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ NetworkManager 重启成功${NC}"
            echo ""
            echo "等待网络恢复..."
            sleep 3

            # 显示当前 NetworkManager 状态
            echo ""
            echo "NetworkManager 状态:"
            systemctl status NetworkManager --no-pager | head -10
        else
            echo -e "${RED}✗ NetworkManager 重启失败${NC}"
            return 1
        fi
    else
        echo "操作已取消"
    fi
}

# 主程序
main() {
    clear
    check_ipv6_status
    local current_status=$?

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       请选择操作${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} - 启用 IPv6"
    echo -e "  ${RED}2${NC} - 禁用 IPv6"
    echo -e "  ${YELLOW}3${NC} - 重新检查状态"
    echo -e "  ${BLUE}4${NC} - 重启 NetworkManager (测试用)"
    echo -e "  ${BLUE}0${NC} - 退出"
    echo ""
    echo -n "请输入选项 [0-4]: "

    read -r choice

    case $choice in
        1)
            if [ $current_status -eq 0 ]; then
                echo ""
                echo -e "${YELLOW}IPv6 已经是启用状态${NC}"
            else
                enable_ipv6
            fi
            ;;
        2)
            if [ $current_status -eq 1 ]; then
                echo ""
                echo -e "${YELLOW}IPv6 已经是禁用状态${NC}"
            else
                disable_ipv6
            fi
            ;;
        3)
            exec "$0"
            ;;
        4)
            restart_networkmanager
            ;;
        0)
            echo ""
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo ""
            echo -e "${RED}无效选项${NC}"
            exit 1
            ;;
    esac

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo "操作完成后，当前状态："
    echo -e "${BLUE}========================================${NC}"
    echo ""
    check_ipv6_status
}

# 运行主程序
main
