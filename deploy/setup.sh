#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Nginx Proxy Manager - Bare-Metal 部署工具
# 适用: Ubuntu 20.04+ / Debian 11+ | 2C1G 低配服务器
# 特性: 交互式菜单 | 端口自定义 | 升级管理 | 健康检查
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ─── 颜色 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── 路径 ──────────────────────────────────────────────────
NPM_DIR="/opt/nginx-proxy-manager"
SCRIPT_DIR="$NPM_DIR/deploy"
NPM_USER="npm"; NPM_GROUP="npm"
DATA_DIR="/data/npm"; LOG_DIR="/var/log/npm"
NGINX_DATA_DIR="/data/nginx"
BACKUP_DIR="/var/backups/npm-$(date +%s)"
NGINX_CONF_DIR="/etc/nginx/npm-conf.d"
NODE_VERSION="22"; SCRIPT_VERSION="2.1.0"
LOG_FILE="/var/log/npm-setup.log"
ENV_FILE="$NPM_DIR/.env"
UPSTREAM_REPO="https://github.com/NginxProxyManager/nginx-proxy-manager.git"
GIT_REPO="https://github.com/zczy-k/nginx-proxy-manager.git"

# ─── 端口默认值 ───────────────────────────────────────────
PORT_HTTP=80; PORT_HTTPS=443; PORT_ADMIN=81; PORT_BACKEND=3000

# ─── 自引导: 如果通过 curl | bash 运行则先克隆仓库 ──────
if [[ ! -f "$SCRIPT_DIR/setup.sh" ]]; then
    echo "==> 正在克隆仓库到 $NPM_DIR ..."
    if ! command -v git &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq git 2>/dev/null || \
            { echo "请先安装 git: apt install git"; exit 1; }
    fi
    rm -rf "$NPM_DIR" 2>/dev/null || true
    git clone --depth 1 "$GIT_REPO" "$NPM_DIR"
    echo "==> 仓库克隆完成，启动部署工具..."
    if [[ $EUID -eq 0 ]]; then
        exec bash "$SCRIPT_DIR/setup.sh" "$@"
    else
        exec sudo bash "$SCRIPT_DIR/setup.sh" "$@"
    fi
fi

# ─── 辅助函数 ─────────────────────────────────────────────
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }
section() { echo -e "\n${BOLD}${WHITE}▶ $1${NC}"; }
spacer()  { echo ""; }

# ─── IP 检测 ─────────────────────────────────────────────
detect_ip() {
    # 尝试多个源获取公网 IP
    SERVER_IP=""
    for src in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        SERVER_IP=$(curl -s --connect-timeout 3 "$src" 2>/dev/null || true)
        [[ -n "$SERVER_IP" ]] && break
    done
    # 回退到局域网 IP
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1)
    fi
    # 最终回退
    SERVER_IP="${SERVER_IP:-服务器IP}"
}

# ─── 防火墙提示 ──────────────────────────────────────────
show_firewall_hint() {
    local ports=($PORT_ADMIN $PORT_HTTP $PORT_HTTPS)
    local port_str=""
    local seen=()
    for p in "${ports[@]}"; do
        [[ " ${seen[*]} " =~ " $p " ]] && continue; seen+=("$p")
        [[ -z "$port_str" ]] && port_str="$p" || port_str="$port_str, $p"
    done

    echo -e "  ${YELLOW}防火墙端口放行提醒:${NC}"
    echo -e "  ${DIM}  请确保以下端口已放行: $port_str${NC}\n"

    if command -v ufw &>/dev/null; then
        for p in "${ports[@]}"; do
            echo -e "    ${BOLD}UFW:${NC} sudo ufw allow $p/tcp"
        done
    fi
    if command -v firewall-cmd &>/dev/null; then
        for p in "${ports[@]}"; do
            echo -e "    ${BOLD}firewalld:${NC} sudo firewall-cmd --add-port=${p}/tcp --permanent"
        done
        echo -e "    ${DIM}    sudo firewall-cmd --reload${NC}"
    fi
    # iptables 作为通用回退
    if ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null; then
        for p in "${ports[@]}"; do
            echo -e "    ${BOLD}iptables:${NC} sudo iptables -A INPUT -p tcp --dport $p -j ACCEPT"
        done
    fi
    # 云服务商提示
    echo -e ""
    echo -e "  ${YELLOW}☁  云服务器额外注意:${NC}"
    echo -e "  ${DIM}  如果使用阿里云/腾讯云/AWS等，还需在云控制台"
    echo -e "  的安全组/防火墙规则中放行对应端口${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        local script="${BASH_SOURCE[0]:-$0}"
        error "请以 root 身份运行: sudo bash $script"
        exit 1
    fi
}

print_banner() {
    clear
    echo -e "${CYAN}"
    echo '  ╔═══════════════════════════════════════════════╗'
    echo '  ║     Nginx Proxy Manager - Bare-Metal         ║'
    echo '  ║     部署工具 v'$SCRIPT_VERSION'                          ║'
    echo '  ╚═══════════════════════════════════════════════╝'
    echo -e "${NC}"
    echo -e "${DIM}  目录: $NPM_DIR${NC}"
    spacer
}

confirm() {
    local prompt=$1; local default=${2:-n}; local yn
    [[ "$default" == "y" ]] && prompt="$prompt [Y/n]" || prompt="$prompt [y/N]"
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt ")" yn || yn=""
    case "$yn" in
        [Yy]*) return 0;;
        [Nn]*) return 1;;
        "") [[ "$default" == "y" ]];;
        *) warn "请输入 y 或 n (默认: $default)"; confirm "$1" "$2";;
    esac
}

read_port() {
    local prompt=$1; local default=$2; local input
    while true; do
        read -r -p "$(echo -e "${YELLOW}?${NC} $prompt [${default}]: ")" input
        input="${input:-$default}"
        if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 ]] && [[ "$input" -le 65535 ]]; then
            echo "$input"; return
        fi
        warn "端口号必须在 1-65535 之间"
    done
}

save_env() {
    mkdir -p "$(dirname "$ENV_FILE")"
    cat > "$ENV_FILE" << ENVEOF
# NPM Bare-Metal 端口配置 (由 setup.sh 自动管理)
PORT_HTTP=$PORT_HTTP
PORT_HTTPS=$PORT_HTTPS
PORT_ADMIN=$PORT_ADMIN
PORT_BACKEND=$PORT_BACKEND
NPM_DIR=$NPM_DIR
DATA_DIR=$DATA_DIR
ENVEOF
    chmod 600 "$ENV_FILE"
    log "配置已保存到 $ENV_FILE"
}

load_env() {
    [[ -f "$ENV_FILE" ]] && . "$ENV_FILE" && \
        info "已加载配置: HTTP=$PORT_HTTP HTTPS=$PORT_HTTPS 管理=$PORT_ADMIN 后端=$PORT_BACKEND"
}

# ═══════════════════════════════════════════════════════════════
# 端口配置
# ═══════════════════════════════════════════════════════════════

configure_ports() {
    header "端口自定义配置"
    echo -e "  ${DIM}可自定义端口以避免与现有服务冲突${NC}\n"
    info "当前: HTTP=$PORT_HTTP HTTPS=$PORT_HTTPS 管理=$PORT_ADMIN 后端=$PORT_BACKEND"
    spacer
    if ! confirm "是否修改端口配置？" "n"; then return; fi
    spacer

    PORT_HTTP=$(read_port "HTTP 代理端口" "$PORT_HTTP")
    PORT_HTTPS=$(read_port "HTTPS 代理端口" "$PORT_HTTPS")
    PORT_ADMIN=$(read_port "管理后台端口" "$PORT_ADMIN")
    PORT_BACKEND=$(read_port "Node.js 后端端口" "$PORT_BACKEND")

    if [[ "$PORT_HTTP" == "$PORT_ADMIN" || "$PORT_HTTP" == "$PORT_HTTPS" \
       || "$PORT_ADMIN" == "$PORT_HTTPS" || "$PORT_BACKEND" == "$PORT_ADMIN" \
       || "$PORT_BACKEND" == "$PORT_HTTP" || "$PORT_BACKEND" == "$PORT_HTTPS" ]]; then
        warn "端口不能重复"; spacer; configure_ports; return
    fi

    info "最终方案: HTTP=$PORT_HTTP HTTPS=$PORT_HTTPS 管理=$PORT_ADMIN 后端=$PORT_BACKEND"
    confirm "确认？" "y" || configure_ports
}

# ═══════════════════════════════════════════════════════════════
# 检测
# ═══════════════════════════════════════════════════════════════

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release; OS_NAME="$ID"; OS_VERSION="$VERSION_ID"
    else
        OS_NAME=$(uname -s); OS_VERSION=$(uname -r)
    fi
    info "系统: $OS_NAME $OS_VERSION"
    if [[ "$OS_NAME" != "ubuntu" && "$OS_NAME" != "debian" ]]; then
        warn "本脚本支持 Ubuntu/Debian，当前系统为 $OS_NAME"
        confirm "是否继续？" "n" || exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in x86_64|aarch64) info "架构: $ARCH ✓";; *) warn "架构: $ARCH (可能不兼容)";; esac
}

detect_existing_npm() {
    if systemctl is-enabled npm-backend &>/dev/null 2>&1; then warn "发现系统服务 (npm-backend)"; return 0; fi
    if [[ -f /etc/systemd/system/npm-backend.service ]]; then warn "发现旧服务文件"; return 0; fi
    if [[ -d "$NGINX_CONF_DIR" ]]; then warn "发现 Nginx 配置目录"; return 0; fi
    if [[ -f "$DATA_DIR/database.sqlite" ]]; then warn "发现数据库文件"; return 0; fi
    if pgrep -f "node.*index.js" | grep -q "nginx-proxy-manager" 2>/dev/null; then warn "发现运行中的后端进程"; return 0; fi
    return 1
}

detect_port_conflicts() {
    local ports=($PORT_HTTP $PORT_HTTPS $PORT_ADMIN $PORT_BACKEND)
    local has_conflict=false; local seen=()
    header "端口冲突检测"
    for port in "${ports[@]}"; do
        [[ " ${seen[*]} " =~ " $port " ]] && continue; seen+=("$port")
        local pid; pid=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
        if [[ -n "$pid" ]]; then
            local proc; proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "未知")
            warn "端口 $port 被占用 (PID: $pid, $proc)"; has_conflict=true
        else info "端口 $port: 空闲"; fi
    done
    $has_conflict && return 0 || return 1
}

detect_nginx_conflicts() {
    header "Nginx 配置检测"
    if command -v nginx &>/dev/null; then
        local sites; sites=$(find /etc/nginx/sites-enabled/ -maxdepth 1 \( -type l -o -type f \) 2>/dev/null | wc -l)
        info "Nginx 已安装，$sites 个站点启用"
        grep -r "npm-conf\|/data/nginx" /etc/nginx/ &>/dev/null 2>&1 && warn "配置含 NPM 残留"
        nginx -t 2>/dev/null || warn "Nginx 配置有语法错误"
    else info "Nginx 未安装 (将自动安装)"; fi
}

# ═══════════════════════════════════════════════════════════════
# 冲突解决
# ═══════════════════════════════════════════════════════════════

resolve_port_conflicts() {
    local ports=($PORT_HTTP $PORT_HTTPS $PORT_ADMIN $PORT_BACKEND)
    local resolved=false; local seen=()
    section "端口冲突自动解决"
    warn "自动停用占用进程将影响该服务提供的所有功能，请确认"
    if ! confirm "确认要自动停用占用进程？" "n"; then
        info "已取消，请手动调整端口或停止占用服务"; return 1
    fi
    for port in "${ports[@]}"; do
        [[ " ${seen[*]} " =~ " $port " ]] && continue; seen+=("$port")
        local pid; pid=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)
        [[ -z "$pid" ]] && continue
        local unit
        unit=$(systemctl status "$pid" 2>/dev/null | grep -oP '● \K[^. ]+' | head -1 || true)
        if [[ -n "$unit" ]]; then
            # 补全 .service 后缀（旧版 systemd 不自动补全）
            [[ "$unit" != *.* ]] && unit="${unit}.service"
            systemctl stop "$unit" 2>/dev/null || true
            systemctl disable "$unit" 2>/dev/null || true
            resolved=true; log "已停用 $unit，释放端口 $port"
        else
            warn "端口 $port 无法自动释放 (PID:$pid) - 可能不是 systemd 管理的进程"
        fi
    done
    $resolved && return 0 || return 1
}

cleanup_old_install() {
    local force=${1:-false}; local cleaned=false
    section "清理旧安装残留"

    # 停用服务
    if systemctl is-active npm-backend &>/dev/null 2>&1 || [[ -f /etc/systemd/system/npm-backend.service ]]; then
        systemctl stop npm-backend 2>/dev/null || true; systemctl disable npm-backend 2>/dev/null || true
        rm -f /etc/systemd/system/npm-backend.service; systemctl daemon-reload; cleaned=true
        log "已停用并删除 npm-backend 服务"
    fi

    # Docker 容器
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi "nginx-proxy-manager\|npm"; then
        docker stop nginx-proxy-manager 2>/dev/null || true; docker rm nginx-proxy-manager 2>/dev/null || true
        cleaned=true; log "已清理 Docker 容器"
    fi

    # 删除安装目录（仅强制模式）
    if $force; then
        for dir in "$NPM_DIR" "/app/nginx-proxy-manager"; do
            [[ -d "$dir" ]] && rm -rf "$dir" && cleaned=true && log "已删除: $dir"
        done
    fi

    # 删除数据目录
    if [[ -d "$DATA_DIR" ]]; then
        if $force; then rm -rf "$DATA_DIR"; cleaned=true; log "已删除数据: $DATA_DIR"
        else confirm "删除数据目录 $DATA_DIR？" "n" && rm -rf "$DATA_DIR" && cleaned=true && log "已删除数据" || true; fi
    fi

    # 删除 Nginx 配置
    if [[ -d "$NGINX_CONF_DIR" ]]; then
        rm -rf "$NGINX_CONF_DIR"; cleaned=true; log "已清理 Nginx 配置"
    fi
    sed -i '/npm-conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true

    # 删除日志
    if [[ -d "$LOG_DIR" ]]; then
        $force && rm -rf "$LOG_DIR" && log "已删除日志" || true
    fi

    $cleaned && log "旧安装已完全清理" || info "无残留"
}

# ═══════════════════════════════════════════════════════════════
# 安装
# ═══════════════════════════════════════════════════════════════

install_deps() {
    section "安装系统依赖"
    apt-get update -qq
    # 系统包推荐安装 (包括 certbot 所需的推荐依赖)
    apt-get install -y \
        nginx certbot python3 python3-certbot-nginx \
        git curl jq logrotate ca-certificates sqlite3 lsof > /dev/null
    log "系统依赖安装完成"
}

install_nodejs() {
    section "安装 Node.js $NODE_VERSION"
    if command -v node &>/dev/null; then
        local ver; ver=$(node --version)
        if [[ "$ver" =~ v([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -ge 18 ]]; then
            log "Node.js $ver ✓"; return
        fi
        info "当前 $ver，升级到 $NODE_VERSION ..."
    fi
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - > /dev/null
    apt-get update -qq > /dev/null
    apt-get install -y nodejs > /dev/null
    log "Node.js $(node --version) 安装完成"
}

create_user() {
    section "创建运行用户"
    id -u "$NPM_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin -d "$NPM_DIR" "$NPM_USER"
    # 确保 NPM_DIR 下所有文件归 NPM_USER 所有（用户用 root git clone 后会产生 root-owned 文件）
    if [[ -d "$NPM_DIR" ]]; then
        chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR" 2>/dev/null || true
    fi
    info "用户 $NPM_USER ✓ (权限已调整)"
}

install_node_deps() {
    section "安装 Node.js 依赖 (精简版)"
    cd "$NPM_DIR/backend"
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm install --no-audit --no-fund" &
    local pid=$!; echo -ne "${DIM}  安装中 ...${NC}"
    while kill -0 "$pid" 2>/dev/null; do echo -n "."; sleep 1; done
    echo -e " ${GREEN}done${NC}"
    wait "$pid" || { error "npm install 失败"; return 1; }

    if confirm "移除 MySQL/PostgreSQL 驱动以节省内存？" "y"; then
        su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm uninstall mysql2 pg sqlite3 --no-audit --no-fund" 2>/dev/null || true
        log "已移除多余 DB 驱动"
    fi

    # ─── 后端端口 patch ───────────────────────────────────
    if [[ "$PORT_BACKEND" -ne 3000 ]]; then
        sed -i "s/app\.listen(3000/app.listen($PORT_BACKEND/" "$NPM_DIR/backend/index.js"
        log "后端端口 → $PORT_BACKEND"
    fi
}

build_frontend() {
    section "构建前端 (管理面板 UI)"

    if [[ -d "$NPM_DIR/frontend/dist" ]] && [[ -f "$NPM_DIR/frontend/dist/index.html" ]]; then
        info "前端已构建 (跳过)"; return 0
    fi

    if [[ "${SKIP_FRONTEND_BUILD:-}" == "1" ]]; then
        warn "已跳过前端构建 (SKIP_FRONTEND_BUILD=1)"
        warn "管理后台将无法访问，需手动: cd $NPM_DIR/frontend && npm install && npm run build"
        return 0
    fi

    cd "$NPM_DIR/frontend"
    info "正在安装前端依赖 (yarn/npm) ..."
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm install --no-audit --no-fund" &
    local pid=$!; echo -ne "${DIM}  安装中 ...${NC}"
    while kill -0 "$pid" 2>/dev/null; do echo -n "."; sleep 2; done
    echo -e " ${GREEN}done${NC}"
    wait "$pid" || { error "前端依赖安装失败"; return 1; }

    info "正在构建前端 (TypeScript + Vite) ..."
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm run build" 2>&1 | tail -20 || {
        error "前端构建失败"; return 1;
    }

    if [[ ! -f "$NPM_DIR/frontend/dist/index.html" ]]; then
        error "前端构建未生成 dist/index.html"; return 1
    fi
    log "前端已构建 → $NPM_DIR/frontend/dist"
}

configure_nginx() {
    section "配置 Nginx 隔离环境"
    # 备份
    mkdir -p "$BACKUP_DIR"; [[ -d /etc/nginx ]] && cp -r /etc/nginx "$BACKUP_DIR/nginx-backup" && log "Nginx 已备份到 $BACKUP_DIR"

    # 前端文件检测
    if [[ ! -f "$NPM_DIR/frontend/dist/index.html" ]]; then
        warn "前端 dist/index.html 不存在，管理后台将无法访问"
        warn "请运行: cd $NPM_DIR/frontend && npm install && npm run build"
        if ! confirm "仍要继续配置 Nginx？" "n"; then
            error "已取消，请先构建前端"; return 1
        fi
        # 创建占位文件避免 Nginx 启动失败
        mkdir -p "$NPM_DIR/frontend/dist"
        cat > "$NPM_DIR/frontend/dist/index.html" <<'EOF'
<!DOCTYPE html>
<html><head><title>NPM - Frontend Not Built</title></head>
<body><h1>Frontend not built</h1><p>Run: cd /opt/nginx-proxy-manager/frontend && npm install && npm run build</p></body>
</html>
EOF
    fi

    mkdir -p "$NGINX_CONF_DIR"
    cat > "$NGINX_CONF_DIR/npm-admin.conf" << NGINX_CONF
server {
    listen ${PORT_ADMIN};
    listen [::]:${PORT_ADMIN};
    server_name _;
    charset utf-8;
    access_log /var/log/npm/admin-access.log;
    error_log /var/log/npm/admin-error.log warn;
    root ${NPM_DIR}/frontend/dist;
    index index.html;

    location / { try_files \$uri \$uri/ /index.html; }

    location /api/ {
        proxy_pass http://127.0.0.1:${PORT_BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${PORT_BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
    location /tokens/ {
        proxy_pass http://127.0.0.1:${PORT_BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_CONF
    log "Nginx 管理面板配置已生成 (端口 $PORT_ADMIN → backend:$PORT_BACKEND)"

    mkdir -p "$NGINX_DATA_DIR"/{custom,proxy_host,redirection_host,stream,dead_host,temp}
    chown -R "$NPM_USER:$NPM_GROUP" "$NGINX_DATA_DIR"

    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ -f "$nginx_conf" ]] && ! grep -q "npm-conf.d" "$nginx_conf" 2>/dev/null; then
        sed -i '/^http {/a\    include /etc/nginx/npm-conf.d/*.conf;' "$nginx_conf"
        if ! grep -q "${NGINX_DATA_DIR}/custom/http_top.conf" "$nginx_conf" 2>/dev/null; then
            sed -i '/^http {/a\    include '"${NGINX_DATA_DIR}"'/custom/http_top.conf;' "$nginx_conf"
        fi
        log "已向 nginx.conf 注入 NPM include"
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null && log "Nginx 重载成功" || warn "Nginx reload 失败，请手动检查"
    else
        warn "Nginx 测试失败，恢复备份..."
        if [[ -d "$BACKUP_DIR/nginx-backup" ]]; then
            cp -r "$BACKUP_DIR/nginx-backup"/* /etc/nginx/ 2>/dev/null || true
            systemctl reload nginx 2>/dev/null || true
        fi
        error "请手动检查 nginx -t"
        return 1
    fi
}

create_data_dirs() {
    section "创建数据目录"
    # 确保父目录存在并设置正确权限
    mkdir -p "$(dirname "$DATA_DIR")" "$(dirname "$NGINX_DATA_DIR")" "$(dirname "$LOG_DIR")"
    mkdir -p "$DATA_DIR" "$LOG_DIR"
    chown -R "$NPM_USER:$NPM_GROUP" "$DATA_DIR" "$LOG_DIR" 2>/dev/null || \
        warn "无法修改 $DATA_DIR 权限，可能已被挂载"
    log "数据: $DATA_DIR | 日志: $LOG_DIR"
}

create_systemd_service() {
    section "创建 systemd 服务"
    local node_bin
    node_bin=$(command -v node || echo "/usr/bin/node")
    cat > /etc/systemd/system/npm-backend.service << SERVICE
[Unit]
Description=Nginx Proxy Manager Backend
Documentation=https://nginxproxymanager.com
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=${NPM_USER}
Group=${NPM_GROUP}
WorkingDirectory=${NPM_DIR}/backend
Environment=NODE_OPTIONS="--max-old-space-size=256"
Environment=NODE_ENV=production
Environment=DB_SQLITE_FILE=${DATA_DIR}/database.sqlite
Environment=DISABLE_IPV6=true
Environment=IP_RANGES_FETCH_ENABLED=false
ExecStart=${node_bin} index.js
ExecReload=/bin/kill -SIGTERM \$MAINPID
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload; log "Systemd 服务已创建 (node: $node_bin)"
}

# ═══════════════════════════════════════════════════════════════
# 健康检查
# ═══════════════════════════════════════════════════════════════

health_check() {
    local all_pass=true
    header "🩺 健康检查"

    # 1. systemd 服务
    echo -ne "  ${BOLD}[服务]${NC} npm-backend  "
    if systemctl is-active npm-backend &>/dev/null; then
        echo -e "${GREEN}● 运行中${NC}"
    elif systemctl is-failed npm-backend &>/dev/null; then
        echo -e "${RED}✗ 失败${NC}"; all_pass=false
    else
        echo -e "${YELLOW}○ 未运行${NC}"; all_pass=false
    fi

    # 2. Nginx
    echo -ne "  ${BOLD}[服务]${NC} nginx       "
    if systemctl is-active nginx &>/dev/null; then
        echo -e "${GREEN}● 运行中${NC}"
    else
        echo -e "${YELLOW}○ 未运行${NC}"; all_pass=false
    fi

    # 3. 端口监听
    local ports=($PORT_ADMIN $PORT_HTTP $PORT_HTTPS $PORT_BACKEND)
    local seen=()
    for port in "${ports[@]}"; do
        [[ " ${seen[*]} " =~ " $port " ]] && continue; seen+=("$port")
        echo -ne "  ${BOLD}[端口]${NC} $port       "
        if ss -tlnp "sport = :$port" 2>/dev/null | grep -q LISTEN; then
            echo -e "${GREEN}监听中${NC}"
        else
            echo -e "${RED}未监听${NC}"; all_pass=false
        fi
    done

    # 4. HTTP 响应 (管理后台) - 检查状态码 + 内容
    echo -ne "  ${BOLD}[HTTP]${NC} :$PORT_ADMIN "
    local http_body http_code
    http_body=$(curl -s --connect-timeout 5 "http://127.0.0.1:$PORT_ADMIN" 2>/dev/null || echo "")
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        "http://127.0.0.1:$PORT_ADMIN" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" || "$http_code" == "302" || "$http_code" == "301" ]]; then
        # 二次验证: 响应内容应包含 NPM 标识
        if echo "$http_body" | grep -qi "nginx\|proxy.manager\|<title>"; then
            echo -e "${GREEN}${http_code} (内容有效)${NC}"
        else
            echo -e "${YELLOW}${http_code} (内容异常)${NC}"; all_pass=false
        fi
    else
        echo -e "${RED}${http_code}${NC}"; all_pass=false
    fi

    # 5. 数据库
    local db_file="${DATA_DIR}/database.sqlite"
    echo -ne "  ${BOLD}[数据库]${NC} SQLite    "
    if [[ -f "$db_file" ]]; then
        local db_size; db_size=$(du -h "$db_file" | cut -f1)
        echo -e "${GREEN}存在 ($db_size)${NC}"
    else
        echo -e "${YELLOW}未创建 (首次启动自动生成)${NC}"
    fi

    # 6. Nginx 配置语法
    echo -ne "  ${BOLD}[Nginx]${NC} 语法检查 "
    if nginx -t 2>/dev/null 1>&2; then
        echo -e "${GREEN}通过${NC}"
    else
        echo -e "${RED}失败${NC}"; all_pass=false
    fi

    # 7. Node.js 进程
    echo -ne "  ${BOLD}[进程]${NC} node        "
    if pgrep -f "node.*index.js" | grep -q . 2>/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"; all_pass=false
    fi

    spacer
    if $all_pass; then
        echo -e "  ${GREEN}${BOLD}✔ 所有检查通过，部署状态正常${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}⚠ 部分检查未通过，请查看上方详情${NC}"
        echo -e "  ${DIM}  日志: journalctl -u npm-backend -n 50 --no-pager${NC}"
    fi
    spacer
    $all_pass && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════
# 升级模块
# ═══════════════════════════════════════════════════════════════

upgrade_npm() {
    check_root
    print_banner
    header "升级 Nginx Proxy Manager"

    # 检查是否为 git 仓库
    if [[ ! -d "$NPM_DIR/.git" ]]; then
        error "不是 git 仓库，无法升级。请通过 git clone 安装"
        return 1
    fi

    # 检查是否有未提交的修改
    cd "$NPM_DIR"
    if ! git diff --quiet HEAD 2>/dev/null; then
        warn "检测到本地修改"
        confirm "是否暂存(stash)后继续？" "y" || return 1
        git stash -u 2>/dev/null || true
        log "已暂存本地修改"
    fi

    # 从 origin (用户自己的 fork) 拉取
    info "正在从 origin 拉取更新..."
    if ! git fetch origin 2>&1; then
        error "从 origin 拉取失败，检查网络或仓库权限"
        return 1
    fi

    # 检查是否有更新
    local behind
    behind=$(git rev-list --count HEAD..origin/$(git rev-parse --abbrev-ref HEAD) 2>/dev/null || echo 0)
    if [[ "$behind" -eq 0 ]]; then
        info "当前已是最新 (已同步 origin)"
    else
        info "发现 $behind 个新提交"
        confirm "确认升级？" "y" || return 1
        git merge origin/$(git rev-parse --abbrev-ref HEAD) --no-edit 2>&1 || {
            warn "合并冲突，请手动解决后重试"
            return 1
        }
        log "代码已更新到最新版本"
    fi

    # 同时检查上游 (jc21/nginx-proxy-manager) 用于跨 fork 升级
    if ! git remote get-url upstream &>/dev/null; then
        if confirm "是否添加上游仓库 (jc21) 以便获取官方更新？" "y"; then
            git remote add upstream "$UPSTREAM_REPO"
            log "已添加上游: $UPSTREAM_REPO"
        fi
    fi

    if git remote get-url upstream &>/dev/null; then
        info "正在从 upstream (官方) 检查更新..."
        git fetch upstream 2>&1 || warn "无法从上游获取"
        local upstream_behind
        upstream_behind=$(git rev-list --count HEAD..upstream/develop 2>/dev/null || echo 0)
        if [[ "$upstream_behind" -gt 0 ]]; then
            info "官方上游有 $upstream_behind 个新提交"
            if confirm "合并官方上游更新？" "n"; then
                git merge upstream/develop --no-edit 2>&1 || {
                    warn "合并冲突，请手动解决"
                    return 1
                }
                log "已合并官方上游更新"
            fi
        else
            info "已与官方上游同步"
        fi
    fi

    spacer
    section "重新应用自定义配置"

    # 重新加载环境变量
    load_env

    # 重新安装 Node 依赖
    cd "$NPM_DIR/backend"
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm install --no-audit --no-fund" || true

    # 重新应用后端端口 patch
    if [[ -f "$ENV_FILE" ]]; then
        . "$ENV_FILE"
        if [[ "$PORT_BACKEND" -ne 3000 ]]; then
            sed -i "s/app\.listen(3000/app.listen($PORT_BACKEND/" "$NPM_DIR/backend/index.js"
            log "重新应用后端端口: $PORT_BACKEND"
        fi
    fi

    # 重建前端
    if [[ -d "$NPM_DIR/frontend" ]]; then
        if confirm "重新构建前端？" "y"; then
            cd "$NPM_DIR/frontend"
            su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm install --no-audit --no-fund" 2>/dev/null || true
            su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm run build" 2>&1 | tail -10 && \
                log "前端构建完成" || warn "前端构建失败"
        fi
    fi

    # 重新生成 Nginx 配置
    configure_nginx

    spacer
    section "重启服务"
    systemctl daemon-reload
    systemctl restart npm-backend 2>/dev/null || true
    sleep 2

    info "运行健康检查..."
    health_check

    log "升级流程完成"
}

# ═══════════════════════════════════════════════════════════════
# 卸载
# ═══════════════════════════════════════════════════════════════

uninstall_npm() {
    check_root
    print_banner; load_env
    header "卸载 Nginx Proxy Manager"
    [[ ! -d "$NPM_DIR" ]] && [[ ! -f /etc/systemd/system/npm-backend.service ]] && \
        warn "未检测到 NPM 安装" && return

    spacer
    echo -e "  ${BOLD}1${NC}. 保留数据卸载 (配置/证书/数据库)"
    echo -e "  ${BOLD}2${NC}. 完全卸载 (清除所有)"
    echo -e "  ${BOLD}3${NC}. 取消"
    spacer
    read -r -p "$(echo -e "${YELLOW}?${NC} 请选择 [1-3]: ")" mode
    case "$mode" in
        1) uninstall_keep ;;
        2) uninstall_purge ;;
        3) info "已取消" ; return ;;
        *) warn "无效" ; uninstall_npm ;;
    esac
}

uninstall_keep() {
    confirm "确认保留数据并卸载？" "n" || return
    systemctl stop npm-backend 2>/dev/null || true
    systemctl disable npm-backend 2>/dev/null || true
    rm -f /etc/systemd/system/npm-backend.service; systemctl daemon-reload; log "服务已移除"
    if [[ -d "$NGINX_CONF_DIR" ]]; then
        mkdir -p "$BACKUP_DIR/nginx-conf"; cp -r "$NGINX_CONF_DIR" "$BACKUP_DIR/nginx-conf/"
        rm -rf "$NGINX_CONF_DIR"; log "Nginx 配置已备份到 $BACKUP_DIR/nginx-conf 并移除"
    fi
    sed -i '/npm-conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true
    info "数据保留: $DATA_DIR"; info "安装目录保留: $NPM_DIR"
    log "卸载完成 (保留数据)"
}

uninstall_purge() {
    confirm "确认完全卸载（所有数据将被删除）？" "n" || return
    systemctl stop npm-backend 2>/dev/null || true
    systemctl disable npm-backend 2>/dev/null || true
    rm -f /etc/systemd/system/npm-backend.service; systemctl daemon-reload

    [[ -d "$NPM_DIR" ]] && rm -rf "$NPM_DIR" && log "已删除安装目录"
    rm -rf "$NGINX_CONF_DIR"
    sed -i '/npm-conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true; log "已清理 Nginx 配置"
    [[ -d "$DATA_DIR" ]] && rm -rf "$DATA_DIR" && log "已删除数据"
    [[ -d "$LOG_DIR" ]] && rm -rf "$LOG_DIR" && log "已删除日志"

    confirm "删除 npm 系统用户？" "n" && userdel -r "$NPM_USER" 2>/dev/null || true
    log "完全卸载完成，无残留"
}

# ═══════════════════════════════════════════════════════════════
# 状态
# ═══════════════════════════════════════════════════════════════

show_status() {
    print_banner; load_env; header "NPM 安装状态"
    echo -ne "  后端服务   "; systemctl is-active npm-backend &>/dev/null && echo -e "${GREEN}● 运行中${NC}" || echo -e "${RED}○ 未运行${NC}"
    echo -ne "  Nginx      "; systemctl is-active nginx &>/dev/null && echo -e "${GREEN}● 运行中${NC}" || echo -e "${RED}○ 未运行${NC}"
    echo -ne "  Node.js    "; command -v node &>/dev/null && echo -e "${GREEN}$(node --version)${NC}" || echo -e "${RED}未安装${NC}"
    echo -ne "  安装目录   "; [[ -d "$NPM_DIR" ]] && echo -e "${GREEN}$NPM_DIR${NC}" || echo -e "${RED}不存在${NC}"
    echo -ne "  数据目录   "
    if [[ -d "$DATA_DIR" ]]; then local size; size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1); echo -e "${GREEN}$DATA_DIR ($size)${NC}"; else echo -e "${DIM}不存在${NC}"; fi
    spacer; header "端口配置"
    echo -e "  HTTP: ${CYAN}$PORT_HTTP${NC}  HTTPS: ${CYAN}$PORT_HTTPS${NC}  管理: ${CYAN}$PORT_ADMIN${NC}  后端: ${CYAN}$PORT_BACKEND${NC}"
    spacer
    health_check
}

# ═══════════════════════════════════════════════════════════════
# 安装主流程
# ═══════════════════════════════════════════════════════════════

run_install() {
    check_root
    print_banner; load_env
    header "Nginx Proxy Manager 安装向导"
    info "本工具将自动补全缺失依赖，在不干扰现有服务的前提下安装 NPM\n"

    section "第一步: 环境检测"
    detect_os; detect_arch; spacer

    section "第二步: 冲突检测"
    local has_ports=false
    detect_port_conflicts && has_ports=true; detect_nginx_conflicts; spacer

    section "第三步: 端口配置"
    configure_ports; spacer

    if $has_ports; then
        section "第四步: 冲突解决"
        confirm "自动解决端口冲突？" "y" && resolve_port_conflicts || true
        spacer
    fi

    spacer
    echo -e "${BOLD}${WHITE}安装概要:${NC}"
    echo -e "  · 安装目录:    ${CYAN}$NPM_DIR${NC}"
    echo -e "  · 数据目录:    ${CYAN}$DATA_DIR${NC}"
    echo -e "  · 端口:        ${CYAN}HTTP=$PORT_HTTP HTTPS=$PORT_HTTPS 管理=$PORT_ADMIN 后端=$PORT_BACKEND${NC}"
    echo -e "  · 数据库:      ${CYAN}SQLite${NC}"
    spacer; confirm "确认开始安装？" "y" || exit 1

    spacer; header "开始安装"

    # 确保 NPM 源码存在（清除旧安装后或首次运行）
    if [[ ! -d "$NPM_DIR/backend" ]]; then
        section "准备 NPM 源码"
        info "未找到源码目录，正在克隆仓库 ..."
        git clone --depth 1 -b develop "$GIT_REPO" "$NPM_DIR" 2>/dev/null || {
            warn "克隆主仓库失败，尝试备用上游 ..."
            git clone --depth 1 -b develop "$UPSTREAM_REPO" "$NPM_DIR" 2>/dev/null || {
                error "克隆失败，请检查网络后重试"; exit 1
            }
        }
        log "NPM 源码已就绪 ($NPM_DIR)"
    fi

    # 自动补齐缺失的系统依赖和 Node.js
    install_deps; install_nodejs; create_user; install_node_deps
    build_frontend
    configure_nginx; create_data_dirs; save_env
    create_systemd_service

    section "启动服务"
    systemctl enable nginx; systemctl start nginx || true
    systemctl enable npm-backend; systemctl start npm-backend || true
    sleep 3
    systemctl is-active npm-backend &>/dev/null && log "后端已启动" || warn "后端启动失败，查看日志: journalctl -u npm-backend -n 30"

    detect_ip
    spacer; header "✅ 部署完成"
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}  管理后台已就绪${NC}"
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e ""
    echo -e "  ${CYAN}${BOLD}  📎 访问地址:${NC}"
    echo -e "  ${WHITE}${BOLD}    http://${SERVER_IP}:${PORT_ADMIN}${NC}"
    echo -e "  ${DIM}    首次访问自动进入初始化设置${NC}"
    echo -e ""
    echo -e "  ${CYAN}${BOLD}  🔌 端口说明:${NC}"
    echo -e "  ${WHITE}    HTTP 代理: ${BOLD}${PORT_HTTP}${NC}"
    echo -e "  ${WHITE}    HTTPS 代理: ${BOLD}${PORT_HTTPS}${NC}"
    echo -e "  ${WHITE}    管理后台: ${BOLD}${PORT_ADMIN}${NC}"
    echo -e ""

    show_firewall_hint
    spacer

    health_check

    spacer
    echo -e "  ${YELLOW}再次运行:${NC} ${BOLD}bash deploy/setup.sh${NC}  进入交互菜单"
    spacer
}

# ═══════════════════════════════════════════════════════════════
# 安装子菜单
# ═══════════════════════════════════════════════════════════════

install_menu() {
    print_banner
    header "安装 Nginx Proxy Manager"
    echo -e "  ${BOLD}1${NC}. 全新安装（检测并清理旧残留后安装）"
    echo -e "  ${BOLD}2${NC}. 强制重装（先完全卸载旧版，清理所有残留，再全新安装）"
    echo -e "  ${BOLD}3${NC}. 返回主菜单"
    spacer
    read -r -p "$(echo -e "${YELLOW}?${NC} 请选择 [1-3]: ")" choice
    case "$choice" in
        1)
            # 全新安装：检测旧版，引导清理
            detect_existing_npm && confirm "检测到旧安装，是否先清理？" "y" && cleanup_old_install false
            run_install
            ;;
        2)
            # 强制重装：不询问直接清除所有
            if confirm "将完全卸载现有版本并删除所有数据，确认？" "n"; then
                warn "正在强制清理所有旧安装..."; spacer
                cleanup_old_install true
                log "旧版已完全清除，开始重新安装"; spacer
                run_install
            else
                info "已取消"; install_menu
            fi
            ;;
        3) main_menu ;;
        *) warn "无效选项"; sleep 1; install_menu ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════════════════════════════

main_menu() {
    print_banner
    echo -e "  ${BOLD}1${NC}. 全新安装 NPM"
    echo -e "  ${BOLD}2${NC}. 卸载 NPM"
    echo -e "  ${BOLD}3${NC}. 升级 NPM"
    echo -e "  ${BOLD}4${NC}. 健康检查"
    echo -e "  ${BOLD}5${NC}. 查看状态"
    echo -e "  ${BOLD}6${NC}. 退出"
    spacer
    read -r -p "$(echo -e "${YELLOW}?${NC} 请选择 [1-6]: ")" choice
    case "$choice" in
        1) install_menu ;;
        2) uninstall_npm ;;
        3) upgrade_npm ;;
        4) health_check ;;
        5) show_status ;;
        6) echo -e "${GREEN}再见!${NC}"; exit 0 ;;
        *) warn "无效选项"; sleep 1; main_menu ;;
    esac
}

handle_args() {
    case "${1:-}" in
        --help|-h)
            echo -e "${CYAN}Nginx Proxy Manager - Bare-Metal 部署工具${NC}"
            echo -e "  ${DIM}用法:${NC} ${BOLD}bash deploy/setup.sh${NC}"
            echo -e "  ${DIM}说明:${NC}  运行后显示交互式菜单，所有操作通过菜单完成${NC}"
            ;;
        *) main_menu ;;
    esac
}

handle_args "$@"
