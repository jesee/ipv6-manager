# IPv6 Manager

简单易用的 IPv6 管理工具，支持快速启用/禁用 IPv6，自动处理 NetworkManager 配置。

## 功能特点

- ✅ **一键切换**：快速启用或禁用 IPv6
- ✅ **自动配置**：自动处理 sysctl 和 NetworkManager 配置
- ✅ **智能管理**：自动修改所有网络连接的 IPv6 设置
- ✅ **状态检查**：实时显示 IPv6 状态和地址信息
- ✅ **测试工具**：内置 NetworkManager 重启功能，方便测试
- ✅ **开机禁用**：支持 systemd 服务，开机自动禁用 IPv6

## 安装

### 方法 1：使用脚本安装（推荐）

```bash
# 克隆或下载脚本
cd /path/to/ipv6-manager.sh

# 运行脚本并选择安装选项
sudo ./ipv6-manager.sh
# 选择 5 - 安装脚本到 /usr/local/bin

# 安装后可在任何位置运行
sudo ipv6-manager
```

### 方法 2：手动安装

```bash
# 复制脚本到系统目录
sudo cp ipv6-manager.sh /usr/local/bin/ipv6-manager

# 设置可执行权限
sudo chmod +x /usr/local/bin/ipv6-manager

# 运行
sudo ipv6-manager
```

## 使用方法

### 交互式菜单

运行脚本后会显示交互式菜单：

```bash
sudo ipv6-manager
```

**菜单选项**：
```
========================================
       IPv6 状态检查
========================================

1. Sysctl 配置状态
2. 内核启动参数
3. IPv6 地址分配

========================================
       请选择操作
========================================

  1 - 启用 IPv6
  2 - 禁用 IPv6
  3 - 重新检查状态
  4 - 重启 NetworkManager (测试用)
  5 - 安装脚本到 /usr/local/bin
  0 - 退出
```

### 选项说明

#### 选项 1：启用 IPv6
- 设置 sysctl 参数启用 IPv6
- 恢复所有 NetworkManager 连接的 IPv6 配置
- 自动重启 NetworkManager 获取 IPv6 地址
- 等待 IPv6 地址分配完成

**适用场景**：需要使用 IPv6 网络时

#### 选项 2：禁用 IPv6
- 设置 sysctl 参数禁用 IPv6
- 修改所有 NetworkManager 连接禁用 IPv6
- 创建配置文件，确保重启后自动禁用
- 不重启 NetworkManager，避免网络中断

**适用场景**：不需要 IPv6，提高安全性或性能

#### 选项 3：重新检查状态
- 刷新并显示当前 IPv6 状态
- 查看配置、地址和接口信息

**适用场景**：检查操作后的效果

#### 选项 4：重启 NetworkManager
- 重启 NetworkManager 服务
- 用于测试 IPv6 配置是否持久化
- 会短暂中断网络连接

**适用场景**：测试配置是否生效

#### 选项 5：安装脚本到系统
- 复制脚本到 `/usr/local/bin/ipv6-manager`
- 设置可执行权限
- 安装后可在任何位置运行 `sudo ipv6-manager`

## 工作原理

### 禁用 IPv6 的流程

1. **创建 sysctl 配置文件**
   - `/etc/sysctl.d/99-disable-ipv6.conf`
   - 设置 `net.ipv6.conf.*.disable_ipv6 = 1`

2. **遍历所有网络接口**
   - 为每个已存在的接口设置 `disable_ipv6=1`
   - 立即生效，无需重启

3. **配置 NetworkManager**
   - 创建全局配置文件
   - 修改所有已存在的网络连接
   - 设置 `ipv6.method=disabled`

### 启用 IPv6 的流程

1. **删除禁用配置**
   - 删除 `/etc/sysctl.d/99-disable-ipv6.conf`
   - 创建 `/etc/sysctl.d/99-enable-ipv6.conf`

2. **启用所有接口的 IPv6**
   - 遍历接口设置 `disable_ipv6=0`

3. **恢复 NetworkManager 配置**
   - 删除禁用配置文件
   - 恢复所有连接的 IPv6 方法为 `auto`

4. **重启 NetworkManager**
   - 触发 IPv6 地址获取（SLAAC/DHCPv6）
   - 等待地址分配完成

## 开机自动禁用 IPv6

如果需要开机自动禁用 IPv6，可以安装 systemd 服务：

```bash
# 1. 创建服务脚本
sudo tee /usr/local/sbin/disable-ipv6-network.sh > /dev/null <<'EOF'
#!/bin/bash
sleep 2
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    iface_name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||' | sed 's|/disable_ipv6||')
    if [ "$iface_name" != "all" ] && [ "$iface_name" != "default" ] && [ "$iface_name" != "lo" ]; then
        if [ -f "$iface" ]; then
            current=$(cat "$iface")
            if [ "$current" = "0" ]; then
                sysctl -w "net.ipv6.conf.$iface_name.disable_ipv6=1" > /dev/null 2>&1
            fi
        fi
    fi
done
exit 0
EOF

sudo chmod +x /usr/local/sbin/disable-ipv6-network.sh

# 2. 创建 systemd 服务
sudo tee /etc/systemd/system/disable-ipv6.service > /dev/null <<EOF
[Unit]
Description=Disable IPv6 on all network interfaces
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disable-ipv6-network.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 3. 启用并启动服务
sudo systemctl daemon-reload
sudo systemctl enable disable-ipv6.service
sudo systemctl start disable-ipv6.service

# 4. 验证服务状态
sudo systemctl status disable-ipv6.service
```

## 常见问题

### Q: 为什么禁用 IPv6 后还有 IPv6 地址？

**A**: 检查具体的网络接口：

```bash
# 检查 wlp1s0 接口（替换为你的接口名）
cat /proc/sys/net/ipv6/conf/wlp1s0/disable_ipv6

# 如果显示 0（启用），手动禁用
sudo sysctl net.ipv6.conf.wlp1s0.disable_ipv6=1
```

### Q: 重启 NetworkManager 后 IPv6 又启用了？

**A**: 脚本应该已经修改了所有连接配置。检查连接设置：

```bash
# 查看连接的 IPv6 方法
nmcli connection show "你的连接名" | grep ipv6.method

# 应该显示 disabled，如果是 auto，手动修改
sudo nmcli connection modify "你的连接名" ipv6.method disabled
```

### Q: 启用 IPv6 后地址不完整？

**A**: 脚本会自动重启 NetworkManager。如果手动操作：

```bash
# 1. 启用 IPv6
sudo sysctl -w "net.ipv6.conf.all.disable_ipv6=0"

# 2. 重启 NetworkManager
sudo systemctl restart NetworkManager

# 3. 等待几秒钟后检查
ip -6 addr show
```

### Q: 如何彻底禁用 IPv6（内核级别）？

**A**: 使用内核启动参数：

```bash
# 1. 备份 GRUB 配置
sudo cp /etc/default/grub /etc/default/grub.backup

# 2. 添加 ipv6.disable=1 参数
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub

# 3. 更新 GRUB
sudo update-grub

# 4. 重启系统
sudo reboot
```

### Q: 如何卸载脚本？

**A**: 删除安装的文件：

```bash
# 删除脚本
sudo rm /usr/local/bin/ipv6-manager

# 删除 systemd 服务（如果安装了）
sudo systemctl disable disable-ipv6.service
sudo rm /etc/systemd/system/disable-ipv6.service
sudo systemctl daemon-reload

# 删除配置文件（可选）
sudo rm /etc/sysctl.d/99-disable-ipv6.conf
sudo rm /etc/sysctl.d/99-enable-ipv6.conf
sudo rm /etc/NetworkManager/conf.d/no-ipv6.conf
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `ipv6-manager.sh` | 主脚本文件 |
| `/usr/local/bin/ipv6-manager` | 安装后的可执行文件 |
| `/usr/local/sbin/disable-ipv6-network.sh` | systemd 服务脚本 |
| `/etc/systemd/system/disable-ipv6.service` | systemd 服务配置 |
| `/etc/sysctl.d/99-disable-ipv6.conf` | IPv6 禁用配置 |
| `/etc/sysctl.d/99-enable-ipv6.conf` | IPv6 启用配置 |
| `/etc/NetworkManager/conf.d/no-ipv6.conf` | NetworkManager 全局配置 |

## 系统要求

- Linux 操作系统
- systemd
- NetworkManager
- bash shell
- root 权限

## 技术细节

### 为什么需要修改每个 NetworkManager 连接？

`/etc/NetworkManager/conf.d/no-ipv6.conf` 中的 `[connection]` 配置只影响**新创建的连接**。对于已经存在的连接（如你的 WiFi），需要单独修改其 IPv6 方法为 `disabled`。

### 为什么启用 IPv6 时要重启 NetworkManager？

启用 IPv6 后，NetworkManager 需要重新获取 IPv6 地址（通过 SLAAC 或 DHCPv6）。不重启只能获取 link-local 地址（`fe80::` 开头），重启后才能获取全球单播地址（如 `2408:` 开头）。

### 为什么禁用 IPv6 时不重启 NetworkManager？

禁用 IPv6 时，sysctl 设置会立即生效，移除所有 IPv6 地址。不需要重启 NetworkManager，避免网络中断。

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！

## 更新日志

### v1.0.0 (2026-01-03)
- 初始版本
- 支持启用/禁用 IPv6
- 自动处理 NetworkManager 配置
- 添加状态检查功能
- 添加测试工具
- 支持安装到系统路径
