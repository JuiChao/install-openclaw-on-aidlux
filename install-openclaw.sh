#!/bin/bash
set -e

# 0. 预检查：确保以普通用户身份运行
if [ $(id -u) -eq 0 ]; then
  echo "错误：请以普通用户身份直接执行（不要加 sudo），脚本内部会自动按需请求权限。"
  exit 1
fi

# 记录当前普通用户，供后续 AidLux 系统级自启引导使用
CURRENT_USER=$(whoami)

echo "[1/7] 补全系统级依赖 (Git, Node, 及 C++ 原生编译工具链)..."
sudo apt-get update -y
# 终极修复：加入 build-essential python3 等，用于编译 sqlite 等底层二进制模块
sudo apt-get install -y git curl procps psmisc lsof build-essential python3 make gcc g++
if ! command -v npm &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

echo "[2/7] 部署系统环境仿真 (systemctl & loginctl)..."
# 部署 systemctl 仿真器 (骗过环境检查，但我们会在网关启动时强制绕过它以防死循环)
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

# 注入 Error 13 网络环境修复补丁
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

# 提取 NPM 全局安装路径，防止开机自启时找不到环境变量
NPM_BIN_PATH=$(npm config get prefix 2>/dev/null)/bin
export PATH=$PATH:/usr/local/bin:/usr/bin:/opt/node/bin:$NPM_BIN_PATH

echo "[4/7] 配置插件编译隔离环境..."
mkdir -p "$WORK_DIR/cache/jiti"

echo "[5/7] 正在安装与配置 OpenClaw 核心程序..."
# 清理由于之前崩溃可能留下的损坏缓存，并强制洗白权限
sudo npm cache clean --force 2>/dev/null || true
sudo chown -R $CURRENT_USER:$CURRENT_USER ~/.npm 2>/dev/null || true

# 终极修复：使用 sudo -E 以继承我们在第 3 步设置的 NODE_OPTIONS，防止 NPM 安装时因为被剥夺内存限额而触发 OOM 强杀！
sudo -E npm install -g openclaw@latest

# 获取绝对路径，彻底消灭 AidLux 启动时的环境变量“黑洞”
NODE_BIN=$(which node)
OPENCLAW_BIN=$(which openclaw || echo "$NPM_BIN_PATH/openclaw")

# 强制洗白权限：消除由之前 sudo 遗留的隐性权限阻断问题
sudo chown -R $CURRENT_USER:$CURRENT_USER ~/.openclaw 2>/dev/null || true
sudo chown -R $CURRENT_USER:$CURRENT_USER ~/.openclaw-aidlux 2>/dev/null || true

echo "[6/7] 构建本地监控守护脚本 (Watcher)..."
cat << EOF > "$WATCHER_PATH"
#!/bin/bash
export NODE_OPTIONS="\$NODE_OPTIONS"
export JITI_CACHE="$WORK_DIR/cache/jiti"
export PATH=\$PATH:/usr/local/bin:/usr/bin:/opt/node/bin:$NPM_BIN_PATH

# 修复：通过环境变量传递端口，绕过 2026.4 严格的 CLI 参数校验 (--port)
export PORT=18789
export OPENCLAW_PORT=18789

while true; do
    # 日志文件超过 5MB 自动截断清空
    [ \$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 5242880 ] && > "$LOG_FILE"
    echo "\$(date): [Watcher] Booting Gateway in FOREGROUND..." >> "$LOG_FILE"
    
    # 修复：放弃无权限的 lsof，改用进程名“靶向猎杀”，解决 PID 僵尸霸占端口问题
    pkill -15 -f "openclaw gateway" 2>/dev/null || true
    sleep 2
    pkill -9 -f "openclaw gateway" 2>/dev/null || true
    
    # 修复：全局粉碎幽灵锁文件 (Ghost Lock)，防止旧版非正常死亡导致新版拒载
    find ~/.openclaw -name "*.lock" -type f -delete 2>/dev/null || true
    find ~/.openclaw -name "*.pid" -type f -delete 2>/dev/null || true

    # 修复：缓冲 3 秒，缓解 AidLux 设备瞬间 CPU 峰值导致的 Event Loop Delay 崩溃
    sleep 3

    # 修复：使用绝对路径 + 去掉 start 参数，强制网关在“前台”运行，避免触发虚假 systemctl 导致闪退死循环
    $NODE_BIN $OPENCLAW_BIN gateway >> "$LOG_FILE" 2>&1 &
    MAIN_PID=\$!
    wait \$MAIN_PID
    
    # 退出时清理子进程组
    pkill -P \$MAIN_PID 2>/dev/null || true
    sleep 10
done
EOF
chmod +x "$WATCHER_PATH"

echo "[7/7] 配置系统自启并启动服务..."
# 禁用移动端不稳定的 mDNS 发现
openclaw config set gateway.mdns.enabled false 2>/dev/null || true

# 配置 Aidlux 系统自启引导（自动降权）
# 使用 tee + 去除 EOF 引号，确保 $CURRENT_USER 变量能够落盘为真实用户名
cat << EOF | sudo tee /etc/aidlux/autostart_openclaw.sh > /dev/null
#!/bin/bash
exec > /tmp/aidlux_boot.log 2>&1
echo "======================================"
echo "[\$(date)] AidLux 触发自启引导..."
sleep 20
echo "[\$(date)] 延迟结束，拉起用户 $CURRENT_USER 的网关..."
su - $CURRENT_USER -c "setsid $WATCHER_PATH >/dev/null 2>&1 &"
echo "[\$(date)] 拉起命令已发送。"
echo "======================================"
EOF
sudo chmod +x /etc/aidlux/autostart_openclaw.sh

# 清理当前环境的所有残骸，确保全新拉起
openclaw gateway stop --force 2>/dev/null || true
pkill -9 -f "openclaw gateway" 2>/dev/null || true
pkill -f "watcher.sh" 2>/dev/null || true

# 开启终极守护
setsid "$WATCHER_PATH" >/dev/null 2>&1 &

echo "------------------------------------------------"
echo "部署完成！全套兼容补丁及 OOM 防杀机制已就绪。"
echo "网关已在后台静默运行。正在进入初始化向导..."
echo "------------------------------------------------"
sleep 4
openclaw onboard
