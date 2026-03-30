# OpenClaw on AidLux 自动化部署与环境修复脚本

专为 AidLux (Android) 运行环境深度定制的 OpenClaw 一键安装与守护工具。将家里的闲置安卓手机利用起来养龙虾吧。

由于 AidLux 基于 Android 底层，缺失标准的 `systemd` 组件，且存在严格的网络接口权限限制，常规的 Node.js/Linux 程序直接部署常常会遭遇各类报错（如常见的 `Error 13`）。本脚本通过**环境仿真**、**底层 API 动态补丁**以及**独立的进程守护逻辑**，完美实现了 OpenClaw 在 AidLux 上的稳定运行与开机自启。

## ✨ 核心特性

* **Systemd 依赖仿真**：自动生成 `systemctl` 和 `loginctl` 存根，骗过 OpenClaw 初始化时的驻留检查。
* **网络接口权限修复 (Error 13)**：动态注入 Node.js 补丁，接管 `os.networkInterfaces()`，彻底解决 AidLux 下获取网卡信息导致的崩溃问题。
* **内存加固与性能调优**：强制配置 V8 引擎 `--max-old-space-size=2048` (2GB 限制)，优化 JITI 缓存路径，防止移动端 OOM 杀后台；并默认禁用移动端不稳定的 mDNS。
* **高可用进程守护 (Watcher)**：内置轻量级 Watcher 脚本，支持进程崩溃自动拉起、端口 (18789) 冲突自动清理，以及日志体积控制（超过 5MB 自动截断）。
* **AidLux 原生开机自启**：无缝对接 AidLux 底层自启机制 (`/etc/aidlux/autostart_openclaw.sh`)，并严格执行权限降级（以普通用户身份运行服务），保障系统安全。

## 🚀 安装指南

### 前置要求
* 已安装并配置好 AidLux 环境。
* 请务必使用**普通用户**执行脚本，**不要**直接使用 root 或加 `sudo` 运行（脚本内部会在需要时自动请求 sudo 权限）。

### 一键安装

将脚本下载到本地并执行：

```bash
# 1. 下载脚本
curl -O https://raw.githubusercontent.com/JuiChao/install-openclaw-on-aidlux/refs/heads/main/install-openclaw.sh

# 2. 赋予执行权限
chmod +x install-openclaw.sh

# 3. 运行部署脚本
./install-openclaw.sh
```

脚本将自动完成依赖安装、补丁注入、核心程序下载以及自启配置。安装完成后，OpenClaw 网关将在后台静默运行，并自动进入初始化流程。

## 📂 目录结构与工作区

部署完成后，所有运行环境和日志均隔离存放在用户主目录下的 `.openclaw-aidlux` 文件夹中：

```text
~/.openclaw-aidlux/
├── cache/
│   └── jiti/            # Node.js 编译缓存目录
├── network-patch.js     # 网络 API 修复补丁
├── watcher.sh           # 守护进程与启动脚本
└── gateway.log          # 运行日志 (最大 5MB)
```

## 🛠️ 日常维护与命令

* **查看运行日志**：
    ```bash
    tail -f ~/.openclaw-aidlux/gateway.log
    ```
* **手动重启网关服务**：
    由于配置了 Watcher，你可以直接杀掉现有进程，Watcher 会在 10 秒内自动拉起：
    ```bash
    pkill -f "openclaw-gateway"
    ```
* **停止所有服务**：
    ```bash
    pkill -f "openclaw-aidlux/watcher"
    pkill -f "openclaw-gateway"
    ```
* **检查服务进程**：
    ```bash
    ps aux | grep openclaw
    ```

## ⚠️ 注意事项
* 脚本会自动覆盖现有的 `systemctl` 和 `loginctl`（如果存在），原文件会备份为 `.bak`。在 AidLux 环境中这两个命令通常不可用，因此覆盖通常是安全的。
* 默认使用的服务端口为 `18789`，请确保该端口未被其他服务长期占用。
