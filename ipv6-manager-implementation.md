# IPv6 管理脚本实现详解

## 脚本结构概览

```
ipv6-manager.sh
├── 颜色定义 (RED, GREEN, YELLOW, BLUE, NC)
├── 权限检查 (必须 root 运行)
├── check_ipv6_status()       - 检查 IPv6 状态
├── enable_ipv6()             - 启用 IPv6（自动重启 NetworkManager）
├── disable_ipv6()            - 禁用 IPv6（不重启 NetworkManager）
├── restart_networkmanager()  - 重启 NetworkManager（测试用）
└── main()                    - 交互式主程序

配套服务：
└── disable-ipv6.service      - 开机自动禁用 IPv6
```

---

## 一、如何检查 IPv6 是否禁用

### 函数：`check_ipv6_status()`

### 检查的三个层面

#### 1️⃣ Sysctl 配置层面检查

**读取三个关键参数**：

```bash
# 读取全局配置
cat /proc/sys/net/ipv6/conf/all/disable_ipv6
# 输出: 0=启用, 1=禁用

# 读取默认配置（影响新创建的接口）
cat /proc/sys/net/ipv6/conf/default/disable_ipv6
# 输出: 0=启用, 1=禁用

# 读取回环接口配置
cat /proc/sys/net/ipv6/conf/lo/disable_ipv6
# 输出: 0=启用, 1=禁用
```

**判断逻辑**：
```bash
if [ "$all_status" = "1" ] && [ "$default_status" = "1" ]; then
    echo "IPv6 已通过 sysctl 禁用"
    return 1  # 返回 1 表示已禁用
else
    echo "IPv6 未通过 sysctl 禁用"
    return 0  # 返回 0 表示已启用
fi
```

#### 2️⃣ 内核启动参数检查

**检查内核命令行**：

```bash
cat /proc/cmdline | grep -o "ipv6.disable=[0-1]" | cut -d= -f2
```

**可能的输出**：
- `"1"` - 内核级别禁用了 IPv6（最彻底）
- `"0"` - 内核级别启用了 IPv6
- `""` (空) - 未设置内核参数

#### 3️⃣ IPv6 地址分配检查

**统计 IPv6 地址数量**：

```bash
ip -6 addr show 2>/dev/null | grep -c "inet6"
```

**输出**：
- `> 0` - 有 IPv6 地址（说明 IPv6 实际在运行）
- `0` - 无 IPv6 地址（说明 IPv6 已禁用）

**显示前 5 个 IPv6 地址**：
```bash
ip -6 addr show 2>/dev/null | grep "inet6" | head -5
```

### 综合判断逻辑

```
IF (all=1 AND default=1):
    当前状态: IPv6 已禁用 (配置层面)
ELSE:
    当前状态: IPv6 已启用
```

**注意**：即使配置显示已禁用，如果仍有 IPv6 地址，说明实际未禁用成功。

---

## 二、禁用 IPv6 操作实现

### 函数：`disable_ipv6()`

### 实现步骤（按顺序）

#### 步骤 1: 创建 sysctl 配置文件

**文件位置**: `/etc/sysctl.d/99-disable-ipv6.conf`

```bash
cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
```

**作用**：确保重启后配置持久化

#### 步骤 2: 移除启用配置（如果存在）

```bash
rm -f /etc/sysctl.d/99-enable-ipv6.conf
```

#### 步骤 3: 应用 sysctl 配置

```bash
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1
```

**作用**：立即应用配置到当前系统

#### 步骤 4: ⭐ 关键步骤 - 为已存在的接口禁用 IPv6

**问题根源**：
- `net.ipv6.conf.all.disable_ipv6 = 1` 只影响**新创建**的接口
- 已经存在的接口（如 wlp1s0）需要**单独设置**

**解决方法**：

```bash
# 遍历所有 IPv6 接口
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    # 提取接口名
    iface_name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||' | sed 's|/disable_ipv6||')

    # 排除特殊接口
    if [ "$iface_name" != "all" ] && [ "$iface_name" != "default" ] && [ "$iface_name" != "lo" ]; then
        # 读取当前值
        current=$(cat "$iface")

        # 如果当前是启用状态（0），则禁用
        if [ "$current" = "0" ]; then
            sysctl "net.ipv6.conf.$iface_name.disable_ipv6=1" > /dev/null 2>&1
        fi
    fi
done
```

**示例**：
```bash
# 这会执行类似以下的命令：
sysctl net.ipv6.conf.wlp1s0.disable_ipv6=1
sysctl net.ipv6.conf.eth0.disable_ipv6=1
sysctl net.ipv6.conf.docker0.disable_ipv6=1
# ... 等等
```

#### 步骤 5: 配置 NetworkManager（修改所有连接）

**创建全局配置文件**：

```bash
cat > /etc/NetworkManager/conf.d/no-ipv6.conf <<EOF
[connection]
ipv6.method=disabled
EOF
```

**修改所有已存在的连接**（关键步骤）：

```bash
# 获取所有连接名称
connections=$(nmcli -t -f NAME,TYPE connection show | grep -v "loopback" | awk -F: '{print $1}')

# 为每个连接设置 IPv6 方法为 disabled
while IFS= read -r conn; do
    nmcli connection modify "$conn" ipv6.method disabled
done <<< "$connections"
```

**为什么需要修改每个连接**：
- `[connection]` 配置只影响**新创建的连接**
- 已存在的连接（如 WiFi）需要单独修改
- 不修改已存在连接，重启 NetworkManager 后 IPv6 会重新启用

**为什么不重启 NetworkManager**：
- ✅ sysctl 设置已经立即生效
- ✅ 避免网络中断
- ✅ 配置已持久化，下次重启会自动应用

### 最终效果

1. ✅ 配置文件持久化（重启后自动生效）
2. ✅ 当前系统立即生效
3. ✅ 所有已存在的接口 IPv6 被禁用
4. ✅ systemd 服务在下次启动时自动禁用

---

## 三、启用 IPv6 操作实现

### 函数：`enable_ipv6()`

### 实现步骤（按顺序）

#### 步骤 1: 移除禁用配置文件

```bash
# 删除 sysctl 禁用配置
rm -f /etc/sysctl.d/99-disable-ipv6.conf
```

#### 步骤 2: 清理 /etc/sysctl.conf 中的禁用配置

```bash
if grep -q "net.ipv6.conf.*disable_ipv6 = 1" /etc/sysctl.conf; then
    # 删除所有包含 disable_ipv6 = 1 的行
    sed -i '/net\.ipv6\.conf\..*\.disable_ipv6 = 1/d' /etc/sysctl.conf
fi
```

**作用**：清理用户可能手动添加的配置

#### 步骤 3: 创建启用配置文件

**文件位置**: `/etc/sysctl.d/99-enable-ipv6.conf`

```bash
cat > /etc/sysctl.d/99-enable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
```

#### 步骤 4: 应用配置

```bash
sysctl -p /etc/sysctl.d/99-enable-ipv6.conf > /dev/null 2>&1
```

#### 步骤 5: 为所有已存在的接口启用 IPv6

```bash
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    iface_name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||' | sed 's|/disable_ipv6||')
    if [ "$iface_name" != "all" ] && [ "$iface_name" != "default" ] && [ "$iface_name" != "lo" ]; then
        if [ -f "$iface" ]; then
            current=$(cat "$iface")
            if [ "$current" = "1" ]; then
                sysctl "net.ipv6.conf.$iface_name.disable_ipv6=0" > /dev/null 2>&1
            fi
        fi
    fi
done
```

#### 步骤 6: 移除 NetworkManager 禁用配置（并重启）

```bash
# 删除全局配置
rm -f /etc/NetworkManager/conf.d/no-ipv6.conf

# 恢复所有连接的 IPv6 方法为 auto
connections=$(nmcli -t -f NAME,TYPE connection show | grep -v "loopback" | awk -F: '{print $1}')
while IFS= read -r conn; do
    nmcli connection modify "$conn" ipv6.method auto
done <<< "$connections"

# 重启 NetworkManager 获取 IPv6 地址
systemctl restart NetworkManager
sleep 3  # 等待 IPv6 地址分配
```

**为什么需要重启 NetworkManager**：
- 启用 IPv6 后需要触发 IPv6 地址获取（SLAAC/DHCPv6）
- 重启后 NetworkManager 会自动获取完整的 IPv6 地址
- 包括全球单播地址（如 2408: 开头的地址）

---

## 四、systemd 服务实现

### 为什么需要 systemd 服务？

**问题**：
- 配置文件中的 `all=1` 只影响新接口
- 重启后需要自动为所有接口禁用 IPv6

**解决**：创建 systemd 服务在网络初始化后自动禁用所有接口的 IPv6

### 服务脚本

**位置**: `/usr/local/sbin/disable-ipv6-network.sh`

```bash
#!/bin/bash
# 在网络接口启动后禁用 IPv6
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
```

### systemd 服务配置

**位置**: `/etc/systemd/system/disable-ipv6.service`

```ini
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
```

**配置说明**：
- `After=network-online.target` - 在网络在线后执行
- `Type=oneshot` - 只执行一次
- `RemainAfterExit=yes` - 执行完成后保持活跃状态
- `WantedBy=multi-user.target` - 在多用户模式下启动

### 服务管理

```bash
# 启用服务（开机自动启动）
sudo systemctl enable disable-ipv6.service

# 启动服务（立即执行）
sudo systemctl start disable-ipv6.service

# 查看服务状态
sudo systemctl status disable-ipv6.service

# 禁用服务
sudo systemctl disable disable-ipv6.service

# 停止服务
sudo systemctl stop disable-ipv6.service
```

---

## 五、关键技术点

### 1. 为什么需要遍历接口设置？

**问题**：
```bash
# 这样设置后
sysctl net.ipv6.conf.all.disable_ipv6=1
```

**不会**自动影响已存在的接口！

**原理**：
- `all` 只影响**新创建**的接口
- 已存在的接口保持原有状态
- 必须逐个接口设置

### 2. 为什么不重启 NetworkManager？

**之前的错误做法**：
```bash
# 禁用 IPv6
sysctl net.ipv6.conf.all.disable_ipv6=1
sysctl net.ipv6.conf.wlp1s0.disable_ipv6=1  # ✅ 成功

systemctl restart NetworkManager              # ❌ 问题！
# 接口重新初始化
# wlp1s0/disable_ipv6 又变回 0
# IPv6 地址又出现了
```

**正确的做法**：
```bash
# 禁用 IPv6
sysctl net.ipv6.conf.all.disable_ipv6=1
sysctl net.ipv6.conf.wlp1s0.disable_ipv6=1  # ✅ 成功

# 不重启 NetworkManager
# 配置保持生效
# IPv6 持续禁用
```

### 3. 配置文件优先级

```
/etc/sysctl.d/*.conf     >  /etc/sysctl.conf
(高优先级)                  (低优先级)

99-disable-ipv6.conf     会覆盖     sysctl.conf 中的设置
```

### 4. 为什么需要内核启动参数？

**sysctl 方法的局限**：
- 在 IPv6 模块加载后才生效
- 某些系统组件可能在 IPv6 禁用前已初始化

**内核参数方法**：
```bash
GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 ..."
```
- 在内核启动时就禁用 IPv6
- 最彻底，不会有任何 IPv6 相关代码运行

---

## 六、执行流程图

### 禁用 IPv6 流程

```
开始
  ↓
创建 /etc/sysctl.d/99-disable-ipv6.conf
  ↓
删除 /etc/sysctl.d/99-enable-ipv6.conf
  ↓
应用 sysctl 配置 (sysctl -p)
  ↓
遍历所有接口
  ↓
对每个接口设置 disable_ipv6=1
  ↓
配置 NetworkManager (不重启!)
  ↓
创建/更新 systemd 服务
  ↓
完成
```

### 启用 IPv6 流程

```
开始
  ↓
删除 99-disable-ipv6.conf
  ↓
清理 /etc/sysctl.conf 中的禁用配置
  ↓
创建 99-enable-ipv6.conf
  ↓
应用 sysctl 配置
  ↓
为所有接口设置 disable_ipv6=0
  ↓
删除 NetworkManager 禁用配置
  ↓
完成
```

### 开机启动流程

```
系统启动
  ↓
网络接口初始化
  ↓
接口获取 IPv6 地址 (默认)
  ↓
network-online.target 达成
  ↓
disable-ipv6.service 执行
  ↓
为所有接口设置 disable_ipv6=1
  ↓
IPv6 地址被移除
  ↓
完成
```

---

## 七、常见问题

### Q1: 为什么配置了但还有 IPv6 地址？

**A**: 可能原因：
1. ❌ 接口在配置前已启动，没有单独设置
2. ✅ 解决：遍历所有接口逐个设置
3. ✅ 验证：检查具体接口的 disable_ipv6 值

**验证步骤**：
```bash
# 1. 检查全局配置
sysctl net.ipv6.conf.all.disable_ipv6

# 2. 检查具体接口
sysctl net.ipv6.conf.wlp1s0.disable_ipv6

# 3. 检查地址
ip -6 addr show
```

### Q2: 为什么启用 IPv6 后地址不完整？

**A**: 需要 NetworkManager 重新获取 IPv6 地址。

**原因**：
- 禁用 IPv6 时，所有 IPv6 地址被移除
- 启用 IPv6 后，sysctl 设置允许 IPv6
- 但 NetworkManager 需要重新获取地址（SLAAC/DHCPv6）
- 不重启 NetworkManager 只能获取 link-local 地址

**解决**：
- ✅ 脚本在启用 IPv6 时自动重启 NetworkManager
- ✅ 等待 3 秒让 IPv6 地址分配完成
- ✅ 可以获取完整的全球单播地址（如 2408: 开头）

### Q3: 重启 NetworkManager 后 IPv6 又回来了？

**A**: 修改所有已存在的连接配置。

**原因**：
```
旧方案：
  创建 /etc/NetworkManager/conf.d/no-ipv6.conf  ✅
  只影响新连接
  已存在的 WiFi 连接保持 ipv6.method=auto    ❌
  重启 NetworkManager 后 IPv6 重新启用

新方案：
  创建全局配置                              ✅
  修改所有已存在连接：ipv6.method=disabled  ✅
  重启 NetworkManager 后 IPv6 保持禁用       ✅
```

### Q4: 如何验证是否真正禁用？

**A**: 三步验证：
```bash
# 1. 检查配置
sysctl net.ipv6.conf.all.disable_ipv6

# 2. 检查具体接口
sysctl net.ipv6.conf.wlp1s0.disable_ipv6

# 3. 检查地址
ip -6 addr show
```

### Q5: 重启后失效怎么办？

**A**: 检查 systemd 服务：

```bash
# 检查服务状态
systemctl status disable-ipv6.service

# 如果未启用，启用它
sudo systemctl enable disable-ipv6.service
sudo systemctl start disable-ipv6.service
```

或者添加内核启动参数（最彻底）：
```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
sudo update-grub
sudo reboot
```

### Q6: 想临时启用 IPv6 怎么办？

**A**: 使用脚本或手动设置：

```bash
# 方法 1: 使用脚本
sudo /home/baby/www/service/network/ipv6-manager.sh
# 选择 1 - 启用 IPv6

# 方法 2: 手动启用
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||; s|/disable_ipv6||')
    if [ "$name" != "all" ] && [ "$name" != "default" ]; then
        sudo sysctl "net.ipv6.conf.$name.disable_ipv6=0"
    fi
done
```

---

## 八、文件位置总结

| 文件 | 作用 |
|------|------|
| `/home/baby/www/service/network/ipv6-manager.sh` | IPv6 管理主脚本 |
| `/etc/sysctl.d/99-disable-ipv6.conf` | 禁用 IPv6 的持久化配置 |
| `/etc/sysctl.d/99-enable-ipv6.conf` | 启用 IPv6 的持久化配置 |
| `/etc/NetworkManager/conf.d/no-ipv6.conf` | NetworkManager IPv6 配置 |
| `/usr/local/sbin/disable-ipv6-network.sh` | systemd 服务执行脚本 |
| `/etc/systemd/system/disable-ipv6.service` | systemd 服务配置文件 |
| `/proc/sys/net/ipv6/conf/*/disable_ipv6` | 运行时 IPv6 状态 |
| `/etc/sysctl.conf` | 传统 sysctl 配置文件 |

---

## 九、调试技巧

### 查看 IPv6 状态详细信息

```bash
# 查看所有接口的 IPv6 禁用状态
for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    name=$(echo "$iface" | sed 's|/proc/sys/net/ipv6/conf/||; s|/disable_ipv6||')
    val=$(cat "$iface")
    printf "%-20s = %s\n" "$name" "$val"
done

# 查看哪些接口有 IPv6 地址
ip -6 addr show | grep -E "^[0-9]+:|inet6"

# 查看 systemd 服务日志
journalctl -u disable-ipv6.service -b
```

### 手动测试 systemd 服务

```bash
# 手动运行服务脚本
sudo bash /usr/local/sbin/disable-ipv6-network.sh

# 检查服务是否配置正确
systemd-analyze verify disable-ipv6.service

# 查看服务依赖
systemctl list-dependencies disable-ipv6.service
```

---

## 十、总结

### 核心要点

1. **`net.ipv6.conf.all.disable_ipv6 = 1` 不会自动影响已存在的接口**
2. **必须遍历接口逐个设置 `disable_ipv6=1`**
3. **不要重启 NetworkManager**，避免接口重新初始化
4. **使用 systemd 服务**确保开机自动禁用 IPv6
5. **配置文件持久化**确保重启后配置保留

### 最佳实践

- ✅ 使用 ipv6-manager.sh 脚本简化操作
- ✅ 启用 disable-ipv6.service 自动处理启动
- ✅ 验证具体接口的 disable_ipv6 值
- ✅ 不要依赖 `all` 配置自动应用
- ✅ 内核参数是最彻底的解决方案

### 适用场景

| 场景 | 推荐方案 |
|------|---------|
| 日常使用 | ipv6-manager.sh + systemd 服务 |
| 服务器 | 内核启动参数 ipv6.disable=1 |
| 临时禁用 | 手动 sysctl 设置 |
| 了解原理 | 手动配置 + systemd 服务 |
