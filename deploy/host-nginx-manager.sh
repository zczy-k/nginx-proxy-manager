#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"
APP_LABEL="VPS Nginx 代理管理器"
MANAGER_ROOT="/etc/nginx/vps-proxy-manager"
SITE_STATE_DIR="$MANAGER_ROOT/sites"
ACME_ROOT="$MANAGER_ROOT/acme"
SITE_PREFIX="vpspm"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

COMMAND="${1:-help}"
shift || true

YES_MODE=0
DELETE_CERT=0
UPSTREAM_SCHEME="http"
CLIENT_MAX_BODY_SIZE="64m"
PROXY_READ_TIMEOUT="300s"
PROXY_SEND_TIMEOUT="300s"
WEBSOCKET=1
ENABLE_SSL=1
CERTBOT_EMAIL=""
BACKEND_INSECURE=0
DOMAIN=""
UPSTREAM=""

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
  host-nginx-manager.sh add DOMAIN UPSTREAM [选项]
  host-nginx-manager.sh enable-ssl DOMAIN [--email EMAIL]
  host-nginx-manager.sh disable-ssl DOMAIN
  host-nginx-manager.sh remove DOMAIN [--yes] [--delete-cert]
  host-nginx-manager.sh list
  host-nginx-manager.sh show DOMAIN
  host-nginx-manager.sh test
  host-nginx-manager.sh reload
  host-nginx-manager.sh help

说明:
  - 此脚本只管理它自己创建的标准 HTTP/HTTPS 反向代理站点。
  - 不会自动修改你当前 nginx.conf 里的 stream、Rathole、假证书拦截等手写配置。
  - 适合把普通 Web/API 服务统一挂到不同子域名下，由宿主 nginx 复用 80/443。

参数:
  --upstream-scheme http|https   后端协议，默认 http
  --email EMAIL                  申请 Let's Encrypt 证书时使用的邮箱
  --no-ssl                       新增站点时先只创建 HTTP 反代，不立即启用 HTTPS
  --client-max-body-size SIZE    如 64m / 512m / 0，默认 64m
  --proxy-read-timeout TIME      默认 300s
  --proxy-send-timeout TIME      默认 300s
  --backend-insecure             当后端是自签 HTTPS 时关闭证书校验
  --yes                          跳过确认
  --delete-cert                  remove 时一并删除 certbot 证书

示例:
  host-nginx-manager.sh add api.example.com 127.0.0.1:3001 --email you@example.com
  host-nginx-manager.sh add metapi.cni.de5.net 127.0.0.1:3001 --upstream-scheme http --no-ssl
  host-nginx-manager.sh enable-ssl metapi.cni.de5.net --email you@example.com
  host-nginx-manager.sh remove api.example.com --delete-cert --yes
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 身份运行此脚本"
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || die "此脚本仅支持 Linux"
}

require_nginx() {
    command_exists nginx || die "未检测到 nginx，请先安装 nginx"
}

require_certbot() {
    command_exists certbot || die "未检测到 certbot，请先安装 certbot"
}

confirm() {
    local prompt="$1"
    local reply=""
    if [[ $YES_MODE -eq 1 ]]; then
        return 0
    fi
    read -r -p "$(printf '%b?%b %s [y/N]: ' "$YELLOW" "$NC" "$prompt")" reply || true
    [[ "$reply" =~ ^[Yy]$ ]]
}

normalize_domain() {
    local raw="$1"
    raw="${raw,,}"
    raw="${raw#http://}"
    raw="${raw#https://}"
    raw="${raw%%/*}"
    printf '%s\n' "$raw"
}

validate_domain() {
    [[ "$1" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$1" == *.* ]]
}

validate_upstream() {
    [[ "$1" =~ ^[^:]+:[0-9]+$ ]]
}

ensure_manager_dirs() {
    mkdir -p "$SITE_STATE_DIR" "$ACME_ROOT"
    chmod 755 "$MANAGER_ROOT" "$ACME_ROOT"
}

state_file() {
    printf '%s/%s.env\n' "$SITE_STATE_DIR" "$1"
}

site_conf_available() {
    printf '/etc/nginx/sites-available/%s-%s.conf\n' "$SITE_PREFIX" "$1"
}

site_conf_enabled() {
    printf '/etc/nginx/sites-enabled/%s-%s.conf\n' "$SITE_PREFIX" "$1"
}

load_state() {
    local file
    file="$(state_file "$1")"
    [[ -f "$file" ]] || die "未找到站点状态文件：$file"
    # shellcheck disable=SC1090
    . "$file"
}

save_state() {
    local file
    file="$(state_file "$DOMAIN")"
    cat > "$file" <<EOF
DOMAIN=$DOMAIN
UPSTREAM=$UPSTREAM
UPSTREAM_SCHEME=$UPSTREAM_SCHEME
ENABLE_SSL=$ENABLE_SSL
CERTBOT_EMAIL=$CERTBOT_EMAIL
CLIENT_MAX_BODY_SIZE=$CLIENT_MAX_BODY_SIZE
PROXY_READ_TIMEOUT=$PROXY_READ_TIMEOUT
PROXY_SEND_TIMEOUT=$PROXY_SEND_TIMEOUT
WEBSOCKET=$WEBSOCKET
BACKEND_INSECURE=$BACKEND_INSECURE
EOF
    chmod 600 "$file"
}

render_site_config() {
    local conf=""
    local backend_tls_block=""
    local websocket_block=""

    if [[ "$UPSTREAM_SCHEME" == "https" ]]; then
        backend_tls_block+="        proxy_ssl_server_name on;\n"
        if [[ "$BACKEND_INSECURE" == "1" ]]; then
            backend_tls_block+="        proxy_ssl_verify off;\n"
        fi
    fi

    if [[ "$WEBSOCKET" == "1" ]]; then
        websocket_block+="        proxy_set_header Upgrade \$http_upgrade;\n"
        websocket_block+="        proxy_set_header Connection \"upgrade\";\n"
    fi

    conf+="# Managed by $APP_LABEL\n"
    conf+="server {\n"
    conf+="    listen 80;\n"
    conf+="    listen [::]:80;\n"
    conf+="    server_name $DOMAIN;\n\n"
    conf+="    location ^~ /.well-known/acme-challenge/ {\n"
    conf+="        root $ACME_ROOT;\n"
    conf+="        default_type text/plain;\n"
    conf+="        try_files \$uri =404;\n"
    conf+="    }\n\n"

    if [[ "$ENABLE_SSL" == "1" ]]; then
        conf+="    location / {\n"
        conf+="        return 301 https://\$host\$request_uri;\n"
        conf+="    }\n"
        conf+="}\n\n"
        conf+="server {\n"
        conf+="    listen 443 ssl http2;\n"
        conf+="    listen [::]:443 ssl http2;\n"
        conf+="    server_name $DOMAIN;\n\n"
        conf+="    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;\n"
        conf+="    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;\n"
        conf+="    ssl_protocols TLSv1.2 TLSv1.3;\n"
        conf+="    ssl_prefer_server_ciphers on;\n\n"
    else
        conf+="    location / {\n"
    fi

    conf+="        proxy_pass $UPSTREAM_SCHEME://$UPSTREAM;\n"
    conf+="        proxy_http_version 1.1;\n"
    conf+="$websocket_block"
    conf+="        proxy_set_header Host \$host;\n"
    conf+="        proxy_set_header X-Real-IP \$remote_addr;\n"
    conf+="        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
    conf+="        proxy_set_header X-Forwarded-Proto \$scheme;\n"
    conf+="        proxy_set_header X-Forwarded-Host \$host;\n"
    conf+="        proxy_set_header X-Forwarded-Port \$server_port;\n"
    conf+="        proxy_read_timeout $PROXY_READ_TIMEOUT;\n"
    conf+="        proxy_send_timeout $PROXY_SEND_TIMEOUT;\n"
    conf+="        client_max_body_size $CLIENT_MAX_BODY_SIZE;\n"
    conf+="$backend_tls_block"
    conf+="    }\n"
    conf+="}\n"

    printf '%b' "$conf"
}

install_conf_file() {
    local available enabled tmp
    available="$(site_conf_available "$DOMAIN")"
    enabled="$(site_conf_enabled "$DOMAIN")"
    tmp="$(mktemp /tmp/vpspm.XXXXXX.conf)"

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    render_site_config > "$tmp"
    install -m 0644 "$tmp" "$available"
    rm -f "$tmp"

    ln -sfn "$available" "$enabled"
}

validate_and_reload() {
    nginx -t >/dev/null 2>&1 || {
        nginx -t
        return 1
    }
    systemctl reload nginx >/dev/null 2>&1 || nginx -s reload
}

apply_site() {
    local available enabled backup_available="" backup_enabled_target=""
    available="$(site_conf_available "$DOMAIN")"
    enabled="$(site_conf_enabled "$DOMAIN")"

    if [[ -f "$available" ]]; then
        backup_available="$(mktemp /tmp/vpspm-backup.XXXXXX.conf)"
        cp "$available" "$backup_available"
    fi
    if [[ -L "$enabled" ]]; then
        backup_enabled_target="$(readlink "$enabled")"
    fi

    install_conf_file

    if validate_and_reload; then
        [[ -n "$backup_available" ]] && rm -f "$backup_available"
        log "nginx 配置已应用：$DOMAIN"
        return 0
    fi

    warn "新配置未通过校验，正在回滚：$DOMAIN"
    if [[ -n "$backup_available" ]]; then
        cp "$backup_available" "$available"
        rm -f "$backup_available"
    else
        rm -f "$available"
    fi

    if [[ -n "$backup_enabled_target" ]]; then
        ln -sfn "$backup_enabled_target" "$enabled"
    else
        rm -f "$enabled"
    fi

    validate_and_reload || true
    return 1
}

issue_cert() {
    local email_args=()
    require_certbot

    if [[ -n "$CERTBOT_EMAIL" ]]; then
        email_args=(--email "$CERTBOT_EMAIL")
    else
        email_args=(--register-unsafely-without-email)
    fi

    certbot certonly \
        --webroot \
        -w "$ACME_ROOT" \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        "${email_args[@]}"
}

parse_add_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --upstream-scheme)
                UPSTREAM_SCHEME="${2:-}"
                shift 2
                ;;
            --email)
                CERTBOT_EMAIL="${2:-}"
                shift 2
                ;;
            --no-ssl)
                ENABLE_SSL=0
                shift
                ;;
            --client-max-body-size)
                CLIENT_MAX_BODY_SIZE="${2:-}"
                shift 2
                ;;
            --proxy-read-timeout)
                PROXY_READ_TIMEOUT="${2:-}"
                shift 2
                ;;
            --proxy-send-timeout)
                PROXY_SEND_TIMEOUT="${2:-}"
                shift 2
                ;;
            --backend-insecure)
                BACKEND_INSECURE=1
                shift
                ;;
            --yes)
                YES_MODE=1
                shift
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    [[ "$UPSTREAM_SCHEME" == "http" || "$UPSTREAM_SCHEME" == "https" ]] || die "--upstream-scheme 只能是 http 或 https"
}

warn_if_domain_exists_elsewhere() {
    local existing=""
    existing="$(nginx -T 2>/dev/null | grep -E "server_name[[:space:]].*\b${DOMAIN}\b" | grep -v "$(site_conf_available "$DOMAIN")" || true)"
    if [[ -n "$existing" ]]; then
        warn "nginx 当前配置里已经出现域名 $DOMAIN。请确认没有重复站点。"
        printf '%s\n' "$existing"
    fi
}

cmd_add() {
    DOMAIN="$(normalize_domain "${1:-}")"
    UPSTREAM="${2:-}"
    shift 2 || true
    parse_add_options "$@"

    validate_domain "$DOMAIN" || die "无效域名：$DOMAIN"
    validate_upstream "$UPSTREAM" || die "UPSTREAM 必须是 HOST:PORT 格式，例如 127.0.0.1:3001"

    ensure_manager_dirs
    warn_if_domain_exists_elsewhere

    section "写入 HTTP 站点"
    local initial_ssl="$ENABLE_SSL"
    ENABLE_SSL=0
    save_state
    apply_site || die "写入 HTTP 站点配置失败"

    if [[ "$initial_ssl" == "1" ]]; then
        section "申请证书并启用 HTTPS"
        issue_cert || die "certbot 证书申请失败"
        ENABLE_SSL=1
        save_state
        apply_site || die "启用 HTTPS 配置失败"
    fi

    write_summary
}

write_summary() {
    section "站点已就绪"
    printf '域名         : %s\n' "$DOMAIN"
    printf '后端         : %s://%s\n' "$UPSTREAM_SCHEME" "$UPSTREAM"
    printf 'HTTPS        : %s\n' "$([[ "$ENABLE_SSL" == "1" ]] && echo 已启用 || echo 未启用)"
    if [[ "$ENABLE_SSL" == "1" ]]; then
        printf '访问地址     : https://%s\n' "$DOMAIN"
    else
        printf '访问地址     : http://%s\n' "$DOMAIN"
    fi
    printf '状态文件     : %s\n' "$(state_file "$DOMAIN")"
    printf '配置文件     : %s\n' "$(site_conf_available "$DOMAIN")"
}

cmd_enable_ssl() {
    DOMAIN="$(normalize_domain "${1:-}")"
    shift || true
    local cli_email=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                cli_email="${2:-}"
                shift 2
                ;;
            --yes)
                YES_MODE=1
                shift
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    validate_domain "$DOMAIN" || die "无效域名：$DOMAIN"
    load_state "$DOMAIN"
    [[ "$ENABLE_SSL" == "1" ]] && warn "站点已启用 HTTPS，将重新确认证书和配置"
    if [[ -n "$cli_email" ]]; then
        CERTBOT_EMAIL="$cli_email"
    fi

    ENABLE_SSL=0
    save_state
    apply_site || die "更新 HTTP 站点失败"

    issue_cert || die "certbot 证书申请失败"
    ENABLE_SSL=1
    save_state
    apply_site || die "启用 HTTPS 配置失败"
    write_summary
}

cmd_disable_ssl() {
    DOMAIN="$(normalize_domain "${1:-}")"
    validate_domain "$DOMAIN" || die "无效域名：$DOMAIN"
    load_state "$DOMAIN"
    ENABLE_SSL=0
    save_state
    apply_site || die "关闭 HTTPS 失败"
    write_summary
}

cmd_remove() {
    DOMAIN="$(normalize_domain "${1:-}")"
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                YES_MODE=1
                shift
                ;;
            --delete-cert)
                DELETE_CERT=1
                shift
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    validate_domain "$DOMAIN" || die "无效域名：$DOMAIN"
    load_state "$DOMAIN"

    confirm "确认删除站点 $DOMAIN 吗？" || exit 0

    rm -f "$(site_conf_enabled "$DOMAIN")" "$(site_conf_available "$DOMAIN")" "$(state_file "$DOMAIN")"
    validate_and_reload || die "删除站点后 nginx 校验失败，请手动检查"

    if [[ $DELETE_CERT -eq 1 ]] && command_exists certbot; then
        certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true
        info "已尝试删除 certbot 证书：$DOMAIN"
    fi

    log "站点已删除：$DOMAIN"
}

cmd_list() {
    ensure_manager_dirs
    section "受管站点列表"
    if ! find "$SITE_STATE_DIR" -maxdepth 1 -name '*.env' | grep -q .; then
        info "暂无受管站点"
        return 0
    fi

    find "$SITE_STATE_DIR" -maxdepth 1 -name '*.env' | sort | while read -r file; do
        # shellcheck disable=SC1090
        . "$file"
        printf '%-30s %-8s %-24s %s\n' "$DOMAIN" "$([[ "$ENABLE_SSL" == "1" ]] && echo HTTPS || echo HTTP)" "$UPSTREAM_SCHEME://$UPSTREAM" "$(basename "$file")"
    done
}

cmd_show() {
    DOMAIN="$(normalize_domain "${1:-}")"
    validate_domain "$DOMAIN" || die "无效域名：$DOMAIN"
    load_state "$DOMAIN"
    section "站点详情"
    printf '域名              : %s\n' "$DOMAIN"
    printf '后端              : %s://%s\n' "$UPSTREAM_SCHEME" "$UPSTREAM"
    printf 'HTTPS             : %s\n' "$([[ "$ENABLE_SSL" == "1" ]] && echo 已启用 || echo 未启用)"
    printf '邮箱              : %s\n' "${CERTBOT_EMAIL:-未设置}"
    printf '上传大小          : %s\n' "$CLIENT_MAX_BODY_SIZE"
    printf '读取超时          : %s\n' "$PROXY_READ_TIMEOUT"
    printf '发送超时          : %s\n' "$PROXY_SEND_TIMEOUT"
    printf '后端证书校验      : %s\n' "$([[ "$BACKEND_INSECURE" == "1" ]] && echo 已关闭 || echo 已开启)"
    printf '状态文件          : %s\n' "$(state_file "$DOMAIN")"
    printf '配置文件          : %s\n' "$(site_conf_available "$DOMAIN")"
}

cmd_test() {
    section "测试 nginx 配置"
    nginx -t
}

cmd_reload() {
    section "重载 nginx"
    validate_and_reload || die "nginx 重载失败"
    log "nginx 已重载"
}

main() {
    case "$COMMAND" in
        help|-h|--help)
            usage
            return 0
            ;;
    esac

    require_root
    require_linux
    require_nginx
    ensure_manager_dirs

    case "$COMMAND" in
        add)
            [[ $# -ge 2 ]] || die "用法：add DOMAIN UPSTREAM [选项]"
            cmd_add "$@"
            ;;
        enable-ssl)
            [[ $# -ge 1 ]] || die "用法：enable-ssl DOMAIN [--email EMAIL]"
            cmd_enable_ssl "$@"
            ;;
        disable-ssl)
            [[ $# -eq 1 ]] || die "用法：disable-ssl DOMAIN"
            cmd_disable_ssl "$1"
            ;;
        remove)
            [[ $# -ge 1 ]] || die "用法：remove DOMAIN [--yes] [--delete-cert]"
            cmd_remove "$@"
            ;;
        list)
            cmd_list
            ;;
        show)
            [[ $# -eq 1 ]] || die "用法：show DOMAIN"
            cmd_show "$1"
            ;;
        test)
            cmd_test
            ;;
        reload)
            cmd_reload
            ;;

        *)
            die "未知命令：$COMMAND"
            ;;
    esac
}

main "$@"
