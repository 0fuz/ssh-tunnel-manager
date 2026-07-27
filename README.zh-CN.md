# SSH Tunnel Manager

**简体中文** · [English](README.md)

> 本文档翻译自 [README.md](README.md)，同步于 `9ab8414`。原文更新后此处可能滞后，如有出入请以英文原文为准。

一款轻量级的 macOS 菜单栏应用，用于管理 SSH 端口转发。无需 Electron，无冗余代码 —— 仅采用原生的 Swift 和 AppKit 开发。

<p align="center">
  <img src=".github/menu.png" width="30%" alt="Menu bar with grouped tunnels and per-group toggles">
</p>
<p align="center">
  <img src=".github/settings.png" width="80%" alt="Tunnel settings with a local port forward">
</p>
<p align="center">
  <img src=".github/group.png" width="80%" alt="Grouped tunnels with a divider in the settings sidebar">
</p>

## 为什么需要它？

如果你经常与远程服务器打交道，你可能经常需要 SSH 隧道：
- 数据库访问 (`localhost:5432` → 生产环境 PostgreSQL)
- 内部服务 (`localhost:8080` → 测试环境 API)
- 进入私有网络的 SOCKS 代理 (`ssh -D`)

在终端运行 `ssh -N -L ...` 虽然可行，但存在以下问题：
- 你会忘记哪些隧道正在运行
- 当笔记本电脑睡眠时，隧道会悄悄断开
- 你需要记住每个隧道的精确命令

这款应用解决了这些问题。一次配置，一键连接。

## 功能特性

- **菜单栏应用** — 随时访问，不会在 Dock 中占用空间
- **单个隧道支持多个端口转发** — 一个 SSH 连接，支持多个 `-L` / `-R` 映射
- **SOCKS 代理** — 支持每个映射的动态转发 (`ssh -D`)，可与本地转发混用
- **远程转发** — 通过服务器公开本地服务 (`ssh -R`) —— 一种自托管的外网访问方式
- **跳板机 (Jump host)** — 访问堡垒机背后的主机 (`ssh -J`)，支持多级跳转链
- **隧道分组** — 使用分隔符对隧道进行组织，并可通过一个开关控制整个分组
- **自动重连** — 隧道掉线后会自动重新连接
- **失败原因分析** — 失败或掉线的隧道会显示具体原因（认证失败、连接被拒、不可达、DNS 问题、主机密钥变更、端口被占用），而不仅仅是显示“已断开”
- **连接/断开提醒** — 隧道掉线或恢复时可选择播放声音或发送通知
- **端口冲突守护** — 当两个隧道请求同一个本地端口时会发出警告，防止相互覆盖
- **单隧道精细调优** — 支持 `ConnectTimeout`、保活 (keepalive)、压缩、“在短暂网络中断中维持”、主机密钥选项，以及一个用于填写任何其他 SSH 标志的自由文本框
- **SSH 配置别名** — 复用 `~/.ssh/config` 中的主机配置
- **登录时启动** — Mac 启动时自动启动隧道
- **自动连接** — 可标记某些隧道在应用启动时自动连接
- **原生 macOS** — 使用系统自带的 SSH，不捆绑二进制文件

## 替代方案

| 应用 | 问题 |
|-----|--------|
| **Core Tunnel** | 10 美元，闭源 |
| **Secure Pipes** | 已停止维护（最后更新于 2019 年） |
| **SSH Tunnel Manager (Java)** | 需要 JRE，界面笨重 |
| **Termius** | 订阅制，仅为隧道功能而言过于臃肿 |
| **手动终端** | 无自动重连，容易忘记 |

本应用免费、开源，且专注于做好这一件事。

## 安装

### Homebrew

```bash
brew install --cask 0fuz/tap/ssh-tunnel-manager
```

由于该应用未经过公证 (notarized)，首次启动时请在 `/Applications` 中右键点击并选择“打开”。要跳过此提示，请运行一次以下命令以清除隔离标志：

```bash
xattr -dr com.apple.quarantine /Applications/SSHTunnelManager.app
```

### 直接下载

从 [Releases](../../releases) 下载 `SSHTunnelManager.dmg`。

首次启动时，macOS 会警告该应用未经签名：
1. 右键点击应用 → 打开，或者
2. 系统设置 → 隐私与安全性 → 仍要打开

## 从源码构建

```bash
git clone https://github.com/0fuz/ssh-tunnel-manager.git
cd ssh-tunnel-manager/SSHTunnelManager
xcodebuild -scheme SSHTunnelManager -configuration Release
```

需要 Xcode 15+ 和 macOS 14+。

## 使用方法

1. 点击菜单栏的网络图标
2. 点击 "Settings" 添加隧道
3. 在菜单栏中切换隧道的开启/关闭状态

配置存储在 `~/Library/Application Support/SSHTunnelManager/tunnels.json`。

### SOCKS 代理

将端口映射的类型设置为 **SOCKS** 即可实现动态代理 (`ssh -D`)。将你的浏览器、系统代理或工具指向 `127.0.0.1:<端口>`。当隧道连接后，详情视图的 **Usage** 部分会提供可直接复制的地址以及 `socks5h://` / `socks5://` URL。

当 DNS 应该**在服务器端**解析时（例如访问服务器背后的内部主机名），请使用 `socks5h://`；`socks5://` 则在本地解析 DNS：

```bash
curl -x socks5h://127.0.0.1:1080 http://internal-host:8080
```

<a id="jump-host-bastion"></a>

### 跳板机 (Jump host / Bastion)

当目标主机没有公网路由，且只能通过堡垒机访问时，请将目标主机设为 **Host**，将堡垒机设为 **Jump Host**（在隧道的 *Advanced* 部分）。应用会添加 `ssh -J` 参数，因此登录请求会通过堡垒机路由，而转发仍然针对最终主机 —— 跳板机仅作为登录路径，不参与数据流。

示例 —— 访问只有堡垒机可见的 Postgres 数据库 `db.internal`：

- **Host**: `db.internal`  **Jump Host**: `you@bastion.example.com`
- **Local Forward**: 本地 `127.0.0.1:5432` → 远程 `127.0.0.1:5432`

然后将你的客户端指向 `localhost:5432`。可以使用逗号连接多个跳板机实现多级跳转：`you@bastion,you@inner-gateway`。

### 远程转发 (公开本地服务)

**远程转发** (`ssh -R`) 是本地转发的相反操作：服务器监听一个端口，并将连接发送回你的 Mac —— 这对于通过公网服务器向外界展示本地网站、接收 Webhook 或实现反向 SSH 非常有用。与其它类型一样，**Local** 始终指本台 Mac，**Remote** 指远程服务器。

示例 —— 让本地网站 (`localhost:3000`) 在服务器的公网地址上可访问：

- **Host**: 你的公网服务器
- **Remote Forward**: 本地 `127.0.0.1:3000` → 远程 `0.0.0.0:8080`

现在访问 `http://your-server:8080` 即可到达你 Mac 的 `localhost:3000`。绑定到 `0.0.0.0`（而非服务器自身的回环地址）需要在服务器的 `sshd_config` 中设置 **`GatewayPorts yes`**；否则该端口仅在服务器本地可访问。

### 连接提醒

当隧道连接或意外掉线时，应用可以播放声音和/或显示通知。在 **Preferences**（侧边栏底部的齿轮图标）中进行设置 —— 默认开启声音，关闭通知。手动断开连接和修改配置时不会发出提醒，仅在真实掉线时才会提醒。

通知功能需要 macOS 权限。首次开启 **Show Notifications** 时会弹出权限请求。如果通知仍未出现，请打开 **系统设置 → 通知 → SSH Tunnel Manager** 并确保 **允许通知** 已开启 —— 对于未签名的构建版本，你可能需要手动在此处开启。

### 当隧道无法连接时

失败或掉线的隧道会在菜单栏及其详情视图中显示原因 —— 如认证失败、连接被拒、主机不可达、DNS 问题、主机密钥变更或本地端口被占用 —— 这样你就知道是应该检查密钥、服务器还是网络。该原因会一直保留，直到隧道重新连接或你手动停止。被手动关闭的隧道显示为灰色；红色表示存在真实问题。

两个隧道不能共享同一个本地转发端口。在输入端口时，设置界面会标记冲突；在连接时，第二个隧道会报告端口被占用而不是与第一个隧道竞争 —— 一旦端口释放，它会自动尝试连接。

### 连接选项

每个隧道的详情视图为一些特殊主机提供了几项 SSH 选项：

- **Connect Timeout / Alive Interval / Alive Count** — 连接等待时间，以及在声明连接死亡前探测静默连接的频率。
- **Compression** (`-C`) — 在慢速网络上以 CPU 换带宽。
- **Survive brief network drops** — 在短暂网络中断期间维持隧道 (`TCPKeepAlive=no`)，依赖上述保活探测而非 TCP 级别的连接拆除。
- **Skip host key check** — 用于在相同地址上频繁重建的主机。不安全（禁用主机密钥验证）；默认关闭。
- **Extra SSH options** — 一个自由文本输入框，用于填写 UI 未覆盖的 SSH 参数，例如 `-o ConnectTimeout=5`。将按原样追加到命令末尾（以空格分隔）。
- **Jump Host** (`-J`) — 通过一个或多个堡垒机路由登录以访问目标主机。参见上文 [跳板机 (Jump host / Bastion)](#jump-host-bastion)。

## 许可证

MIT

---

<sub>由 AI 辅助构建并经人工审核 —— 每个变更在发布前均经过测试。</sub>
