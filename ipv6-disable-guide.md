# 禁用 IPv6 配置指南

## 问题诊断

### 典型症状

虽然 `/etc/sysctl.conf` 中已配置：
```bash
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
```

但每次重启后：
- 配置显示已禁用
- 但实际上仍有 IPv6 地址
- 需要手动运行 `sudo sysctl -p` 才能生效

### 问题根源

**核心问题**：`net.ipv6.conf.all.disable_ipv6 = 1` **不会自动影响已存在的网络接口**

```
系统启动流程：
1. 网络接口启动（如 wlp1s0）
2. 接口获取 IPv6 地址（因为默认 disable_ipv6=0）
3. systemd-sysctl 加载配置
4. 配置设置 all=1, default=1
5. 但已存在的 wlp1s0 保持 disable_ipv6=0
6. 结果：配置显示禁用，但实际有 IPv6 地址
```

**验证问题**：
```bash
# 配置层面
cat /proc/sys/net/ipv6/conf/all/disable_ipv6      # 输出: 1 (已禁用)

# 实际接口
cat /proc/sys/net/ipv6/conf/wlp1s0/disable_ipv6   # 输出: 0 (启用!)

# IPv6 地址
ip -6 addr show                                    # 有 IPv6 地址
```

---

## 推荐解决方案

### 方案 1：使用自动管理脚本（推荐）⭐

使用提供的 `ipv6-manager.sh` 脚本，它会自动处理所有细节：

```bash
# 运行脚本
sudo /home/baby/www/service/network/ipv6-manager.sh

# 选择选项 2 - 禁用 IPv6
```

**脚本功能**：
- **选项 1**：启用 IPv6（自动重启 NetworkManager 获取地址）
- **选项 2**：禁用 IPv6（不断网，仅修改配置）
- **选项 3**：重新检查状态
- **选项 4**：重启 NetworkManager（测试用）

**脚本会自动**：
1. 创建/删除 sysctl 配置文件
2. 遍历所有接口设置 IPv6 状态
3. 修改所有已存在的 NetworkManager 连接配置
4. 创建/删除 NetworkManager 全局配置
5. 启用 IPv6 时自动重启 NetworkManager
6. 禁用 IPv6 时不重启（避免断网）

**优点**：
- 一键操作，无需手动配置
- 自动处理所有接口和所有连接
- 正确处理 NetworkManager 连接配置
- 启用/禁用切换流畅
- 开机自动禁用（systemd 服务）

---

### 方案 2：手动配置 + systemd 服务

如果你喜欢手动配置，可以按照以下步骤：

#### 步骤 1: 创建 sysctl 配置

```bash
sudo tee /etc/sysctl.d/99-disable-ipv6.conf > /dev/null <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
```

#### 步骤 2: 配置 NetworkManager

```bash
sudo tee /etc/NetworkManager/conf.d/no-ipv6.conf > /dev/null <<EOF
[connection]
ipv6.method=disabled
EOF
```

#### 步骤 3: 创建 systemd 服务

**创建服务脚本**：
```bash
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
```

**创建 systemd 服务**：
```bash
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

# 启用并启动服务
sudo systemctl daemon-reload
sudo systemctl enable disable-ipv6.service
sudo systemctl start disable-ipv6.service
```

#### 步骤 4: 立即生效

```bash
# 为当前所有接口禁用 IPv6
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||; s|/disable_ipv6||')
    if [ "$name" != "all" ] && [ "$name" != "default" ] && [ "$name" != "lo" ]; then
        sudo sysctl "net.ipv6.conf.$name.disable_ipv6=1"
    fi
done
```

---

### 方案 3：内核启动参数（最彻底）

在内核级别禁用 IPv6，完全阻止 IPv6 模块加载：

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

**优点**：
- 最彻底，内核级别禁用
- 不会有任何 IPv6 相关代码运行
- 一劳永逸，无需 systemd 服务

**缺点**：
- 需要重启系统
- 如果某些应用需要 IPv6 会无法使用

**撤销方法**：
```bash
sudo cp /etc/default/grub.backup /etc/default/grub
sudo update-grub
sudo reboot
```

---

## 验证步骤

重启后**不要**手动运行 `sudo sysctl -p`，直接检查：

### 1. 检查 sysctl 配置

```bash
cat /proc/sys/net/ipv6/conf/all/disable_ipv6
cat /proc/sys/net/ipv6/conf/default/disable_ipv6
cat /proc/sys/net/ipv6/conf/lo/disable_ipv6
```

期望输出：都是 `1`

### 2. 检查具体接口

```bash
cat /proc/sys/net/ipv6/conf/wlp1s0/disable_ipv6  # 替换为你的接口名
```

期望输出：`1`

### 3. 检查 IPv6 地址

```bash
ip -6 addr show
```

期望输出：无 IPv6 地址，或只有 link-local 地址

### 4. 检查 systemd 服务（如果使用方案 1 或 2）

```bash
systemctl status disable-ipv6.service
```

期望输出：`active (exited)`

### 5. 检查 NetworkManager 配置

```bash
cat /etc/NetworkManager/conf.d/no-ipv6.conf
```

期望输出：存在且内容正确

---

## 故障排查

### Q1: 配置显示禁用，但仍有 IPv6 地址？

**原因**：已存在的接口没有被单独设置

**解决**：
```bash
# 方案 A：使用脚本
sudo /home/baby/www/service/network/ipv6-manager.sh

# 方案 B：手动设置
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||; s|/disable_ipv6||')
    if [ "$name" != "all" ] && [ "$name" != "default" ] && [ "$name" != "lo" ]; then
        sudo sysctl "net.ipv6.conf.$name.disable_ipv6=1"
    fi
done
```

### Q2: 重启后 IPv6 又回来了？

**原因**：systemd 服务未安装或未启用

**检查**：
```bash
systemctl status disable-ipv6.service
```

**解决**：
```bash
sudo systemctl enable disable-ipv6.service
sudo systemctl start disable-ipv6.service
```

### Q3: 网络重启后 IPv6 恢复？

**原因**：接口重新初始化时没有重新禁用

**说明**：这是正常行为。使用方案 1 的脚本或 systemd 服务会在启动时自动处理。运行时网络重启不会影响 IPv6 状态。

### Q4: 想临时启用 IPv6 怎么办？

**方法 1：使用脚本**
```bash
sudo /home/baby/www/service/network/ipv6-manager.sh
# 选择 1 - 启用 IPv6
# 脚本会自动重启 NetworkManager 并获取 IPv6 地址
```

**方法 2：手动启用**
```bash
# 1. 为所有接口启用
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||; s|/disable_ipv6||')
    if [ "$name" != "all" ] && [ "$name" != "default" ]; then
        sudo sysctl "net.ipv6.conf.$name.disable_ipv6=0"
    fi
done

# 2. 恢复所有 NetworkManager 连接的 IPv6
nmcli -t -f NAME connection show | grep -v "loopback" | while IFS=: read -r name _; do
    [ -n "$name" ] && nmcli connection modify "$name" ipv6.method auto
done

# 3. 重启 NetworkManager
sudo systemctl restart NetworkManager
```

---

## 方案对比

| 方案 | 优点 | 缺点 | 推荐场景 |
|------|------|------|----------|
| **脚本管理** | 简单、可切换、自动服务 | 依赖脚本文件 | 日常使用，推荐 ⭐ |
| **手动配置 + systemd** | 完全控制、透明 | 配置步骤多 | 了解原理、定制需求 |
| **内核参数** | 最彻底、无副作用 | 需要重启、难切换 | 服务器、永久禁用 |

---

## 文件位置总结

| 文件 | 作用 |
|------|------|
| `/home/baby/www/service/network/ipv6-manager.sh` | IPv6 管理脚本 |
| `/etc/sysctl.d/99-disable-ipv6.conf` | 禁用 IPv6 的持久化配置 |
| `/etc/sysctl.d/99-enable-ipv6.conf` | 启用 IPv6 的持久化配置 |
| `/etc/NetworkManager/conf.d/no-ipv6.conf` | NetworkManager IPv6 配置 |
| `/usr/local/sbin/disable-ipv6-network.sh` | systemd 服务执行脚本 |
| `/etc/systemd/system/disable-ipv6.service` | systemd 服务配置 |
| `/proc/sys/net/ipv6/conf/*/disable_ipv6` | 运行时 IPv6 状态 |

---

## 注意事项

1. **备份重要配置**：修改系统配置前务必备份
2. **Docker 问题**：如果使用 Docker，可能需要额外配置 Docker 的 IPv6 设置
3. **应用依赖**：禁用前确保没有应用程序依赖 IPv6
4. **测试验证**：修改后务必验证 IPv6 是否真正禁用

---

## 参考资料

- `man sysctl.d` - sysctl 配置文档
- `man sysctl` - sysctl 命令文档
- `man systemd-sysctl.service` - systemd sysctl 服务文档
- `man NetworkManager.conf` - NetworkManager 配置文档
- `man systemd.service` - systemd 服务配置文档
