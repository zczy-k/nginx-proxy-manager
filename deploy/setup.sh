#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="4.0.1"
APP_LABEL="Nginx Proxy Manager 裸机部署"
APP_USER="npmbare"
APP_GROUP="npmbare"

INSTALL_ROOT="/opt/npm-bare"
APP_ROOT="$INSTALL_ROOT/app"
SRC_DIR="$APP_ROOT/source"
BIN_DIR="$INSTALL_ROOT/bin"
TOOLS_DIR="$INSTALL_ROOT/tools"
SHIM_DIR="$INSTALL_ROOT/shims"

STATE_ROOT="/var/lib/npm-bare"
RUNTIME_ROOT="$STATE_ROOT/runtime"
RUNTIME_DATA_DIR="$RUNTIME_ROOT/data"
RUNTIME_LE_DIR="$RUNTIME_ROOT/letsencrypt"
RUNTIME_ETC_DIR="$RUNTIME_ROOT/etc"
RUNTIME_NGINX_ETC_DIR="$RUNTIME_ROOT/etc-nginx"
RUNTIME_RUN_DIR="$RUNTIME_ROOT/run"
RUNTIME_WWW_DIR="$RUNTIME_ROOT/www"
APP_HOME="$STATE_ROOT/home"
LOG_ROOT="/var/log/npm-bare"
TMP_ROOT="$STATE_ROOT/tmp"

CONFIG_FILE="$STATE_ROOT/config.env"
ENV_FILE="$STATE_ROOT/runtime.env"
NGINX_REAL_BIN="$TOOLS_DIR/nginx-real"
NODE_ROOT="$TOOLS_DIR/node"
CERTBOT_VENV="$TOOLS_DIR/certbot"

GIT_REPO="https://github.com/zczy-k/nginx-proxy-manager.git"
UPSTREAM_REPO="https://github.com/NginxProxyManager/nginx-proxy-manager.git"
GITHUB_API="https://api.github.com/repos/zczy-k/nginx-proxy-manager"
DEFAULT_REF="build-latest"
DEFAULT_ADMIN_PORT="81"
DEFAULT_NODE_VERSION="22.16.0"

SERVICE_BACKEND="npm-bare-backend.service"
SERVICE_NGINX="npm-bare-nginx.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

COMMAND="${1:-menu}"
shift || true

NONINTERACTIVE=0
FORCE=0
ADMIN_PORT=""
INSTALL_REF=""
INSTALL_MODE=""
NODE_VERSION=""
INITIAL_ADMIN_EMAIL=""
INITIAL_ADMIN_PASSWORD=""
KEEP_DATA=0

log()   { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$*"; }
info()  { printf "%b[i ]%b %s\n" "$BLUE" "$NC" "$*"; }
warn()  { printf "%b[! ]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[x ]%b %s\n" "$RED" "$NC" "$*"; }
die()   { error "$*"; exit 1; }
section() { printf "\n%b%s%b\n" "$BOLD$CYAN" "$*" "$NC"; }

usage() {
    cat <<EOF
$APP_LABEL v$SCRIPT_VERSION

用法:
  setup.sh install [--admin-port PORT] [--ref REF] [--node VERSION] [--yes]
  setup.sh install-local [--admin-port PORT] [--ref REF] [--node VERSION] [--yes]
  setup.sh reinstall [--admin-port PORT] [--ref REF] [--node VERSION] [--yes]
  setup.sh reinstall-local [--admin-port PORT] [--ref REF] [--node VERSION] [--yes]
  setup.sh upgrade [--ref REF] [--node VERSION] [--yes]
  setup.sh status
  setup.sh health
  setup.sh logs
  setup.sh uninstall [--yes] [--keep-data]
  setup.sh help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --admin-port)
                ADMIN_PORT="${2:-}"
                shift 2
                ;;
            --ref)
                INSTALL_REF="${2:-}"
                shift 2
                ;;
            --node)
                NODE_VERSION="${2:-}"
                shift 2
                ;;
            --initial-admin-email)
                INITIAL_ADMIN_EMAIL="${2:-}"
                shift 2
                ;;
            --initial-admin-password)
                INITIAL_ADMIN_PASSWORD="${2:-}"
                shift 2
                ;;
            --yes|--non-interactive)
                NONINTERACTIVE=1
                FORCE=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --keep-data)
                KEEP_DATA=1
                shift
                ;;
            help|-h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done
}

print_banner() {
    clear 2>/dev/null || true
    cat <<EOF
${CYAN}${BOLD}
  Nginx Proxy Manager
  裸机部署器 v${SCRIPT_VERSION}
${NC}
${DIM}私有运行时、私有 nginx 实例、不修改上游源码${NC}
EOF
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "请使用 root 身份运行此脚本"
    fi
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || die "此部署脚本仅支持 Linux"
}

ensure_tty() {
    [[ -r /dev/tty ]]
}

prompt_text() {
    local prompt="$1"
    local default="${2:-}"
    local reply=""
    if [[ $NONINTERACTIVE -eq 1 ]] || ! ensure_tty; then
        printf '%s\n' "$default"
        return 0
    fi
    if [[ -n "$default" ]]; then
        read -r -p "$(printf '%b?%b %s [%s]: ' "$YELLOW" "$NC" "$prompt" "$default")" reply < /dev/tty || true
        printf '%s\n' "${reply:-$default}"
    else
        read -r -p "$(printf '%b?%b %s: ' "$YELLOW" "$NC" "$prompt")" reply < /dev/tty || true
        printf '%s\n' "$reply"
    fi
}

confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local reply=""
    if [[ $FORCE -eq 1 || $NONINTERACTIVE -eq 1 ]] || ! ensure_tty; then
        [[ "$default" == "y" ]]
        return
    fi
    if [[ "$default" == "y" ]]; then
        read -r -p "$(printf '%b?%b %s [Y/n]: ' "$YELLOW" "$NC" "$prompt")" reply < /dev/tty || true
        [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
    else
        read -r -p "$(printf '%b?%b %s [y/N]: ' "$YELLOW" "$NC" "$prompt")" reply < /dev/tty || true
        [[ "$reply" =~ ^[Yy]$ ]]
    fi
}

menu() {
    print_banner
    cat <<EOF
1. 安装（预构建产物，内存占用最低）
2. 安装（本地构建）
3. 重装 / 升级（预构建产物）
4. 重装 / 升级（本地构建）
5. 状态
6. 健康检查
7. 日志
8. 卸载
0. 退出
EOF
    local choice
    choice="$(prompt_text '请选择操作' '1')"
    case "$choice" in
        1) COMMAND="install" ;;
        2) COMMAND="install-local" ;;
        3) COMMAND="reinstall" ;;
        4) COMMAND="reinstall-local" ;;
        5) COMMAND="status" ;;
        6) COMMAND="health" ;;
        7) COMMAND="logs" ;;
        8) COMMAND="uninstall" ;;
        0) exit 0 ;;
        *) die "无效的菜单选项：$choice" ;;
    esac
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    if grep -Eq '[`$()]' "$CONFIG_FILE"; then
        die "拒绝加载不安全的配置文件：$CONFIG_FILE"
    fi
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

save_config() {
    mkdir -p "$STATE_ROOT"
    cat > "$CONFIG_FILE" <<EOF
ADMIN_PORT=$ADMIN_PORT
INSTALL_REF=$INSTALL_REF
INSTALL_MODE=$INSTALL_MODE
NODE_VERSION=$NODE_VERSION
EOF
    chmod 600 "$CONFIG_FILE"
}

write_runtime_env() {
    mkdir -p "$STATE_ROOT"
    local certbot_version="unknown"
    if [[ -x "$CERTBOT_VENV/bin/certbot" ]]; then
        certbot_version="$($CERTBOT_VENV/bin/certbot --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1 || echo unknown)"
    fi
    cat > "$ENV_FILE" <<EOF
ADMIN_PORT=$ADMIN_PORT
INSTALL_REF=$INSTALL_REF
INSTALL_MODE=$INSTALL_MODE
NODE_VERSION=$NODE_VERSION
CERTBOT_VERSION=$certbot_version
EOF
    chmod 600 "$ENV_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_in_root_namespace() {
    local cmd="$1"
    if command_exists systemd-run; then
        systemd-run --quiet --wait --pipe --service-type=exec \
            --property=BindPaths="$RUNTIME_DATA_DIR:/data" \
            --property=BindPaths="$RUNTIME_LE_DIR:/etc/letsencrypt" \
            --property=BindPaths="$RUNTIME_NGINX_ETC_DIR:/etc/nginx" \
            --property=BindPaths="$RUNTIME_RUN_DIR:/run/npm-bare" \
            --property=BindReadOnlyPaths="$RUNTIME_ETC_DIR/letsencrypt.ini:/etc/letsencrypt.ini" \
            /bin/bash -lc "$cmd"
    else
        /bin/bash -lc "$cmd"
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) return 0 ;;
        esac
        die "不支持的发行版：${ID:-unknown}。请使用 Debian 11+ 或 Ubuntu 20.04+"
    fi
    die "无法识别 Linux 发行版"
}

node_arch() {
    case "$(uname -m)" in
        x86_64) printf 'x64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
}

ensure_directories() {
    mkdir -p "$INSTALL_ROOT" "$APP_ROOT" "$BIN_DIR" "$TOOLS_DIR" "$SHIM_DIR"
    mkdir -p "$STATE_ROOT" "$RUNTIME_ROOT" "$APP_HOME" "$LOG_ROOT" "$TMP_ROOT"
    chmod 750 "$INSTALL_ROOT" "$APP_ROOT" "$STATE_ROOT" "$LOG_ROOT"
}

ensure_user() {
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
        groupadd --system "$APP_GROUP"
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        useradd --system --gid "$APP_GROUP" --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
    fi

    # Keep the top-level roots managed by root, but allow the service account to
    # traverse them so it can reach its private runtimes under /opt and /var/lib.
    chown root:"$APP_GROUP" "$INSTALL_ROOT" "$STATE_ROOT"
    chmod 750 "$INSTALL_ROOT" "$STATE_ROOT"

    chown -R "$APP_USER:$APP_GROUP" "$APP_HOME" "$LOG_ROOT" "$TMP_ROOT" "$APP_ROOT"
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

ensure_packages() {
    section "安装系统软件包"

    local nginx_present=0
    local nginx_active=0
    local nginx_enabled=0

    if command_exists nginx; then
        nginx_present=1
        systemctl is-active nginx >/dev/null 2>&1 && nginx_active=1
        systemctl is-enabled nginx >/dev/null 2>&1 && nginx_enabled=1
    fi

    apt_install ca-certificates curl git jq lsof logrotate openssl python3 python3-venv tar xz-utils nginx libnginx-mod-stream

    if [[ $nginx_present -eq 0 ]]; then
        systemctl stop nginx >/dev/null 2>&1 || true
        systemctl disable nginx >/dev/null 2>&1 || true
    elif [[ $nginx_active -eq 0 ]]; then
        systemctl stop nginx >/dev/null 2>&1 || true
        if [[ $nginx_enabled -eq 0 ]]; then
            systemctl disable nginx >/dev/null 2>&1 || true
        fi
    fi

    log "系统软件包已就绪"
}

ensure_build_packages() {
    section "安装本地构建依赖"
    apt_install build-essential pkg-config
    log "本地构建工具链已就绪"
}

ensure_node() {
    section "安装私有 Node.js"
    local arch url tmpfile
    arch="$(node_arch)"
    url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz"
    if [[ -x "$NODE_ROOT/bin/node" ]] && [[ "$($NODE_ROOT/bin/node --version 2>/dev/null || true)" == "v${NODE_VERSION}" ]]; then
        log "Node.js v${NODE_VERSION} 已存在"
        return 0
    fi
    tmpfile="$(mktemp /tmp/npmbare-node.XXXXXX.tar.xz)"
    curl -fsSL "$url" -o "$tmpfile"
    rm -rf "$NODE_ROOT"
    mkdir -p "$NODE_ROOT"
    tar -xJf "$tmpfile" -C "$NODE_ROOT" --strip-components=1
    rm -f "$tmpfile"
    chown -R "$APP_USER:$APP_GROUP" "$NODE_ROOT"
    log "已安装 Node.js v${NODE_VERSION} 到 $NODE_ROOT"
}

ensure_certbot() {
    section "安装私有 Certbot"
    if [[ ! -x "$CERTBOT_VENV/bin/certbot" ]]; then
        rm -rf "$CERTBOT_VENV"
        python3 -m venv "$CERTBOT_VENV"
    fi
    chown -R "$APP_USER:$APP_GROUP" "$CERTBOT_VENV"
    run_as_app "'$CERTBOT_VENV/bin/python' -m pip install --upgrade pip certbot certbot-nginx >/dev/null"
    log "Certbot 环境已就绪"
}

copy_nginx_binary() {
    mkdir -p "$TOOLS_DIR"
    install -m 0755 "$(command -v nginx)" "$NGINX_REAL_BIN"
}

run_as_app() {
    local cmd="$1"
    su -s /bin/bash "$APP_USER" -c "export HOME='$APP_HOME'; export TMPDIR='$TMP_ROOT'; $cmd"
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( "$1" >= 1 && "$1" <= 65535 ))
}

port_in_use() {
    local port="$1"
    ss -ltn "sport = :$port" 2>/dev/null | awk 'NR > 1 { print $4 }' | grep -q .
}

ensure_proxy_ports_free() {
    local ports=(80 443 "$ADMIN_PORT")
    local seen=""
    if [[ "$ADMIN_PORT" == "80" || "$ADMIN_PORT" == "443" ]]; then
        die "管理后台端口不能是 80 或 443"
    fi
    for port in "${ports[@]}"; do
        [[ " $seen " == *" $port "* ]] && continue
        seen+=" $port"
        if port_in_use "$port"; then
            if [[ "$port" == "$ADMIN_PORT" ]]; then
                die "管理后台端口 $ADMIN_PORT 已被占用"
            fi
            die "端口 $port 已被占用。裸机版 NPM 必须独占 80 和 443"
        fi
    done
}

collect_install_settings() {
    local cli_admin_port="$ADMIN_PORT"
    local cli_ref="$INSTALL_REF"
    local cli_mode="$INSTALL_MODE"
    local cli_node_version="$NODE_VERSION"

    ADMIN_PORT="$DEFAULT_ADMIN_PORT"
    INSTALL_REF="$DEFAULT_REF"
    INSTALL_MODE="prebuilt"
    NODE_VERSION="$DEFAULT_NODE_VERSION"

    load_config

    ADMIN_PORT="${cli_admin_port:-$ADMIN_PORT}"
    INSTALL_REF="${cli_ref:-$INSTALL_REF}"
    INSTALL_MODE="${cli_mode:-$INSTALL_MODE}"
    NODE_VERSION="${cli_node_version:-$NODE_VERSION}"

    case "$COMMAND" in
        install|reinstall|upgrade)
            INSTALL_MODE="${cli_mode:-$INSTALL_MODE}"
            ;;
        install-local|reinstall-local)
            INSTALL_MODE="local"
            ;;
    esac

    if [[ $NONINTERACTIVE -eq 0 ]] && ensure_tty; then
        section "部署设置"
        ADMIN_PORT="$(prompt_text '管理后台端口' "$ADMIN_PORT")"
        INSTALL_REF="$(prompt_text '要部署的 Git 引用' "$INSTALL_REF")"
        if [[ "$COMMAND" == "install" || "$COMMAND" == "reinstall" || "$COMMAND" == "upgrade" ]]; then
            local mode_choice
            mode_choice="$(prompt_text '安装模式（prebuilt/local）' "$INSTALL_MODE")"
            case "$mode_choice" in
                prebuilt|local) INSTALL_MODE="$mode_choice" ;;
                *) die "安装模式必须是 prebuilt 或 local" ;;
            esac
        fi
    fi

    validate_port "$ADMIN_PORT" || die "无效的管理后台端口：$ADMIN_PORT"
    [[ -n "$INSTALL_REF" ]] || die "Git 引用不能为空"
    [[ -n "$NODE_VERSION" ]] || die "Node 版本不能为空"
}

clone_source() {
    section "拉取源码"
    rm -rf "$SRC_DIR"
    if ! git clone --depth 1 --branch "$INSTALL_REF" "$GIT_REPO" "$SRC_DIR" >/dev/null 2>&1; then
        git clone --depth 1 "$GIT_REPO" "$SRC_DIR" >/dev/null 2>&1
        (
            cd "$SRC_DIR"
            git fetch --tags origin "$INSTALL_REF" >/dev/null 2>&1
            git checkout "$INSTALL_REF" >/dev/null 2>&1
        )
    fi
    (
        cd "$SRC_DIR"
        git remote remove upstream >/dev/null 2>&1 || true
        git remote add upstream "$UPSTREAM_REPO" >/dev/null 2>&1 || true
    )
    chown -R "$APP_USER:$APP_GROUP" "$SRC_DIR"
    log "已检出 $INSTALL_REF"
}

release_json_for_ref() {
    local ref="$1"
    curl -fsSL "$GITHUB_API/releases/tags/$ref"
}

use_prebuilt_assets() {
    [[ "$INSTALL_MODE" == "prebuilt" ]] || return 1

    local json frontend_url backend_url tmpdir
    if ! json="$(release_json_for_ref "$INSTALL_REF" 2>/dev/null)"; then
        warn "未找到引用 $INSTALL_REF 对应的预构建 release"
        return 1
    fi

    frontend_url="$(printf '%s' "$json" | jq -r '.assets[] | select(.name == "frontend-dist.tar.gz") | .browser_download_url' | head -1)"
    backend_url="$(printf '%s' "$json" | jq -r '.assets[] | select(.name == "backend-modules.tar.gz") | .browser_download_url' | head -1)"

    if [[ -z "$frontend_url" || "$frontend_url" == "null" || -z "$backend_url" || "$backend_url" == "null" ]]; then
        warn "引用 $INSTALL_REF 的预构建产物不完整"
        return 1
    fi

    section "下载预构建产物"
    tmpdir="$(mktemp -d /tmp/npmbare-assets.XXXXXX)"
    curl -fsSL "$frontend_url" -o "$tmpdir/frontend-dist.tar.gz"
    curl -fsSL "$backend_url" -o "$tmpdir/backend-modules.tar.gz"

    rm -rf "$SRC_DIR/frontend/dist" "$SRC_DIR/backend/node_modules"
    tar -xzf "$tmpdir/frontend-dist.tar.gz" -C "$SRC_DIR/frontend"
    tar -xzf "$tmpdir/backend-modules.tar.gz" -C "$SRC_DIR/backend"
    rm -rf "$tmpdir"

    chown -R "$APP_USER:$APP_GROUP" "$SRC_DIR/frontend/dist" "$SRC_DIR/backend/node_modules"
    log "已应用预构建前端和后端依赖"
    return 0
}

local_build() {
    section "执行本地构建"
    ensure_build_packages
    run_as_app "export COREPACK_ENABLE_DOWNLOAD_PROMPT=0; export PATH='$NODE_ROOT/bin:$PATH'; cd '$SRC_DIR/backend'; corepack yarn install --frozen-lockfile"
    run_as_app "export COREPACK_ENABLE_DOWNLOAD_PROMPT=0; export PATH='$NODE_ROOT/bin:$PATH'; cd '$SRC_DIR/frontend'; corepack yarn install --frozen-lockfile"
    run_as_app "export COREPACK_ENABLE_DOWNLOAD_PROMPT=0; export PATH='$NODE_ROOT/bin:$PATH'; cd '$SRC_DIR/frontend'; corepack yarn build"
    log "本地构建完成"
}

prepare_artifacts() {
    if use_prebuilt_assets; then
        return 0
    fi
    INSTALL_MODE="local"
    local_build
}

write_fallback_page() {
    mkdir -p "$RUNTIME_WWW_DIR"
    if [[ -f "$SRC_DIR/docker/rootfs/var/www/html/index.html" ]]; then
        cp "$SRC_DIR/docker/rootfs/var/www/html/index.html" "$RUNTIME_WWW_DIR/index.html"
        return 0
    fi

    cat > "$RUNTIME_WWW_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>Nginx Proxy Manager</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: sans-serif; margin: 0; display: grid; place-items: center; min-height: 100vh; background: #f3f5f7; color: #17212b; }
    main { max-width: 42rem; padding: 2rem; }
    h1 { margin-top: 0; }
  </style>
</head>
<body>
  <main>
    <h1>Nginx Proxy Manager</h1>
    <p>代理服务已运行，但此域名尚未配置站点。</p>
  </main>
</body>
</html>
EOF
}

sync_modules_enabled() {
    mkdir -p "$RUNTIME_NGINX_ETC_DIR/modules-enabled"
    rm -f "$RUNTIME_NGINX_ETC_DIR/modules-enabled"/*.conf
    if [[ -d /etc/nginx/modules-enabled ]]; then
        find /etc/nginx/modules-enabled -maxdepth 1 -name '*.conf' | while read -r item; do
            cp -Lf "$item" "$RUNTIME_NGINX_ETC_DIR/modules-enabled/$(basename "$item")"
        done
    fi
}

write_resolvers_conf() {
    local resolver_line
    resolver_line="$(awk 'BEGIN { ORS=" " } $1 == "nameserver" { sub(/%.*$/, "", $2); if ($2 ~ /:/) { printf("[%s] ", $2) } else { printf("%s ", $2) } }' /etc/resolv.conf)"
    [[ -n "$resolver_line" ]] || resolver_line="1.1.1.1 8.8.8.8 "
    printf 'resolver %svalid=10s;\n' "$resolver_line" > "$RUNTIME_NGINX_ETC_DIR/conf.d/include/resolvers.conf"
}

write_runtime_files() {
    section "准备隔离运行环境"

    mkdir -p "$RUNTIME_DATA_DIR/nginx"/{access,custom_ssl,default_host,default_www,dead_host,proxy_host,redirection_host,stream,temp,custom}
    mkdir -p "$RUNTIME_DATA_DIR"/{logs,access,custom_ssl,letsencrypt-acme-challenge}
    mkdir -p "$RUNTIME_LE_DIR"/{accounts,archive,credentials,live,renewal}
    mkdir -p "$RUNTIME_ETC_DIR/logrotate.d" "$RUNTIME_NGINX_ETC_DIR/conf.d/include" "$RUNTIME_RUN_DIR" "$RUNTIME_RUN_DIR/cache/public" "$RUNTIME_RUN_DIR/cache/private" "$RUNTIME_RUN_DIR/tmp/nginx/body" "$TMP_ROOT"

    rm -rf "$LOG_ROOT"
    ln -s "$RUNTIME_DATA_DIR/logs" "$LOG_ROOT"

    write_fallback_page
    sync_modules_enabled

    cp "$SRC_DIR/docker/rootfs/etc/nginx/mime.types" "$RUNTIME_NGINX_ETC_DIR/mime.types"
    for file in assets.conf block-exploits.conf force-ssl.conf letsencrypt-acme-challenge.conf log-proxy.conf log-stream.conf proxy.conf ssl-cache-stream.conf ssl-cache.conf ssl-ciphers.conf; do
        cp "$SRC_DIR/docker/rootfs/etc/nginx/conf.d/include/$file" "$RUNTIME_NGINX_ETC_DIR/conf.d/include/$file"
    done
    : > "$RUNTIME_NGINX_ETC_DIR/conf.d/include/ip_ranges.conf"
    write_resolvers_conf

    for custom_file in events.conf http.conf http_top.conf root.conf root_top.conf server_dead.conf server_proxy.conf server_redirect.conf server_stream.conf server_stream_tcp.conf server_stream_udp.conf stream.conf; do
        : > "$RUNTIME_DATA_DIR/nginx/custom/$custom_file"
    done

    cat > "$RUNTIME_ETC_DIR/letsencrypt.ini" <<'EOF'
text = True
non-interactive = True
agree-tos = True
webroot-path = /data/letsencrypt-acme-challenge
key-type = ecdsa
elliptic-curve = secp384r1
preferred-chain = ISRG Root X1
EOF

    cat > "$RUNTIME_ETC_DIR/logrotate.d/nginx-proxy-manager" <<'EOF'
/data/logs/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 npmbare npmbare
    sharedscripts
    postrotate
        /opt/npm-bare/tools/nginx-real -c /etc/nginx/nginx.conf -p /run/npm-bare/ -s reopen >/dev/null 2>&1 || true
    endscript
}
EOF

    cat > "$SHIM_DIR/nginx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/npm-bare/tools/nginx-real -c /etc/nginx/nginx.conf -p /run/npm-bare/ "$@"
EOF

    cat > "$SHIM_DIR/logrotate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/sbin/logrotate -s /run/npm-bare/logrotate.state "$@"
EOF

    chmod 755 "$SHIM_DIR/nginx" "$SHIM_DIR/logrotate"

    cat > "$RUNTIME_NGINX_ETC_DIR/nginx.conf" <<EOF
user $APP_USER;
worker_processes auto;
pid /run/npm-bare/nginx.pid;
error_log /data/logs/fallback_error.log warn;

include /etc/nginx/modules-enabled/*.conf;
include /data/nginx/custom/root_top[.]conf;

events {
    include /data/nginx/custom/events[.]conf;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    server_tokens off;
    tcp_nopush on;
    tcp_nodelay on;
    client_body_temp_path /run/npm-bare/tmp/nginx/body 1 2;
    keepalive_timeout 90s;
    proxy_connect_timeout 90s;
    proxy_send_timeout 90s;
    proxy_read_timeout 90s;
    ssl_prefer_server_ciphers on;
    gzip on;
    proxy_ignore_client_abort off;
    client_max_body_size 2000m;
    server_names_hash_bucket_size 1024;
    proxy_http_version 1.1;
    proxy_set_header X-Forwarded-Scheme \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Accept-Encoding "";
    proxy_cache off;
    proxy_cache_path /run/npm-bare/cache/public levels=1:2 keys_zone=public-cache:30m max_size=192m;
    proxy_cache_path /run/npm-bare/cache/private levels=1:2 keys_zone=private-cache:5m max_size=1024m;

    include /etc/nginx/conf.d/include/log-proxy[.]conf;
    include /etc/nginx/conf.d/include/resolvers[.]conf;

    map \$host \$forward_scheme {
        default http;
    }

    map \$http_x_forwarded_proto \$x_forwarded_proto {
        "http" "http";
        "https" "https";
        default \$scheme;
    }

    map \$http_x_forwarded_scheme \$x_forwarded_scheme {
        "http" "http";
        "https" "https";
        default \$scheme;
    }

    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    include /etc/nginx/conf.d/include/ip_ranges[.]conf;
    real_ip_header X-Real-IP;
    real_ip_recursive on;

    include /data/nginx/custom/http_top[.]conf;
    include /etc/nginx/conf.d/*.conf;
    include /data/nginx/default_host/*.conf;
    include /data/nginx/proxy_host/*.conf;
    include /data/nginx/redirection_host/*.conf;
    include /data/nginx/dead_host/*.conf;
    include /data/nginx/temp/*.conf;
    include /data/nginx/custom/http[.]conf;
}

stream {
    include /etc/nginx/conf.d/include/log-stream[.]conf;
    include /data/nginx/stream/*.conf;
    include /data/nginx/custom/stream[.]conf;
}

include /data/nginx/custom/root[.]conf;
EOF

    cat > "$RUNTIME_NGINX_ETC_DIR/conf.d/default.conf" <<EOF
server {
    listen 80;
    listen [::]:80;

    set \$forward_scheme "http";
    set \$server "127.0.0.1";
    set \$port "80";

    server_name localhost-nginx-proxy-manager;
    access_log /data/logs/fallback_http_access.log standard;
    error_log /data/logs/fallback_http_error.log warn;
    include /etc/nginx/conf.d/include/assets.conf;
    include /etc/nginx/conf.d/include/block-exploits.conf;
    include /etc/nginx/conf.d/include/letsencrypt-acme-challenge.conf;

    location / {
        index index.html;
        root $RUNTIME_WWW_DIR;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    set \$forward_scheme "https";
    set \$server "127.0.0.1";
    set \$port "443";

    server_name localhost;
    access_log /data/logs/fallback_http_access.log standard;
    error_log /dev/null crit;
    include /etc/nginx/conf.d/include/ssl-ciphers.conf;
    ssl_reject_handshake on;

    return 444;
}
EOF

    cat > "$RUNTIME_NGINX_ETC_DIR/conf.d/production.conf" <<EOF
server {
    listen $ADMIN_PORT default_server;
    listen [::]:$ADMIN_PORT default_server;

    server_name npm-admin.local;
    root $SRC_DIR/frontend/dist;
    access_log /data/logs/admin_access.log standard;
    error_log /data/logs/admin_error.log warn;

    location = /api {
        return 302 /api/;
    }

    location /api/ {
        add_header X-Served-By \$host;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Scheme \$scheme;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_pass http://127.0.0.1:3000/;
        proxy_read_timeout 15m;
        proxy_send_timeout 15m;
    }

    location / {
        index index.html;
        if (\$request_uri ~ ^/(.*)\\.html$) {
            return 302 /\$1;
        }
        try_files \$uri \$uri.html \$uri/ /index.html;
    }
}
EOF

    chown -R "$APP_USER:$APP_GROUP" "$APP_ROOT" "$STATE_ROOT" "$LOG_ROOT" "$SHIM_DIR"
    log "隔离运行环境已就绪"
}
write_service_units() {
    section "写入 systemd 服务单元"
    write_runtime_env

    cat > "/etc/systemd/system/$SERVICE_NGINX" <<EOF
[Unit]
Description=Nginx Proxy Manager 私有 nginx
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
EnvironmentFile=$ENV_FILE
BindPaths=$RUNTIME_DATA_DIR:/data
BindPaths=$RUNTIME_LE_DIR:/etc/letsencrypt
BindPaths=$RUNTIME_NGINX_ETC_DIR:/etc/nginx
BindPaths=$RUNTIME_RUN_DIR:/run/npm-bare
BindReadOnlyPaths=$RUNTIME_ETC_DIR/letsencrypt.ini:/etc/letsencrypt.ini
ExecStart=$NGINX_REAL_BIN -c /etc/nginx/nginx.conf -p /run/npm-bare/ -g daemon\ off;
ExecReload=$NGINX_REAL_BIN -c /etc/nginx/nginx.conf -p /run/npm-bare/ -s reload
ExecStop=$NGINX_REAL_BIN -c /etc/nginx/nginx.conf -p /run/npm-bare/ -s quit
Restart=on-failure
RestartSec=2
KillSignal=SIGQUIT
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/$SERVICE_BACKEND" <<EOF
[Unit]
Description=Nginx Proxy Manager 后端服务
After=network-online.target $SERVICE_NGINX
Wants=network-online.target $SERVICE_NGINX

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$SRC_DIR/backend
EnvironmentFile=$ENV_FILE
Environment=HOME=$APP_HOME
Environment=TMPDIR=$TMP_ROOT
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=256
Environment=DB_SQLITE_FILE=/data/database.sqlite
Environment=PATH=$SHIM_DIR:$CERTBOT_VENV/bin:$NODE_ROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DISABLE_IPV6=false
BindPaths=$RUNTIME_DATA_DIR:/data
BindPaths=$RUNTIME_LE_DIR:/etc/letsencrypt
BindPaths=$RUNTIME_NGINX_ETC_DIR:/etc/nginx
BindPaths=$RUNTIME_RUN_DIR:/run/npm-bare
BindPaths=$CERTBOT_VENV:/opt/certbot
BindReadOnlyPaths=$RUNTIME_ETC_DIR/letsencrypt.ini:/etc/letsencrypt.ini
BindReadOnlyPaths=$RUNTIME_ETC_DIR/logrotate.d/nginx-proxy-manager:/etc/logrotate.d/nginx-proxy-manager
BindReadOnlyPaths=$SHIM_DIR/nginx:/usr/sbin/nginx
ExecStart=$NODE_ROOT/bin/node index.js
Restart=on-failure
RestartSec=3
PrivateTmp=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "systemd 服务单元已写入"
}

stop_services() {
    systemctl stop "$SERVICE_BACKEND" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE_NGINX" >/dev/null 2>&1 || true
}

wait_for_health() {
    local tries=30
    local url="http://127.0.0.1:${ADMIN_PORT}/api/"
    while (( tries > 0 )); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries - 1))
        sleep 2
    done
    warn "管理后台 API 未能在预期时间内就绪"
    journalctl -u "$SERVICE_BACKEND" -n 20 --no-pager || true
    return 1
}

start_services() {
    section "启动服务"
    systemctl enable "$SERVICE_NGINX" "$SERVICE_BACKEND" >/dev/null 2>&1 || true
    systemctl start "$SERVICE_NGINX"
    systemctl start "$SERVICE_BACKEND"
    wait_for_health
    log "服务已启动"
}

status_report() {
    load_config
    local admin_port="${ADMIN_PORT:-$DEFAULT_ADMIN_PORT}"
    local ip_addr="127.0.0.1"
    if command_exists hostname; then
        ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        ip_addr="${ip_addr:-127.0.0.1}"
    fi

    section "部署状态"
    printf '后端服务     : %s\n' "$(systemctl is-active "$SERVICE_BACKEND" 2>/dev/null || echo inactive)"
    printf 'Nginx 服务    : %s\n' "$(systemctl is-active "$SERVICE_NGINX" 2>/dev/null || echo inactive)"
    printf '管理后台端口 : %s\n' "$admin_port"
    printf '部署引用     : %s\n' "${INSTALL_REF:-未配置}"
    printf '安装模式     : %s\n' "${INSTALL_MODE:-未配置}"
    printf 'Node 运行时  : %s\n' "$($NODE_ROOT/bin/node --version 2>/dev/null || echo 缺失)"
    printf '管理后台地址 : http://%s:%s\n' "$ip_addr" "$admin_port"
    printf '源码路径     : %s\n' "$SRC_DIR"
    printf '状态路径     : %s\n' "$STATE_ROOT"
}

health_report() {
    load_config
    local failures=0
    local admin_port="${ADMIN_PORT:-$DEFAULT_ADMIN_PORT}"

    section "健康检查"

    if systemctl is-active "$SERVICE_BACKEND" >/dev/null 2>&1; then
        log "后端服务处于活动状态"
    else
        error "后端服务未处于活动状态"
        failures=$((failures + 1))
    fi

    if systemctl is-active "$SERVICE_NGINX" >/dev/null 2>&1; then
        log "私有 nginx 服务处于活动状态"
    else
        error "私有 nginx 服务未处于活动状态"
        failures=$((failures + 1))
    fi

    if run_in_root_namespace "'$NGINX_REAL_BIN' -c /etc/nginx/nginx.conf -p /run/npm-bare/ -t" >/dev/null 2>&1; then
        log "私有 nginx 配置通过语法检查"
    else
        error "私有 nginx 配置未通过语法检查"
        failures=$((failures + 1))
    fi

    if curl -fsS "http://127.0.0.1:${admin_port}/api/" >/dev/null 2>&1; then
        log "管理后台 API 在端口 ${admin_port} 上可访问"
    else
        error "管理后台 API 在端口 ${admin_port} 上无响应"
        failures=$((failures + 1))
    fi

    if [[ -f "$RUNTIME_DATA_DIR/database.sqlite" ]]; then
        log "SQLite 数据库已存在"
    else
        warn "SQLite 数据库尚未创建"
    fi

    if (( failures > 0 )); then
        error "健康检查失败，共发现 ${failures} 个问题"
        return 1
    fi

    log "健康检查通过"
}

logs_report() {
    journalctl -u "$SERVICE_BACKEND" -u "$SERVICE_NGINX" -n 120 --no-pager
}

write_install_summary() {
    load_config
    local admin_port="${ADMIN_PORT:-$DEFAULT_ADMIN_PORT}"
    local ip_addr="127.0.0.1"
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    ip_addr="${ip_addr:-127.0.0.1}"

    section "部署完成"
    printf '管理后台地址 : http://%s:%s\n' "$ip_addr" "$admin_port"
    printf 'API 检查     : http://127.0.0.1:%s/api/\n' "$admin_port"
    printf '源码路径     : %s\n' "$SRC_DIR"
    printf '数据路径     : %s\n' "$STATE_ROOT"
    printf '日志命令     : journalctl -u %s -u %s -f\n' "$SERVICE_BACKEND" "$SERVICE_NGINX"
    printf '说明         : 如果没有传入初始管理员环境变量，首次登录会进入上游自带的初始化向导。\n'
}

remove_services() {
    stop_services
    systemctl disable "$SERVICE_BACKEND" "$SERVICE_NGINX" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$SERVICE_BACKEND" "/etc/systemd/system/$SERVICE_NGINX"
    systemctl daemon-reload
}

uninstall_all() {
    section "正在卸载"
    if [[ $KEEP_DATA -eq 0 ]] && [[ $FORCE -eq 0 ]] && [[ $NONINTERACTIVE -eq 0 ]]; then
        confirm "是否移除全部 NPM 裸机部署数据、证书和日志？" "y" || KEEP_DATA=1
    fi

    remove_services

    rm -rf "$INSTALL_ROOT"
    if [[ $KEEP_DATA -eq 0 ]]; then
        rm -f "$CONFIG_FILE" "$ENV_FILE"
        rm -rf "$STATE_ROOT" "$LOG_ROOT"
    fi
    if id -u "$APP_USER" >/dev/null 2>&1; then
        userdel "$APP_USER" >/dev/null 2>&1 || true
    fi
    if getent group "$APP_GROUP" >/dev/null 2>&1; then
        groupdel "$APP_GROUP" >/dev/null 2>&1 || true
    fi

    log "卸载完成"
    if [[ $KEEP_DATA -eq 1 ]]; then
        info "数据已保留在 $STATE_ROOT"
    fi
}

perform_install() {
    require_root
    require_linux
    check_os
    collect_install_settings
    ensure_directories
    ensure_user
    ensure_packages
    ensure_node
    ensure_certbot
    copy_nginx_binary
    stop_services
    ensure_proxy_ports_free
    clone_source
    prepare_artifacts
    write_runtime_files
    save_config
    write_service_units
    if [[ -n "$INITIAL_ADMIN_EMAIL" ]]; then
        printf 'INITIAL_ADMIN_EMAIL=%s\n' "$INITIAL_ADMIN_EMAIL" >> "$ENV_FILE"
    fi
    if [[ -n "$INITIAL_ADMIN_PASSWORD" ]]; then
        printf 'INITIAL_ADMIN_PASSWORD=%s\n' "$INITIAL_ADMIN_PASSWORD" >> "$ENV_FILE"
    fi
    start_services
    status_report
    write_install_summary
}

perform_upgrade() {
    require_root
    require_linux
    check_os
    [[ -f "$CONFIG_FILE" ]] || die "未找到现有安装"
    collect_install_settings
    ensure_directories
    ensure_user
    ensure_packages
    ensure_node
    ensure_certbot
    copy_nginx_binary
    stop_services
    ensure_proxy_ports_free
    clone_source
    prepare_artifacts
    write_runtime_files
    save_config
    write_service_units
    start_services
    status_report
    write_install_summary
}

main() {
    parse_args "$@"

    case "$COMMAND" in
        menu)
            menu
            main
            ;;
        install)
            INSTALL_MODE="prebuilt"
            perform_install
            ;;
        install-local)
            INSTALL_MODE="local"
            perform_install
            ;;
        reinstall)
            INSTALL_MODE="prebuilt"
            perform_upgrade
            ;;
        reinstall-local)
            INSTALL_MODE="local"
            perform_upgrade
            ;;
        upgrade)
            perform_upgrade
            ;;
        status)
            status_report
            ;;
        health)
            health_report
            ;;
        logs)
            logs_report
            ;;
        uninstall)
            require_root
            uninstall_all
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            die "未知命令：$COMMAND"
            ;;
    esac
}

main "$@"
