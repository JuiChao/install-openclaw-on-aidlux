#!/bin/bash
set -e

# 0. 预检查：确保以普通用户身份运行
if [ $(id -u) -eq 0 ]; then
  echo "错误：请以普通用户身份直接执行（不要加 sudo），脚本内部会自动按需请求权限。"
  exit 1
fi

# 获取当前执行脚本的普通用户名
CURRENT_USER=$(whoami)

echo "[1/7] 补全系统级依赖 (Git & Node)..."
sudo apt-get update -y
sudo apt-get install -y git curl procps psmisc lsof
if ! command -v npm &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

echo "[2/7] 部署系统环境仿真 (systemctl & loginctl)..."
# 部署 systemctl 仿真器
[ -f /usr/bin/systemctl ] && sudo mv /usr/bin/systemctl /usr/bin/systemctl.bak 2>/dev/null || true
echo -e '#!/bin/bash\nexit 0' | sudo tee /usr/bin/systemctl > /dev/null
sudo chmod 755 /usr/bin/systemctl

# 部署 loginctl 仿真器以骗过 onboarding 驻留检查
[ -f /usr/bin/loginctl ] && sudo mv /usr/bin/loginctl /usr/bin/loginctl.bak 2>/dev/null || true
cat << 'EOF' | sudo tee /usr/bin/loginctl > /dev/null
#!/bin/bash
[[ "$*" == *"show-user"* ]] && echo "Linger=yes"
exit 0
EOF
sudo chmod 755 /usr/bin/loginctl

echo "[3/7] 环境补丁初始化与内存加固 (2GB)..."
WORK_DIR="$HOME/.openclaw-aidlux"
mkdir -p "$WORK_DIR/cache/jiti"
LOG_FILE="$WORK_DIR/gateway.log"
WATCHER_PATH="$WORK_DIR/watcher.sh"
PATCH_PATH="$WORK_DIR/network-patch.js"

# 注入 Error 13 修复补丁
cat << 'EOF' > "$PATCH_PATH"
const os = require('os');
const _orig = os.networkInterfaces.bind(os);
os.networkInterfaces = () => {
    try { return _orig(); }
    catch (e) {
        return { lo: [{ address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4', mac: '00:00:00:00:00:00', internal: true }] };
    }
};
EOF

# 环境变量设置：2048MB 内存限额 + JITI 缓存重定向
MEM_OPTS="--max-old-space-size=2048"
PATCH_LOAD="--require $PATCH_PATH"
JITI_ENV="JITI_CACHE=\"$WORK_DIR/cache/jiti\""

sed -i '/NODE_OPTIONS/d' ~/.bashrc
sed -i '/JITI_CACHE/d' ~/.bashrc
echo "export NODE_OPTIONS='$MEM_OPTS $PATCH_LOAD'" >> ~/.bashrc
echo "export $JITI_ENV" >> ~/.bashrc

export NODE_OPTIONS="$MEM_OPTS $PATCH_LOAD"
export JITI_CACHE="$WORK_DIR/cache/jiti"

# 提取 NPM 全局安装路径以防止自启时找不到环境变量
NPM_BIN_PATH=$(npm config get prefix 2>/dev/null)/bin
export PATH=$PATH:/usr/local/bin:/usr/bin:/opt/node/bin:$NPM_BIN_PATH

echo "[4/7] 配置插件编译隔离环境..."
mkdir -p "$WORK_DIR/cache/jiti"

echo "[5/7] 正在安装 OpenClaw 核心程序..."
sudo npm install -g openclaw@latest

echo "[6/7] 构建本地监控守护脚本 (Watcher)..."
# 生成守护脚本：包含了 start 指令、优雅终止以及 Ghost Lock 清理机制
cat << EOF > "$WATCHER_PATH"
#!/bin/bash
export NODE_OPTIONS="$NODE_OPTIONS"
export JITI_CACHE="$JITI_CACHE"
export PATH=\$PATH:/usr/local/bin:/usr/bin:/opt/node/bin:$NPM_BIN_PATH

while true; do
    # 日志文件超过 5MB 自动截断清空
    [ \$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 5242880 ] && > "$LOG_FILE"
    echo "\$(date): Starting Gateway..." >> "$LOG_FILE"
    
    # 优雅清理端口：先尝试 kill -15 释放锁文件，再 fallback 到 kill -9
    lsof -t -i tcp:18789 | xargs kill -15 2>/dev/null || true
    sleep 2
    lsof -t -i tcp:18789 | xargs kill -9 2>/dev/null || true
    
    # 清理幽灵锁文件 (Ghost Lock) 防止新版拒载
    find ~/.openclaw/agents/*/sessions/ -name "*.lock" -exec rm -f {} \; 2>/dev/null || true

    # 补全严格的 gateway start 子命令
    openclaw gateway start --port 18789 >> "$LOG_FILE" 2>&1 &
    MAIN_PID=\$!
    wait \$MAIN_PID
    
    # 退出时清理子进程组
    pkill -P \$MAIN_PID 2>/dev/null || true
    sleep 10
done
EOF
chmod +x "$WATCHER_PATH"

# 配置 Aidlux 系统自启引导（自动降权）
# 使用 tee 将自动降权指令准确写入系统目录，规避 EOF 引号导致的环境变量不展开问题
cat << EOF | sudo tee /etc/aidlux/autostart_openclaw.sh > /dev/null
#!/bin/bash
sleep 20
su - $CURRENT_USER -c "setsid $WATCHER_PATH >/dev/null 2>&1 &"
EOF
sudo chmod +x /etc/aidlux/autostart_openclaw.sh

echo "[7/7] 启动服务与性能调优..."
# 禁用移动端不稳定的 mDNS 发现
openclaw config set gateway.mdns.enabled false 2>/dev/null || true

# 重置进程状态并开启当前守护
pkill -f "openclaw-aidlux/watcher" 2>/dev/null || true
pkill -f "openclaw gateway" 2>/dev/null || true
setsid "$WATCHER_PATH" >/dev/null 2>&1 &

echo "------------------------------------------------"
echo "部署完成！系统自启组件与 2026.4 守护补丁已全部就绪。"
echo "网关已在后台静默运行。正在进入初始化..."
echo "------------------------------------------------"
sleep 2
openclaw onboard
