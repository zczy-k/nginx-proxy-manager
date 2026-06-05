#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Nginx Proxy Manager - Bare-Metal 部署工具
# 适用: Ubuntu 20.04+ / Debian 11+ | 2C1G 低配服务器
# 原则: 不修改上游源码 | 运行时配置 + 系统级包装实现适配
# 用法: curl -fsSL https://raw.githubusercontent.com/zczy-k/nginx-proxy-manager/develop/deploy/setup.sh | sudo bash -s -- install
#   或: curl -fsSL ... | sudo bash                        (交互式菜单)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ─── 管道模式修复 ──────────────────────────────────────────
if [[ ! -t 0 ]]; then
    echo "  检测到管道模式，正在初始化..."
    TMP_SCRIPT="$(mktemp /tmp/npm-setup.XXXXXX.sh)"
    cat > "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"
    exec bash "$TMP_SCRIPT" "$@" </dev/tty
fi

# ─── Root 权限自动提升 ────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "需要 root 权限，正在使用 sudo 重新运行..."
    exec sudo bash "$0" "$@"
fi

# ═══════════════════════════════════════════════════════════════
# 常量与路径
# ═══════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

NPM_DIR="/opt/nginx-proxy-manager"
NPM_USER="npm"; NPM_GROUP="npm"
DATA_DIR="/data/npm"; LOG_DIR="/var/log/npm"
NGINX_DATA_DIR="/data/nginx"
NGINX_CONF_DIR="/etc/nginx/npm-conf.d"
BACKUP_DIR="/var/backups/npm-$(date +%s)"
NODE_VERSION="22"
SCRIPT_VERSION="3.0.0"
ENV_FILE="$NPM_DIR/.env"
UPSTREAM_REPO="https://github.com/NginxProxyManager/nginx-proxy-manager.git"
GIT_REPO="https://github.com/zczy-k/nginx-proxy-manager.git"

# 端口默认值 (后端固定 3000，不修改源码)
PORT_HTTP=80; PORT_HTTPS=443; PORT_ADMIN=81

# ═══════════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════════
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }
section() { echo -e "\n${BOLD}${WHITE}▶ $1${NC}"; }
spacer()  { echo ""; }

spinner() {
    local pid=$1; local msg=$2; local spin='-\|/'
    echo -ne "${DIM}  $msg ...${NC}  "
    while kill -0 "$pid" 2>/dev/null; do
        for i in $(seq 0 3); do echo -ne "\b${spin:$i:1}"; sleep 0.1; done
    done
    local exit_code=0
    wait "$pid" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo -e "\b${GREEN}✓${NC}"
    else
        echo -e "\b${RED}✗${NC}"
    fi
    return $exit_code
}

confirm() {
    local prompt=$1; local default=${2:-n}; local yn
    [[ "$default" == "y" ]] && prompt="$prompt [Y/n]" || prompt="$prompt [y/N]"
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt ")" yn
    case "$yn" in
        [Yy]*) return 0 ;; [Nn]*) return 1 ;;
        "") [[ "$default" == "y" ]] && return 0 || return 1 ;;
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

print_banner() {
    clear
    echo -e "${CYAN}"
    echo '  ╔═══════════════════════════════════════════════╗'
    echo '  ║        Nginx Proxy Manager                    ║'
    echo '  ║        Bare-Metal 部署工具 v'$SCRIPT_VERSION'            ║'
    echo '  ╚═══════════════════════════════════════════════╝'
    echo -e "${NC}"
    echo -e "${DIM}  适用于 2C1G 低配服务器 | 无需 Docker | 不修改上游源码${NC}"
    spacer
}

# ─── 环境配置持久化 ──────────────────────────────────────────
save_env() {
    mkdir -p "$(dirname "$ENV_FILE")"
    cat > "$ENV_FILE" << ENVEOF
# NPM Bare-Metal 配置 (由 setup.sh 自动管理)
PORT_HTTP=$PORT_HTTP
PORT_HTTPS=$PORT_HTTPS
PORT_ADMIN=$PORT_ADMIN
ENVEOF
    chmod 600 "$ENV_FILE"
    log "配置已保存到 $ENV_FILE"
}

load_env() {
    [[ -f "$ENV_FILE" ]] || return 0
    if grep -qE '^\s*[^#]\s*=' "$ENV_FILE" && ! grep -qE '[;&|`$()]' "$ENV_FILE"; then
        . "$ENV_FILE"
        info "已加载配置: HTTP=$PORT_HTTP HTTPS=$PORT_HTTPS 管理=$PORT_ADMIN"
    else
        warn "$ENV_FILE 内容异常，跳过加载"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 检测模块
# ═══════════════════════════════════════════════════════════════
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release; OS_NAME="$ID"; OS_VERSION="$VERSION_ID"
    else
        OS_NAME=$(uname -s); OS_VERSION=$(uname -r)
    fi
    info "系统: $OS_NAME $OS_VERSION"
    if [[ "$OS_NAME" != "ubuntu" && "$OS_NAME" != "debian" ]]; then
        warn "本脚本主要支持 Ubuntu/Debian，你的系统是 $OS_NAME"
        confirm "是否继续？" "n" || exit 1
    fi
}

detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64) info "架构: $arch (支持)" ;;
        *) warn "架构: $arch (可能不兼容)" ;;
    esac
}

detect_existing_npm() {
    local found=false
    [[ -d "$NPM_DIR" ]] && { found=true; warn "发现安装目录: $NPM_DIR"; }
    systemctl is-enabled npm-backend &>/dev/null 2>&1 && { found=true; warn "发现 npm-backend 服务"; }
    pgrep -f "node.*index.js" 2>/dev/null | grep -q "nginx-proxy-manager" && { found=true; warn "发现 NPM 进程"; }
    $found
}

detect_port_conflicts() {
    local ports=($PORT_HTTP $PORT_HTTPS $PORT_ADMIN)
    local has_conflict=false
    local seen=()
    for port in "${ports[@]}"; do
        [[ " ${seen[*]} " =~ " $port " ]] && continue; seen+=("$port")
        local pid
        pid=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1) || true
        if [[ -n "$pid" ]]; then
            local proc; proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "未知")
            warn "端口 $port 已被占用 (PID: $pid, $proc)"; has_conflict=true
        else
            info "端口 $port: 空闲"
        fi
    done
    $has_conflict
}

detect_nginx_conflicts() {
    if command -v nginx &>/dev/null; then
        local sites; sites=$(find /etc/nginx/sites-enabled/ -type l -o -type f 2>/dev/null | wc -l)
        info "Nginx 已安装，$sites 个站点"
        grep -r "npm-conf\|/data/nginx" /etc/nginx/ &>/dev/null && warn "Nginx 配置含 NPM 指令"
        nginx -t 2>/dev/null || warn "Nginx 配置有语法错误"
    else
        info "Nginx 未安装 (将自动安装)"
    fi
}

detect_nodejs() {
    if command -v node &>/dev/null; then
        local ver; ver=$(node --version); info "Node.js: $ver"
        [[ "$ver" =~ v([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -lt 18 ]] && { warn "Node.js 版本过低"; return 1; }
    else
        warn "Node.js 未安装"; return 1
    fi
}

detect_certbot() {
    if command -v certbot &>/dev/null; then
        local n; n=$(certbot certificates 2>/dev/null | grep -c "Certificate Name" || echo 0)
        [[ "$n" -gt 0 ]] && info "Certbot: $n 个证书" || info "Certbot 已安装"
    else
        info "Certbot 未安装 (将自动安装)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 冲突解决
# ═══════════════════════════════════════════════════════════════
resolve_port_conflicts() {
    local ports=($PORT_HTTP $PORT_HTTPS $PORT_ADMIN); local resolved=false
    local seen=()
    for port in "${ports[@]}"; do
        [[ " ${seen[*]} " =~ " $port " ]] && continue; seen+=("$port")
        local pid; pid=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1) || true
        [[ -z "$pid" ]] && continue
        local unit; unit=$(systemctl status "$pid" 2>/dev/null | grep -oP '● \K[^. ]+' | head -1) || true
        if [[ -n "$unit" ]]; then
            systemctl stop "$unit" 2>/dev/null || true
            systemctl disable "$unit" 2>/dev/null || true
            resolved=true; log "已释放端口 $port (停用 $unit)"
        else
            warn "端口 $port 被 PID:$pid 占用，无法自动释放 → kill $pid"
        fi
    done
    $resolved
}

configure_ports() {
    header "端口自定义配置"
    echo -e "  ${DIM}后端 API 端口固定为 3000 (不修改上游源码)${NC}"
    spacer
    echo -e "  HTTP: ${CYAN}$PORT_HTTP${NC}  HTTPS: ${CYAN}$PORT_HTTPS${NC}  管理: ${CYAN}$PORT_ADMIN${NC}"
    spacer
    confirm "是否修改端口？" "n" || { log "使用默认端口"; return; }

    PORT_HTTP=$(read_port "HTTP 代理端口" "$PORT_HTTP")
    PORT_HTTPS=$(read_port "HTTPS 代理端口" "$PORT_HTTPS")
    PORT_ADMIN=$(read_port "管理后台端口" "$PORT_ADMIN")

    if [[ "$PORT_HTTP" == "$PORT_ADMIN" || "$PORT_HTTP" == "$PORT_HTTPS" || "$PORT_ADMIN" == "$PORT_HTTPS" ]]; then
        warn "端口不能相同"; spacer; configure_ports; return
    fi
    spacer
    echo -e "  HTTP: ${CYAN}$PORT_HTTP${NC}  HTTPS: ${CYAN}$PORT_HTTPS${NC}  管理: ${CYAN}$PORT_ADMIN${NC}"
    confirm "确认？" "y" || configure_ports
}

cleanup_old_install() {
    section "清理旧安装"
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi "nginx-proxy-manager" && {
        docker stop nginx-proxy-manager 2>/dev/null || true
        docker rm nginx-proxy-manager 2>/dev/null || true
        log "已清理 Docker 容器"
    }
    [[ -f /etc/systemd/system/npm-backend.service ]] && {
        systemctl stop npm-backend 2>/dev/null || true
        systemctl disable npm-backend 2>/dev/null || true
        rm -f /etc/systemd/system/npm-backend.service
        rm -f /etc/sudoers.d/npm-backend 2>/dev/null || true
        rm -f /etc/logrotate.d/nginx-proxy-manager 2>/dev/null || true
        systemctl daemon-reload; log "已清理 systemd 服务"
    }
    [[ -d "$NGINX_CONF_DIR" ]] && { rm -rf "$NGINX_CONF_DIR"; log "已清理 Nginx 配置"; }
    [[ -d /etc/nginx/conf.d/include ]] && { rm -rf /etc/nginx/conf.d/include; log "已清理 Nginx include 片段"; }
    # 清理 nginx.conf 中残余的 NPM include 注入
    sed -i '/npm-conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i '/http_top\.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i '/data\/nginx\/stream/d' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i '/log-stream\.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
    # 清理旧 wrapper
    dpkg-divert --list 2>/dev/null | grep -q "/usr/sbin/nginx" && {
        rm -f /usr/sbin/nginx; dpkg-divert --remove --rename /usr/sbin/nginx 2>/dev/null || true
        log "已清理旧 Nginx wrapper"
    }
}

# ═══════════════════════════════════════════════════════════════
# 安装模块
# ═══════════════════════════════════════════════════════════════
install_dependencies() {
    section "安装系统依赖"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        nginx certbot python3 python3-venv python3-certbot-nginx \
        git curl jq logrotate ca-certificates sqlite3 lsof sudo \
        build-essential \
        > /dev/null
    log "系统依赖安装完成"

    if [[ ! -f /opt/certbot/bin/activate ]]; then
        python3 -m venv /opt/certbot
        /opt/certbot/bin/pip install --upgrade pip --quiet 2>/dev/null || true
        /opt/certbot/bin/pip install --quiet certbot certbot-nginx 2>/dev/null || true
        log "Certbot venv 已创建 (/opt/certbot/)"
    fi
}

install_nodejs() {
    section "安装 Node.js $NODE_VERSION"
    if command -v node &>/dev/null; then
        local ver; ver=$(node --version); info "Node.js: $ver"
        [[ "$ver" =~ v([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -ge 18 ]] && { log "版本满足"; return; }
        info "版本过低，升级中..."
    fi
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    apt-get install -y nodejs > /dev/null
    log "Node.js $(node --version) 安装完成"
}

create_user() {
    section "创建运行用户"
    if ! id -u "$NPM_USER" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -d "$NPM_DIR" "$NPM_USER"
        log "用户 $NPM_USER 已创建"
    else
        info "用户 $NPM_USER 已存在"
    fi
}

# ─── Nginx Wrapper (核心: 免源码修改方案) ──────────────────────
# 上游 internal/nginx.js 直接调用 /usr/sbin/nginx (不带 sudo)
# Docker 中后端以 root 运行所以无问题，裸机以 npm 用户运行则权限不足
# 解决: dpkg-divert + wrapper 脚本，apt 升级也不会覆盖
install_nginx_wrapper() {
    section "安装 Nginx Wrapper"
    if [[ -f /usr/sbin/nginx.real ]] && dpkg-divert --list 2>/dev/null | grep -q "/usr/sbin/nginx"; then
        head -1 /usr/sbin/nginx 2>/dev/null | grep -q "NPM" && { info "Wrapper 已存在"; return; }
    fi
    dpkg-divert --list 2>/dev/null | grep -q "/usr/sbin/nginx" || {
        dpkg-divert --add --rename --divert /usr/sbin/nginx.real /usr/sbin/nginx
        log "nginx → nginx.real (dpkg-divert)"
    }
    cat > /usr/sbin/nginx << 'WRAPPER'
#!/bin/sh
# NPM Bare-Metal Nginx Wrapper (dpkg-divert 保护)
if [ "$(id -u)" = "0" ]; then
    exec /usr/sbin/nginx.real "$@"
else
    exec sudo -n /usr/sbin/nginx.real "$@"
fi
WRAPPER
    chmod 755 /usr/sbin/nginx
    log "Wrapper 已安装: npm 用户通过 sudo 调用 nginx"
}

clone_project() {
    section "克隆 NPM 源代码"
    if [[ -d "$NPM_DIR" ]] && [[ -f "$NPM_DIR/backend/package.json" ]]; then
        info "项目已存在"; return
    fi
    [[ -d "$NPM_DIR" ]] && { confirm "目录无效，删除重新克隆？" "y" || exit 1; rm -rf "$NPM_DIR"; }
    git clone --depth 1 -b develop "$GIT_REPO" "$NPM_DIR"
    chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR"
    log "源代码克隆完成"
}

install_node_deps() {
    section "安装 Node.js 依赖"
    # 修复 npm 缓存目录权限 (root 运行遗留)
    chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR/.npm" 2>/dev/null || true
    # 使用上游原始 package.json (不修改源码)
    # config.js 未检测到 MySQL/Postgres 环境变量时自动使用 better-sqlite3
    cd "$NPM_DIR/backend"
    info "安装 npm 依赖 ..."
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm install --no-audit --no-fund" &
    spinner $! "npm install" || { error "npm install 失败 (可能缺少编译工具)"; return 1; }
    # 移除不需要的数据库驱动 (--no-save 确保不修改 package.json)
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm uninstall mysql2 pg sqlite3 --no-save --no-audit --no-fund" 2>/dev/null || true
    log "依赖安装完成 (已清理多余 DB 驱动)"
}

build_frontend() {
    section "构建前端 (管理面板)"
    [[ -f "$NPM_DIR/frontend/dist/index.html" ]] && { info "前端已构建"; return 0; }
    [[ "${SKIP_FRONTEND_BUILD:-}" == "1" ]] && {
        warn "跳过前端构建"; warn "需手动: cd $NPM_DIR/frontend && npm run build"; return 0
    }
    # 修复 npm 缓存目录权限 (root 运行遗留)
    chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR/.npm" 2>/dev/null || true
    info "安装前端依赖 ..."
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm install --no-audit --no-fund" &
    spinner $! "npm install (frontend)" || { error "前端依赖安装失败"; return 1; }
    info "构建前端 (在 2C1G 服务器上可能需要 3-5 分钟) ..."
    su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm run build" 2>&1 | tail -20 || {
        error "前端构建失败"; info "可能内存不足，关闭其他服务后重试"; return 1
    }
    [[ -f "$NPM_DIR/frontend/dist/index.html" ]] || { error "未生成 dist/index.html"; return 1; }
    log "前端构建完成"
}

# ─── 从 GitHub Release 下载预构建产物 ─────────────────────────
# 避免在低配服务器上编译前端和原生模块
download_prebuilt() {
    section "下载预构建产物"
    local release_tag="build-latest"
    local api_url="https://api.github.com/repos/${GIT_REPO#*://*/}/releases/tags/${release_tag}"
    # 兼容 https://github.com/user/repo.git 和 https://github.com/user/repo 两种格式
    local repo_path
    repo_path=$(echo "$GIT_REPO" | sed -E 's|https?://github\.com/||; s|\.git$||')
    api_url="https://api.github.com/repos/${repo_path}/releases/tags/${release_tag}"

    info "检查 GitHub Release (${release_tag}) ..."

    # 获取 release 信息
    local release_json
    release_json=$(curl -sL -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null) || {
        warn "无法访问 GitHub API"; return 1
    }

    # 检查是否有效
    if echo "$release_json" | jq -e '.message' &>/dev/null; then
        warn "未找到预构建产物 (${release_tag})"
        return 1
    fi

    # 显示构建信息
    local build_info_url
    build_info_url=$(echo "$release_json" | jq -r '.assets[] | select(.name == "build-info.json") | .browser_download_url' 2>/dev/null)
    if [[ -n "$build_info_url" && "$build_info_url" != "null" ]]; then
        local build_info
        build_info=$(curl -sL "$build_info_url" 2>/dev/null)
        local build_node build_time
        build_node=$(echo "$build_info" | jq -r '.node_version // "unknown"')
        build_time=$(echo "$build_info" | jq -r '.build_time // "unknown"')
        info "构建信息: Node ${build_node} | ${build_time}"

        # 检查 Node.js 版本是否匹配
        local local_node
        local_node=$(node --version 2>/dev/null || echo "none")
        local build_major local_major
        build_major=$(echo "$build_node" | grep -oP 'v\K[0-9]+' || echo "0")
        local_major=$(echo "$local_node" | grep -oP 'v\K[0-9]+' || echo "0")
        if [[ "$build_major" != "$local_major" ]]; then
            warn "Node.js 版本不匹配 (本地: ${local_node}, 构建: ${build_node})"
            warn "原生模块可能不兼容，回退到本地构建"
            return 1
        fi
    fi

    # 下载前端 dist
    local frontend_url
    frontend_url=$(echo "$release_json" | jq -r '.assets[] | select(.name == "frontend-dist.tar.gz") | .browser_download_url' 2>/dev/null)
    if [[ -n "$frontend_url" && "$frontend_url" != "null" ]]; then
        info "下载前端产物 ..."
        curl -sL "$frontend_url" -o /tmp/frontend-dist.tar.gz &
        spinner $! "frontend-dist.tar.gz" || { warn "前端下载失败"; return 1; }
    else
        warn "未找到前端产物"; return 1
    fi

    # 下载后端 node_modules
    local backend_url
    backend_url=$(echo "$release_json" | jq -r '.assets[] | select(.name == "backend-modules.tar.gz") | .browser_download_url' 2>/dev/null)
    if [[ -n "$backend_url" && "$backend_url" != "null" ]]; then
        info "下载后端产物 ..."
        curl -sL "$backend_url" -o /tmp/backend-modules.tar.gz &
        spinner $! "backend-modules.tar.gz" || { warn "后端下载失败"; return 1; }
    else
        warn "未找到后端产物"; return 1
    fi

    # 解压前端
    section "安装预构建产物"
    info "解压前端 ..."
    mkdir -p "$NPM_DIR/frontend/dist"
    tar xzf /tmp/frontend-dist.tar.gz -C "$NPM_DIR/frontend/"
    chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR/frontend/dist"
    log "前端已安装 (预构建)"

    # 解压后端 node_modules
    info "解压后端原生模块 ..."
    tar xzf /tmp/backend-modules.tar.gz -C "$NPM_DIR/backend/"
    chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR/backend/node_modules"
    log "后端依赖已安装 (预构建)"

    # 清理临时文件
    rm -f /tmp/frontend-dist.tar.gz /tmp/backend-modules.tar.gz

    log "预构建产物安装完成"
    return 0
}

create_data_dirs() {
    section "创建数据目录"
    mkdir -p "$DATA_DIR" "$LOG_DIR"
    # 后端硬编码 /data/keys.json，需要 npm 用户可写 /data/
    chown "$NPM_USER:$NPM_GROUP" /data 2>/dev/null || true
    # 后端模板引用的运行时目录
    mkdir -p /data/logs /data/custom_ssl /data/access /data/nginx/default_www
    mkdir -p /data/letsencrypt-acme-challenge
    mkdir -p "$NGINX_DATA_DIR"/{custom,proxy_host,redirection_host,stream,dead_host,temp,default_host}
    chown "$NPM_USER:$NPM_GROUP" /data/logs /data/custom_ssl /data/access /data/letsencrypt-acme-challenge
    chown -R "$NPM_USER:$NPM_GROUP" "$NGINX_DATA_DIR" "$DATA_DIR"
    # 日志目录: npm 后端和 nginx worker (www-data) 都需要写入
    chown "$NPM_USER:www-data" "$LOG_DIR"
    chmod 775 "$LOG_DIR"
    # Let's Encrypt (certbot 需要完整目录权限)
    mkdir -p /etc/letsencrypt/credentials /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal /etc/letsencrypt/accounts
    chown -R "$NPM_USER:$NPM_GROUP" /etc/letsencrypt 2>/dev/null || true
    # certbot 配置文件 (从 Docker rootfs 复制或手动生成)
    if [[ ! -f /etc/letsencrypt.ini ]] || [[ ! -s /etc/letsencrypt.ini ]]; then
        if [[ -f "$NPM_DIR/docker/rootfs/etc/letsencrypt.ini" ]]; then
            cp "$NPM_DIR/docker/rootfs/etc/letsencrypt.ini" /etc/letsencrypt.ini
        else
            cat > /etc/letsencrypt.ini << 'LE_INI'
text = True
non-interactive = True
webroot-path = /data/letsencrypt-acme-challenge
key-type = ecdsa
elliptic-curve = secp384r1
preferred-chain = ISRG Root X1
LE_INI
        fi
        chown "$NPM_USER:$NPM_GROUP" /etc/letsencrypt.ini
    fi
    log "数据目录创建完成"
}

configure_nginx() {
    section "配置 Nginx"
    # 备份
    mkdir -p "$BACKUP_DIR"
    [[ -d /etc/nginx ]] && cp -r /etc/nginx "$BACKUP_DIR/nginx-backup"

    mkdir -p "$NGINX_CONF_DIR"
    # 管理面板配置 (后端固定 3000 端口)
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
        proxy_pass http://127.0.0.1:3000;
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
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
    location /tokens/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_CONF

    # 清理旧版 npm-default.conf (已弃用，变量默认值改由 http_top.conf 的 set 指令提供)
    rm -f "$NGINX_CONF_DIR/npm-default.conf"

    # NPM http 级配置 (变量默认值 + log_format + cache + map)
    # 隔离设计: 仅包含声明式指令，不含 server 块，不影响用户已有配置
    cat > "$NGINX_DATA_DIR/custom/http_top.conf" << 'HTTP_TOP'
# --- NPM Bare-Metal: http-level configuration ---
# Variable defaults (backend-generated proxy hosts override these per-server)
set $server "127.0.0.1";
set $port "80";

# Log formats (used by backend-generated proxy host configs)
log_format proxy '[$time_local] $upstream_cache_status $upstream_status $status - $request_method $scheme $host "$request_uri" [Client $remote_addr] [Length $body_bytes_sent] [Gzip $gzip_ratio] [Sent-to $server] "$http_user_agent" "$http_referer"';
log_format standard '[$time_local] $status - $request_method $scheme $host "$request_uri" [Client $remote_addr] [Length $body_bytes_sent] [Gzip $gzip_ratio] "$http_user_agent" "$http_referer"';

# Proxy cache zones (referenced by conf.d/include/assets.conf)
proxy_cache_path /var/lib/nginx/cache/public  levels=1:2 keys_zone=public-cache:30m  max_size=192m;
proxy_cache_path /var/lib/nginx/cache/private levels=1:2 keys_zone=private-cache:5m max_size=1024m;

# NPM template variables
map $host $forward_scheme { default http; }
map $http_x_forwarded_proto $x_forwarded_proto { "http" "http"; "https" "https"; default $scheme; }
map $http_x_forwarded_scheme $x_forwarded_scheme { "http" "http"; "https" "https"; default $scheme; }

# NPM backend-generated proxy configs
include /data/nginx/default_host/*.conf;
include /data/nginx/proxy_host/*.conf;
include /data/nginx/redirection_host/*.conf;
include /data/nginx/dead_host/*.conf;
include /data/nginx/temp/*.conf;
HTTP_TOP
    chown "$NPM_USER:$NPM_GROUP" "$NGINX_DATA_DIR/custom/http_top.conf"

    # 默认站点 (仅当 sites-enabled 为空时创建，避免与用户已有站点冲突)
    local sites_count=0
    [[ -d /etc/nginx/sites-enabled ]] && sites_count=$(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | wc -l)
    if [[ "$sites_count" -eq 0 ]] && [[ ! -f "$NGINX_DATA_DIR/default_host/site.conf" ]]; then
        cat > "$NGINX_DATA_DIR/default_host/site.conf" << 'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root /var/www/html;
    location / { try_files $uri $uri/ =404; }
}
EOF
        chown "$NPM_USER:$NPM_GROUP" "$NGINX_DATA_DIR/default_host/site.conf"
        log "已创建 NPM 默认站点"
    elif [[ -f "$NGINX_DATA_DIR/default_host/site.conf" ]]; then
        # 修正旧版本遗留的 default_server (会导致 nginx -t 失败)
        if grep -q 'default_server' "$NGINX_DATA_DIR/default_host/site.conf" 2>/dev/null; then
            sed -i 's/ default_server//g' "$NGINX_DATA_DIR/default_host/site.conf"
            log "已移除 default_host/site.conf 中的 default_server"
        fi
    else
        info "sites-enabled 已有 $sites_count 个站点，跳过 NPM 默认站点创建"
    fi

    # 复制 Docker 内置的 nginx include 片段 (conf.d/include/*.conf)
    # 后端模板通过 include conf.d/include/proxy.conf 等引用这些文件
    local include_dir="/etc/nginx/conf.d/include"
    mkdir -p "$include_dir"
    local docker_include_dir="$NPM_DIR/docker/rootfs/etc/nginx/conf.d/include"
    if [[ -d "$docker_include_dir" ]]; then
        for f in "$docker_include_dir"/*.conf; do
            [[ -f "$f" ]] && cp "$f" "$include_dir/"
        done
        log "已复制 Docker nginx include 片段到 $include_dir"
    else
        warn "未找到 Docker include 目录: $docker_include_dir"
    fi
    # 创建空的 resolvers.conf (Docker 启动时动态生成，裸机用占位文件)
    [[ -f "$include_dir/resolvers.conf" ]] || touch "$include_dir/resolvers.conf"
    # 创建空的 ip_ranges.conf (后端运行时填充)
    [[ -f "$include_dir/ip_ranges.conf" ]] || touch "$include_dir/ip_ranges.conf"
    # 创建 nginx cache 目录
    mkdir -p /var/lib/nginx/cache/public /var/lib/nginx/cache/private
    chown -R www-data:www-data /var/lib/nginx/cache 2>/dev/null || true

    # 注入前: 检测与用户已有配置的潜在冲突
    local nc="/etc/nginx/nginx.conf"
    if [[ -f "$nc" ]]; then
        # 检测 map 变量名冲突 (NPM 定义了 map $host $forward_scheme 等)
        local conflict_maps=()
        for var in forward_scheme x_forwarded_proto x_forwarded_scheme; do
            if grep -qE "map\s+\S+\s+\\\$${var}\b" "$nc" 2>/dev/null; then
                conflict_maps+=("\$$var")
            fi
        done
        if [[ ${#conflict_maps[@]} -gt 0 ]]; then
            warn "检测到 map 变量名冲突: ${conflict_maps[*]}"
            warn "NPM 需要在 http 块中定义这些 map，如果您的配置也定义了同名 map，"
            warn "请移除您配置中的定义，NPM 的 map 会自动处理。"
        fi
    fi

    # 注入 include (隔离设计: 仅在 http {} 末尾追加 2 行 include)
    if [[ -f "$nc" ]]; then
        # http 块注入: 在 http {} 末尾 (最后一个 } 之前) 追加 include
        if ! grep -q "npm-conf.d" "$nc" 2>/dev/null; then
            if grep -qE '^\s*http\s*\{' "$nc"; then
                # 使用 awk + 花括号计数精确定位 http {} 结束位置
                awk '
                /^\s*http\s*\{/ { in_http=1; depth=0 }
                in_http {
                    depth += gsub(/{/, "{")
                    depth -= gsub(/}/, "}")
                    if (depth <= 0) {
                        print "    include /data/nginx/custom/http_top.conf;"
                        print "    include /etc/nginx/npm-conf.d/*.conf;"
                        in_http = 0
                    }
                }
                { print }
                ' "$nc" > "${nc}.tmp" && mv "${nc}.tmp" "$nc"
                log "已注入 NPM http include (http 块末尾)"
            else
                warn "未找到 http {} 块，请手动添加 include 指令"
            fi
        fi
        # stream 块: 仅在 stream 块存在且没有自定义 server 时才注入
        # (已有自定义 stream 配置的服务器不应被修改)
        if ! grep -q '/data/nginx/stream' "$nc" 2>/dev/null; then
            if grep -qE '^\s*stream\s*\{' "$nc"; then
                local stream_server_count
                stream_server_count=$(sed -n '/^\s*stream\s*{/,/^}/p' "$nc" | grep -c '^\s*server\s*{' || true)
                if [[ "$stream_server_count" -eq 0 ]]; then
                    sed -i '/^\s*stream\s*{/a\    include /data/nginx/stream/*.conf;' "$nc"
                    log "已注入 NPM stream include"
                else
                    info "stream 块已有 $stream_server_count 个自定义 server，跳过注入"
                    info "如需 NPM TCP/UDP 代理，请手动添加: include /data/nginx/stream/*.conf;"
                fi
            else
                info "nginx.conf 无 stream 块 (跳过 TCP/UDP 代理支持)"
            fi
        fi
    fi

    # nginx 配置测试 (显示完整错误信息便于排查)
    local nginx_test_output
    if nginx_test_output=$(nginx -t 2>&1); then
        systemctl reload nginx
        log "Nginx 配置生效"
    else
        warn "配置测试失败，恢复备份..."
        echo "$nginx_test_output" | while IFS= read -r line; do warn "  $line"; done
        [[ -d "$BACKUP_DIR/nginx-backup" ]] && cp -r "$BACKUP_DIR/nginx-backup"/* /etc/nginx/
        systemctl reload nginx 2>/dev/null || true
    fi
}

create_systemd_service() {
    section "创建 systemd 服务"
    cat > /etc/systemd/system/npm-backend.service << SERVICE
[Unit]
Description=Nginx Proxy Manager Backend
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
ExecStart=/usr/bin/node index.js
Restart=on-failure
RestartSec=5
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
    systemctl daemon-reload
    log "Systemd 服务已创建"
}

configure_sudoers() {
    section "配置权限"
    cat > /etc/sudoers.d/npm-backend << 'SUDOERS'
# NPM: nginx 通过 wrapper 调用 (dpkg-divert)
npm ALL=(ALL) NOPASSWD: /usr/sbin/nginx.real
# NPM: logrotate (setup.js)
npm ALL=(ALL) NOPASSWD: /usr/sbin/logrotate /etc/logrotate.d/nginx-proxy-manager
SUDOERS
    chmod 440 /etc/sudoers.d/npm-backend
    visudo -c &>/dev/null || warn "sudoers 语法异常"
    log "权限配置完成"
}

create_logrotate() {
    cat > /etc/logrotate.d/nginx-proxy-manager << LOGROTATE
/var/log/npm/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $NPM_USER $NPM_GROUP
    sharedscripts
    postrotate
        /usr/sbin/nginx -s reopen 2>/dev/null || true
    endscript
}
LOGROTATE
}

start_services() {
    section "启动服务"
    systemctl enable nginx; systemctl start nginx || true
    systemctl enable npm-backend; systemctl start npm-backend || true
    info "等待后端启动 (首次需执行数据库迁移) ..."
    local waited=0 max_wait=30
    while [[ $waited -lt $max_wait ]]; do
        sleep 2; waited=$((waited + 2))
        systemctl is-active npm-backend &>/dev/null && { log "后端运行中 (${waited}s)"; return; }
        echo -ne "${DIM}  已等待 ${waited}s ...${NC}\r"
    done
    warn "${max_wait}s 内未就绪 (可能仍在迁移中)"
    info "journalctl -u npm-backend -n 50 --no-pager"
}

# ═══════════════════════════════════════════════════════════════
# 安装主流程
# ═══════════════════════════════════════════════════════════════
run_install() {
    print_banner
    header "安装向导"
    info "不修改上游源码，通过 Nginx Wrapper + 运行时配置实现适配"
    spacer
    load_env

    section "环境检测"; detect_os; detect_arch; spacer
    section "冲突检测"
    local has_conflicts=false
    detect_port_conflicts && has_conflicts=true || true
    detect_nginx_conflicts; detect_nodejs || true; detect_certbot; spacer
    section "遗留清理"; detect_existing_npm && confirm "清理旧安装？" "y" && cleanup_old_install; spacer
    section "端口配置"; configure_ports; spacer

    if $has_conflicts; then
        section "冲突解决"; confirm "自动解决端口冲突？" "y" && resolve_port_conflicts || true; spacer
    fi

    spacer
    echo -e "${BOLD}安装概要:${NC}"
    echo -e "  安装目录: ${CYAN}$NPM_DIR${NC}  数据: ${CYAN}$DATA_DIR${NC}"
    echo -e "  HTTP: ${CYAN}$PORT_HTTP${NC}  HTTPS: ${CYAN}$PORT_HTTPS${NC}  管理: ${CYAN}$PORT_ADMIN${NC}  后端: ${DIM}3000${NC}"
    echo -e "  源码修改: ${GREEN}无${NC}  Wrapper: ${GREEN}dpkg-divert${NC}"
    spacer
    confirm "确认安装？" "y" || exit 1

    spacer; header "执行安装"
    install_dependencies
    install_nodejs
    create_user
    clone_project

    # 优先下载预构建产物，失败时回退到本地构建
    if [[ "${FORCE_LOCAL_BUILD:-}" != "1" ]] && download_prebuilt; then
        log "使用预构建产物 (跳过本地编译)"
    else
        warn "回退到本地构建 (在 2C1G 上可能需要 5-10 分钟)"
        install_node_deps || { error "后端依赖安装失败，请检查日志"; exit 1; }
        build_frontend || { error "前端构建失败，安装中止"; exit 1; }
    fi

    create_data_dirs
    configure_nginx
    install_nginx_wrapper
    save_env
    create_systemd_service
    configure_sudoers
    create_logrotate
    start_services

    spacer; header "安装完成"
    echo -e "  ${GREEN}✓${NC} 管理后台: ${CYAN}http://<IP>:${PORT_ADMIN}${NC}"
    echo -e "  ${GREEN}✓${NC} HTTP: ${CYAN}$PORT_HTTP${NC}  HTTPS: ${CYAN}$PORT_HTTPS${NC}"
    echo -e "  ${GREEN}✓${NC} 源码未修改 (可安全 merge 上游)"
    spacer
    echo -e "  ${DIM}bash deploy/setup.sh          # 管理菜单${NC}"
    echo -e "  ${DIM}bash deploy/setup.sh status    # 状态${NC}"
    spacer
}

# ═══════════════════════════════════════════════════════════════
# 卸载
# ═══════════════════════════════════════════════════════════════
uninstall_npm() {
    print_banner; load_env
    header "卸载 Nginx Proxy Manager"
    [[ ! -d "$NPM_DIR" ]] && [[ ! -f /etc/systemd/system/npm-backend.service ]] && { warn "未安装"; return; }
    spacer
    echo -e "  ${BOLD}1${NC}. 保留数据卸载  ${BOLD}2${NC}. 完全卸载  ${BOLD}3${NC}. 取消"
    read -r -p "$(echo -e "${YELLOW}?${NC} 选择 [1-3]: ")" mode
    case "$mode" in
        1) _uninstall_keep ;; 2) _uninstall_purge ;; 3) return ;; *) warn "无效"; uninstall_npm ;;
    esac
}

_uninstall_common() {
    systemctl stop npm-backend 2>/dev/null || true
    systemctl disable npm-backend 2>/dev/null || true
    rm -f /etc/systemd/system/npm-backend.service
    rm -f /etc/sudoers.d/npm-backend 2>/dev/null || true
    rm -f /etc/logrotate.d/nginx-proxy-manager 2>/dev/null || true
    systemctl daemon-reload
    [[ -d "$NGINX_CONF_DIR" ]] && rm -rf "$NGINX_CONF_DIR"
    sed -i '/npm-conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i '/http_top\.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i '/data\/nginx\/stream/d' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i '/log-stream\.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
    [[ -d /etc/nginx/conf.d/include ]] && rm -rf /etc/nginx/conf.d/include
    systemctl reload nginx 2>/dev/null || true
    dpkg-divert --list 2>/dev/null | grep -q "/usr/sbin/nginx" && {
        rm -f /usr/sbin/nginx; dpkg-divert --remove --rename /usr/sbin/nginx 2>/dev/null || true
    }
}

_uninstall_keep() {
    confirm "保留数据并卸载？" "n" || return
    _uninstall_common
    log "已卸载 (数据保留在 $DATA_DIR)"
}

_uninstall_purge() {
    confirm "完全卸载？所有数据将删除！" "n" || return
    _uninstall_common
    [[ -d "$NPM_DIR" ]] && rm -rf "$NPM_DIR"
    [[ -d "$DATA_DIR" ]] && rm -rf "$DATA_DIR"
    [[ -d "$LOG_DIR" ]] && rm -rf "$LOG_DIR"
    confirm "删除 npm 用户？" "n" && userdel -r "$NPM_USER" 2>/dev/null || true
    log "完全卸载完成"
}

# ═══════════════════════════════════════════════════════════════
# 升级
# ═══════════════════════════════════════════════════════════════
upgrade_npm() {
    print_banner; load_env
    header "升级 NPM"
    [[ ! -d "$NPM_DIR" ]] && { warn "未安装"; return; }

    echo -e "  ${BOLD}1${NC}. 从 origin (${GIT_REPO##*/}) 拉取"
    echo -e "  ${BOLD}2${NC}. 从 upstream (官方仓库) 拉取"
    echo -e "  ${BOLD}3${NC}. 取消"
    read -r -p "$(echo -e "${YELLOW}?${NC} 选择 [1-3]: ")" mode

    # 添加 upstream remote (如果不存在)
    cd "$NPM_DIR"
    git remote get-url upstream &>/dev/null || git remote add upstream "$UPSTREAM_REPO"

    local branch="develop"

    # 停止后端 (防止数据库迁移冲突)
    section "停止后端服务"
    systemctl stop npm-backend 2>/dev/null || true
    log "后端已停止"

    case "$mode" in
        1) info "从 origin 拉取..."; git fetch origin "$branch" && git merge "origin/$branch" --no-edit || { error "合并失败"; systemctl start npm-backend 2>/dev/null || true; return 1; } ;;
        2) info "从 upstream 拉取..."; git fetch upstream "$branch" && git merge "upstream/$branch" --no-edit || { error "合并失败"; systemctl start npm-backend 2>/dev/null || true; return 1; } ;;
        3) systemctl start npm-backend 2>/dev/null || true; return ;;
        *) warn "无效"; systemctl start npm-backend 2>/dev/null || true; return ;;
    esac

    section "重新安装依赖"
    # 优先下载预构建产物
    if [[ "${FORCE_LOCAL_BUILD:-}" != "1" ]] && download_prebuilt; then
        log "使用预构建产物 (跳过本地编译)"
    else
        warn "回退到本地构建"
        # 修复 npm 缓存目录权限
        chown -R "$NPM_USER:$NPM_GROUP" "$NPM_DIR/.npm" 2>/dev/null || true
        cd "$NPM_DIR/backend"
        su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm install --no-audit --no-fund" &
        spinner $! "npm install (backend)" || { error "后端依赖安装失败"; systemctl start npm-backend 2>/dev/null || true; return 1; }
        su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/backend' && npm uninstall mysql2 pg sqlite3 --no-save --no-audit --no-fund" 2>/dev/null || true

        section "重新构建前端"
        rm -rf "$NPM_DIR/frontend/dist" 2>/dev/null || true
        su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm install --no-audit --no-fund" &
        spinner $! "npm install (frontend)" || { error "前端依赖安装失败"; systemctl start npm-backend 2>/dev/null || true; return 1; }
        su -s /bin/bash "$NPM_USER" -c "cd '$NPM_DIR/frontend' && npm run build" 2>&1 | tail -10 || { error "前端构建失败"; systemctl start npm-backend 2>/dev/null || true; return 1; }
    fi

    section "重启服务"
    systemctl start npm-backend
    sleep 5
    systemctl is-active npm-backend &>/dev/null && log "升级完成" || warn "后端未就绪，检查日志"
}

# ═══════════════════════════════════════════════════════════════
# 健康检查
# ═══════════════════════════════════════════════════════════════
health_check() {
    print_banner; load_env
    header "健康检查"
    local pass=0 fail=0 total=7

    # 1. systemd 服务
    echo -n "  后端服务:    "
    if systemctl is-active npm-backend &>/dev/null; then echo -e "${GREEN}运行中${NC}"; pass=$((pass + 1))
    else echo -e "${RED}未运行${NC}"; fail=$((fail + 1)); fi

    # 2. Nginx
    echo -n "  Nginx:       "
    if systemctl is-active nginx &>/dev/null; then echo -e "${GREEN}运行中${NC}"; pass=$((pass + 1))
    else echo -e "${RED}未运行${NC}"; fail=$((fail + 1)); fi

    # 3. Wrapper
    echo -n "  Nginx Wrapper: "
    if [[ -f /usr/sbin/nginx.real ]] && dpkg-divert --list 2>/dev/null | grep -q "/usr/sbin/nginx"; then
        echo -e "${GREEN}已安装${NC}"; pass=$((pass + 1))
    else echo -e "${RED}未安装${NC}"; fail=$((fail + 1)); fi

    # 4. 管理端口
    echo -n "  管理端口 $PORT_ADMIN: "
    if ss -tlnp "sport = :$PORT_ADMIN" 2>/dev/null | grep -q LISTEN; then echo -e "${GREEN}监听中${NC}"; pass=$((pass + 1))
    else echo -e "${RED}未监听${NC}"; fail=$((fail + 1)); fi

    # 5. HTTP 响应
    echo -n "  HTTP 响应:   "
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_ADMIN}/" 2>/dev/null) || http_code="000"
    if [[ "$http_code" == "200" ]]; then echo -e "${GREEN}200 OK${NC}"; pass=$((pass + 1))
    else echo -e "${RED}$http_code${NC}"; fail=$((fail + 1)); fi

    # 6. SQLite
    echo -n "  SQLite DB:   "
    if [[ -f "$DATA_DIR/database.sqlite" ]]; then
        local size; size=$(du -sh "$DATA_DIR/database.sqlite" 2>/dev/null | cut -f1)
        echo -e "${GREEN}存在 ($size)${NC}"; pass=$((pass + 1))
    else echo -e "${YELLOW}不存在 (首次启动后创建)${NC}"; pass=$((pass + 1)); fi

    # 7. Nginx 语法
    echo -n "  Nginx 语法:  "
    if nginx -t 2>/dev/null; then echo -e "${GREEN}通过${NC}"; pass=$((pass + 1))
    else echo -e "${RED}错误${NC}"; fail=$((fail + 1)); fi

    spacer
    echo -e "  结果: ${GREEN}$pass/$total 通过${NC}  ${RED}${fail} 失败${NC}"
    [[ $fail -gt 0 ]] && info "journalctl -u npm-backend -n 30 --no-pager"
}

# ═══════════════════════════════════════════════════════════════
# 状态
# ═══════════════════════════════════════════════════════════════
show_status() {
    print_banner; load_env
    header "安装状态"
    echo -ne "  ${BOLD}后端:${NC}      "; systemctl is-active npm-backend &>/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"
    echo -ne "  ${BOLD}Nginx:${NC}     "; systemctl is-active nginx &>/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"
    echo -ne "  ${BOLD}Wrapper:${NC}   "; [[ -f /usr/sbin/nginx.real ]] && echo -e "${GREEN}已安装${NC}" || echo -e "${DIM}未安装${NC}"
    echo -ne "  ${BOLD}Node.js:${NC}   "; command -v node &>/dev/null && echo -e "${GREEN}$(node --version)${NC}" || echo -e "${RED}未安装${NC}"
    echo -ne "  ${BOLD}安装目录:${NC}  "; [[ -d "$NPM_DIR" ]] && echo -e "${GREEN}$NPM_DIR${NC}" || echo -e "${RED}不存在${NC}"
    echo -ne "  ${BOLD}数据目录:${NC}  "; [[ -d "$DATA_DIR" ]] && echo -e "${GREEN}$DATA_DIR ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1))${NC}" || echo -e "${DIM}-${NC}"
    spacer
    header "端口"
    echo -e "  HTTP: ${CYAN}$PORT_HTTP${NC}  HTTPS: ${CYAN}$PORT_HTTPS${NC}  管理: ${CYAN}$PORT_ADMIN${NC}  后端: ${DIM}3000${NC}"
    spacer
    for port in $PORT_HTTP $PORT_HTTPS $PORT_ADMIN 3000; do
        echo -ne "  端口 $port: "
        if ss -tlnp "sport = :$port" 2>/dev/null | grep -q LISTEN; then
            local p; p=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'users:\(\("?\K[^"]+' | head -1)
            echo -e "${YELLOW}$p${NC}"
        else echo -e "${DIM}空闲${NC}"; fi
    done
    spacer; info "journalctl -u npm-backend -n 30 --no-pager"
}

# ═══════════════════════════════════════════════════════════════
# 菜单与入口
# ═══════════════════════════════════════════════════════════════
main_menu() {
    print_banner
    echo -e "  ${BOLD}1${NC}. 安装 NPM"
    echo -e "  ${BOLD}2${NC}. 卸载 NPM"
    echo -e "  ${BOLD}3${NC}. 升级 NPM"
    echo -e "  ${BOLD}4${NC}. 健康检查"
    echo -e "  ${BOLD}5${NC}. 查看状态"
    echo -e "  ${BOLD}6${NC}. 退出"
    spacer
    read -r -p "$(echo -e "${YELLOW}?${NC} 选择 [1-6]: ")" choice
    case "$choice" in
        1) run_install ;;
        2) uninstall_npm ;;
        3) upgrade_npm ;;
        4) health_check ;;
        5) show_status ;;
        6) echo -e "${GREEN}再见!${NC}"; exit 0 ;;
        *) warn "无效选项"; sleep 1; main_menu ;;
    esac
}

case "${1:-}" in
    install|-i)  run_install ;;
    install-local) FORCE_LOCAL_BUILD=1 run_install ;;
    uninstall|-u) uninstall_npm ;;
    upgrade)     upgrade_npm ;;
    health|--health) health_check ;;
    status|-s)   show_status ;;
    --help|-h)
        echo -e "${CYAN}NPM Bare-Metal 部署工具 v${SCRIPT_VERSION}${NC}"
        echo "  curl -fsSL .../setup.sh | sudo bash -s -- install       安装 (优先下载预构建)"
        echo "  curl -fsSL .../setup.sh | sudo bash -s -- install-local 安装 (强制本地编译)"
        echo "  curl -fsSL .../setup.sh | sudo bash                     交互菜单"
        echo "  curl -fsSL .../setup.sh | sudo bash -s -- uninstall     卸载"
        echo "  curl -fsSL .../setup.sh | sudo bash -s -- upgrade       升级"
        echo "  curl -fsSL .../setup.sh | sudo bash -s -- health        健康检查"
        echo "  curl -fsSL .../setup.sh | sudo bash -s -- status        状态"
        ;;
    *) main_menu ;;
esac
