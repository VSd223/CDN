#!/usr/bin/env bash
# ==============================================================================
# EDGE TRAFFIC GATEWAY & SMART REVERSE PROXY MANAGER
# High-Performance HTTP/HTTPS, TCP/UDP & Telegram WEB Proxy Router
# Version: 3.1.0
# ==============================================================================

set -o pipefail

# --- КОНСТАНТЫ И ПУТИ ---
APP_NAME="EdgeProxy"
APP_VERSION="3.1.0"
CONFIG_DIR="/etc/edge-proxy"
RULES_HTTP_DIR="${CONFIG_DIR}/rules.d/http"
RULES_STREAM_DIR="${CONFIG_DIR}/rules.d/stream"
NGINX_DIR="/etc/nginx"
NGINX_CONF="${NGINX_DIR}/nginx.conf"
NGINX_HTTP_DIR="${NGINX_DIR}/conf.d/edge_http"
NGINX_STREAM_DIR="${NGINX_DIR}/conf.d/edge_stream"
CACHE_DIR="/var/cache/edge-proxy"
LOG_DIR="/var/log/edge-proxy"
BACKUP_DIR="${CONFIG_DIR}/backups"

# --- ЦВЕТА И ОФОРМЛЕНИЕ ---
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'

print_banner() {
    clear
    echo -e "${C_CYAN}"
    echo "  ███████╗██████╗  ██████╗ ███████╗    ██████╗ ██████╗  ██████╗ ██╗  ██╗██╗   ██╗"
    echo "  ██╔════╝██╔══██╗██╔════╝ ██╔════╝    ██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝╚██╗ ██╔╝"
    echo "  █████╗  ██║  ██║██║  ███╗█████╗      ██████╔╝██████╔╝██║   ██║ ╚███╔╝  ╚████╔╝ "
    echo "  ██╔══╝  ██║  ██║██║   ██║██╔══╝      ██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗   ╚██╔╝  "
    echo "  ███████╗██████╔╝╚██████╔╝███████╗    ██║     ██║  ██║╚██████╔╝██╔╝ ██╗   ██║   "
    echo "  ╚══════╝╚═════╝  ╚═════╝ ╚══════╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   "
    echo -e "${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}Универсальный шлюз перенаправления и защиты трафика v${APP_VERSION}${C_RESET}"
    echo -e "  ${C_CYAN}──────────────────────────────────────────────────────────────────────────────${C_RESET}"
}

log_info() { echo -e "  ${C_BLUE}ℹ${C_RESET}  $1"; }
log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET}  $1"; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET}  $1"; }
log_err()  { echo -e "  ${C_RED}✖${C_RESET}  $1"; }

pause_prompt() {
    echo ""
    read -rp "  Нажмите [Enter] для продолжения..."
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Этот скрипт должен быть запущен с правами root (sudo)."
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VER_ID=$VERSION_ID
    else
        log_err "Не удалось определить операционную систему."
        exit 1
    fi
}

init_directories() {
    mkdir -p "${CONFIG_DIR}" \
             "${RULES_HTTP_DIR}" \
             "${RULES_STREAM_DIR}" \
             "${NGINX_HTTP_DIR}" \
             "${NGINX_STREAM_DIR}" \
             "${CACHE_DIR}" \
             "${LOG_DIR}" \
             "${BACKUP_DIR}" \
             "/etc/edge-proxy/ssl" \
             "/var/www/html"
}

setup_master_nginx_conf() {
    log_info "Настройка главной конфигурации Nginx..."
    
    if [ ! -f /etc/edge-proxy/ssl/dhparam.pem ]; then
        log_info "Генерация DH-параметров безопасности (2048-bit)..."
        openssl dhparam -out /etc/edge-proxy/ssl/dhparam.pem 2048 > /dev/null 2>&1
    fi

    cat <<EOF > "${NGINX_CONF}"
user www-data;
worker_processes auto;
worker_rlimit_nofile 1048576;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
}

stream {
    log_format stream_edge '\$remote_addr [\$time_local] '
                           '\$protocol \$status \$bytes_sent \$bytes_received '
                           '\$session_time "\$upstream_addr"';

    access_log ${LOG_DIR}/stream_access.log stream_edge;
    error_log ${LOG_DIR}/stream_error.log warn;

    include ${NGINX_STREAM_DIR}/*.conf;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Динамический апгрейд для WebSocket (критично для Telegram Web Proxy)
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    resolver 1.1.1.1 8.8.8.8 77.88.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 10000;
    types_hash_max_size 2048;
    server_tokens off;

    client_max_body_size 500M;
    client_body_buffer_size 128k;
    proxy_connect_timeout 60s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_dhparam /etc/edge-proxy/ssl/dhparam.pem;

    proxy_cache_path ${CACHE_DIR} levels=1:2 keys_zone=EDGE_CACHE:100m max_size=5g inactive=60m use_temp_path=off;

    limit_req_zone \$binary_remote_addr zone=edge_ip_limit:20m rate=40r/s;
    limit_conn_zone \$binary_remote_addr zone=edge_conn_limit:20m;

    log_format edge_combined '\$remote_addr - \$remote_user [\$time_local] '
                             '"\$request" \$status \$body_bytes_sent '
                             '"\$http_referer" "\$http_user_agent" '
                             'rt=\$request_time uct="\$upstream_connect_time" uht="\$upstream_header_time" urt="\$upstream_response_time" '
                             'cache="\$upstream_cache_status"';

    access_log ${LOG_DIR}/http_access.log edge_combined;
    error_log ${LOG_DIR}/http_error.log warn;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    include ${NGINX_HTTP_DIR}/*.conf;
}
EOF

    nginx -t > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        systemctl enable nginx > /dev/null 2>&1
        log_ok "Главный конфиг Nginx успешно развернут!"
    else
        log_err "Ошибка в базовой структуре nginx.conf!"
    fi
}

ensure_firewall_port() {
    local port=$1
    local proto=$2
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" > /dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
    fi
}

# ==============================================================================
# МОДУЛЬ: TELEGRAM WEB PROXY (TPROXY ШЛЮЗ)
# ==============================================================================

add_tg_webproxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление шлюза для Telegram WEB Proxy (tproxy / bridge)${C_RESET}\n"

    read -rp "  Входной домен для Telegram (например, tg.mysite.ru): " TG_DOMAIN
    TG_DOMAIN=$(echo "$TG_DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')
    if [[ -z "$TG_DOMAIN" ]]; then
        log_err "Домен не может быть пустым!"
        pause_prompt; return
    fi

    read -rp "  Целевой IP зарубежного сервера с tproxy: " TARGET_IP
    TARGET_IP=$(echo "$TARGET_IP" | xargs | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*||')
    if [[ -z "$TARGET_IP" ]]; then
        log_err "IP зарубежного сервера обязателен!"
        pause_prompt; return
    fi

    read -rp "  Протокол на зарубежном сервере (1 - https [443], 2 - http) [1]: " PROTO_CH
    if [[ "$PROTO_CH" == "2" ]]; then
        TARGET_SCHEME="http"
        DEFAULT_PORT=80
    else
        TARGET_SCHEME="https"
        DEFAULT_PORT=443
    fi

    read -rp "  Порт на зарубежном сервере [$DEFAULT_PORT]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-$DEFAULT_PORT}

    CONF_FILE="${NGINX_HTTP_DIR}/tg_${TG_DOMAIN}.conf"
    RULE_DATA_FILE="${RULES_HTTP_DIR}/tg_${TG_DOMAIN}.json"

    # Создаем конфиг со сквозным Host, отключенной буферизацией и таймаутом 24ч
    cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    listen [::]:80;
    server_name ${TG_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${TG_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${TG_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${TG_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass ${TARGET_SCHEME}://${TARGET_IP}:${TARGET_PORT};

        # Передача оригинального Host обязательна для проверки HMAC
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_ssl_server_name on;
        proxy_ssl_name \$host;
        proxy_ssl_verify off;

        # WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Потоковая передача без задержек и буферизации
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        tcp_nodelay on;

        # Суточные таймауты
        proxy_connect_timeout 10s;
        proxy_send_timeout 86400s;
        proxy_read_timeout 86400s;
    }
}
EOF

    # Проверка SSL-сертификата
    if [ ! -f "/etc/letsencrypt/live/${TG_DOMAIN}/fullchain.pem" ]; then
        log_info "Выпуск Let's Encrypt SSL-сертификата для ${TG_DOMAIN}..."
        # Временная заглушка для выпуска certbot
        cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    listen [::]:80;
    server_name ${TG_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 200 "Certbot verification..."; }
}
EOF
        systemctl reload nginx
        certbot certonly --webroot -w /var/www/html -d "${TG_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email
        
        # Перезаписываем боевой SSL-конфиг
        add_tg_webproxy_wizard_write_conf "$CONF_FILE" "$TG_DOMAIN" "$TARGET_SCHEME" "$TARGET_IP" "$TARGET_PORT"
    fi

    nginx -t > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_err "Ошибка проверки Nginx! Проверьте корректность SSL сертификата."
        pause_prompt; return
    fi

    systemctl restart nginx

    cat <<EOF > "$RULE_DATA_FILE"
{
    "domain": "${TG_DOMAIN}",
    "target_host": "${TARGET_IP}",
    "target_port": "${TARGET_PORT}",
    "scheme": "${TARGET_SCHEME}",
    "type": "tg_webproxy",
    "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

    ensure_firewall_port 80 tcp
    ensure_firewall_port 443 tcp

    echo ""
    log_ok "Шлюз для Telegram WEB Proxy успешно запущен на https://${TG_DOMAIN} !"
    echo -e "\n  ${C_YELLOW}ВАЖНО: В панели управления tproxy на зарубежном сервере укажите домен: ${C_BOLD}${TG_DOMAIN}${C_RESET}"
    echo -e "  ${C_YELLOW}Ссылка для подключения в Telegram: https://t.me/webproxy?server=${TG_DOMAIN}&secret=ВАШ_СЕКРЕТ${C_RESET}"
    pause_prompt
}

add_tg_webproxy_wizard_write_conf() {
    local cfile="$1"
    local dom="$2"
    local sch="$3"
    local tip="$4"
    local tport="$5"

    cat <<EOF > "$cfile"
server {
    listen 80;
    listen [::]:80;
    server_name ${dom};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${dom};

    ssl_certificate /etc/letsencrypt/live/${dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${dom}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass ${sch}://${tip}:${tport};

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_ssl_server_name on;
        proxy_ssl_name \$host;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        tcp_nodelay on;

        proxy_connect_timeout 10s;
        proxy_send_timeout 86400s;
        proxy_read_timeout 86400s;
    }
}
EOF
}

# ==============================================================================
# МОДУЛЬ HTTP / STREAM / РЕДАКТИРОВАНИЕ (БАЗОВЫЙ)
# ==============================================================================

generate_http_nginx_conf() {
    local domain="$1"
    local target_host="$2"
    local target_port="$3"
    local scheme="$4"
    local host_header_mode="$5"
    local enable_cache="$6"
    local enable_ws="$7"
    local enable_limit="$8"
    local conf_out="$9"

    local ws_block=""
    if [[ "$enable_ws" == "yes" ]]; then
        ws_block="
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;"
    fi

    local cache_block=""
    if [[ "$enable_cache" == "yes" ]]; then
        cache_block="
        proxy_cache EDGE_CACHE;
        proxy_cache_valid 200 302 60m;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Cache \$upstream_cache_status always;"
    fi

    local limit_block=""
    if [[ "$enable_limit" == "yes" ]]; then
        limit_block="
        limit_req zone=edge_ip_limit burst=60 nodelay;
        limit_conn edge_conn_limit 60;"
    fi

    local host_header_val="\$host"
    if [[ "$host_header_mode" == "rewrite" ]]; then
        host_header_val="${target_host}"
    fi

    cat <<EOF > "$conf_out"
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        ${limit_block}
        ${cache_block}
        ${ws_block}

        proxy_pass ${scheme}://${target_host}:${target_port};
        proxy_set_header Host ${host_header_val};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_ssl_server_name on;
        proxy_ssl_name ${target_host};
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_verify off;
        proxy_read_timeout 90s;
    }
}
EOF
}

add_http_proxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление веб-сайта (HTTP/HTTPS -> IP или Домен)${C_RESET}\n"

    read -rp "  Введите входной домен (например, site.ru): " DOMAIN_NAME
    DOMAIN_NAME=$(echo "$DOMAIN_NAME" | xargs | tr '[:upper:]' '[:lower:]')
    if [[ -z "$DOMAIN_NAME" ]]; then
        log_err "Домен не может быть пустым!"
        pause_prompt; return
    fi

    read -rp "  Целевой IP или ДОМЕН назначения: " TARGET_HOST
    TARGET_HOST=$(echo "$TARGET_HOST" | xargs | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*||')

    read -rp "  Целевой протокол (1 - http, 2 - https) [1]: " PROTO_CHOICE
    if [[ "$PROTO_CHOICE" == "2" ]]; then
        TARGET_SCHEME="https"
        DEFAULT_PORT=443
    else
        TARGET_SCHEME="http"
        DEFAULT_PORT=80
    fi

    read -rp "  Целевой порт [$DEFAULT_PORT]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-$DEFAULT_PORT}

    read -rp "  Подменять Host-заголовок на целевой? (1 - Нет, 2 - Да) [1]: " HOST_MODE_CHOICE
    [[ "$HOST_MODE_CHOICE" == "2" ]] && HOST_MODE="rewrite" || HOST_MODE="preserve"

    read -rp "  Включить кэширование CDN? [y/N]: " ENABLE_CACHE_IN
    read -rp "  Включить поддержку WebSocket? [Y/n]: " ENABLE_WS_IN
    read -rp "  Включить защиту Rate-limit? [Y/n]: " ENABLE_LIMIT_IN

    ENABLE_CACHE="no"; [[ "$ENABLE_CACHE_IN" =~ ^[YyДд]$ ]] && ENABLE_CACHE="yes"
    ENABLE_WS="yes"; [[ "$ENABLE_WS_IN" =~ ^[Nn]$ ]] && ENABLE_WS="no"
    ENABLE_LIMIT="yes"; [[ "$ENABLE_LIMIT_IN" =~ ^[Nn]$ ]] && ENABLE_LIMIT="no"

    CONF_FILE="${NGINX_HTTP_DIR}/${DOMAIN_NAME}.conf"
    RULE_DATA_FILE="${RULES_HTTP_DIR}/${DOMAIN_NAME}.json"

    generate_http_nginx_conf "$DOMAIN_NAME" "$TARGET_HOST" "$TARGET_PORT" "$TARGET_SCHEME" \
                             "$HOST_MODE" "$ENABLE_CACHE" "$ENABLE_WS" "$ENABLE_LIMIT" "$CONF_FILE"

    nginx -t > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_err "Ошибка конфигурации Nginx!"
        rm -f "$CONF_FILE"
        pause_prompt; return
    fi

    systemctl reload nginx

    read -rp "  Выпустить бесплатный SSL Let's Encrypt? [Y/n]: " ISSUE_SSL
    SSL_ENABLED="no"
    if [[ ! "$ISSUE_SSL" =~ ^[Nn]$ ]]; then
        certbot --nginx -d "${DOMAIN_NAME}" --non-interactive --agree-tos --register-unsafely-without-email --redirect
        [[ $? -eq 0 ]] && SSL_ENABLED="yes"
    fi

    cat <<EOF > "$RULE_DATA_FILE"
{
    "domain": "${DOMAIN_NAME}",
    "target_host": "${TARGET_HOST}",
    "target_port": "${TARGET_PORT}",
    "scheme": "${TARGET_SCHEME}",
    "host_mode": "${HOST_MODE}",
    "cache": "${ENABLE_CACHE}",
    "ws": "${ENABLE_WS}",
    "limit": "${ENABLE_LIMIT}",
    "ssl": "${SSL_ENABLED}",
    "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    ensure_firewall_port 80 tcp
    ensure_firewall_port 443 tcp
    log_ok "Сайт ${DOMAIN_NAME} успешно добавлен!"
    pause_prompt
}

generate_stream_nginx_conf() {
    local l_port="$1"
    local d_host="$2"
    local d_port="$3"
    local proto="$4"
    local conf_out="$5"

    case "$proto" in
        "UDP")
            cat <<EOF > "$conf_out"
server {
    listen ${l_port} udp;
    proxy_pass ${d_host}:${d_port};
    proxy_timeout 1h;
    proxy_responses 1;
}
EOF
            ensure_firewall_port "$l_port" udp
            ;;
        "TCP+UDP")
            cat <<EOF > "$conf_out"
server {
    listen ${l_port};
    proxy_pass ${d_host}:${d_port};
    proxy_timeout 1h;
}
server {
    listen ${l_port} udp;
    proxy_pass ${d_host}:${d_port};
    proxy_timeout 1h;
}
EOF
            ensure_firewall_port "$l_port" tcp
            ensure_firewall_port "$l_port" udp
            ;;
        *)
            cat <<EOF > "$conf_out"
server {
    listen ${l_port};
    proxy_pass ${d_host}:${d_port};
    proxy_timeout 1h;
}
EOF
            ensure_firewall_port "$l_port" tcp
            ;;
    esac
}

add_stream_proxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление пересылки портов (L4 TCP/UDP Stream)${C_RESET}\n"

    read -rp "  Локальный входящий порт: " LISTEN_PORT
    read -rp "  Целевой IP/Хост назначения: " DEST_HOST
    read -rp "  Целевой порт [$LISTEN_PORT]: " DEST_PORT
    DEST_PORT=${DEST_PORT:-$LISTEN_PORT}

    read -rp "  Протокол (1 - TCP, 2 - UDP, 3 - TCP+UDP) [1]: " PROTO_CHOICE
    case "$PROTO_CHOICE" in
        2) PROTO_DESC="UDP" ;;
        3) PROTO_DESC="TCP+UDP" ;;
        *) PROTO_DESC="TCP" ;;
    esac

    RULE_ID="stream_${LISTEN_PORT}"
    CONF_FILE="${NGINX_STREAM_DIR}/${RULE_ID}.conf"
    RULE_DATA_FILE="${RULES_STREAM_DIR}/${RULE_ID}.json"

    generate_stream_nginx_conf "$LISTEN_PORT" "$DEST_HOST" "$DEST_PORT" "$PROTO_DESC" "$CONF_FILE"

    nginx -t > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_err "Ошибка конфигурации порта! Возможно он занят."
        rm -f "$CONF_FILE"
        pause_prompt; return
    fi

    systemctl reload nginx

    cat <<EOF > "$RULE_DATA_FILE"
{
    "listen_port": "${LISTEN_PORT}",
    "dest_host": "${DEST_HOST}",
    "dest_port": "${DEST_PORT}",
    "protocol": "${PROTO_DESC}",
    "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    log_ok "Порт ${LISTEN_PORT} перенаправлен на ${DEST_HOST}:${DEST_PORT} (${PROTO_DESC})!"
    pause_prompt
}

list_active_rules() {
    print_banner
    echo -e "${C_BOLD}Активные правила перенаправления трафика${C_RESET}\n"

    echo -e "${C_YELLOW}--- [ L7 ] Веб-сервисы и Сайты ---${C_RESET}"
    printf "  ${C_BOLD}%-25s %-28s %-6s %-12s${C_RESET}\n" "ДОМЕН" "НАЗНАЧЕНИЕ" "SSL" "ТИП"
    echo "  ─────────────────────────────────────────────────────────────────────────────"

    local http_count=0
    for file in "${RULES_HTTP_DIR}"/*.json; do
        if [ -f "$file" ]; then
            http_count=$((http_count + 1))
            local domain target_h target_p ssl rtype
            domain=$(jq -r '.domain' "$file")
            target_h=$(jq -r '.target_host' "$file")
            target_p=$(jq -r '.target_port' "$file")
            ssl=$(jq -r '.ssl // "no"' "$file")
            rtype=$(jq -r '.type // "HTTP"' "$file")
            
            local ssl_str="${C_RED}No${C_RESET}"
            [[ "$ssl" == "yes" ]] && ssl_str="${C_GREEN}Yes${C_RESET}"

            printf "  %-25s %-28s %-15b %-12s\n" "$domain" "${target_h}:${target_p}" "$ssl_str" "$rtype"
        fi
    done
    [[ $http_count -eq 0 ]] && echo "  (Нет активных сайтов)"

    echo -e "\n${C_YELLOW}--- [ L4 ] Порты и Стримы ---${C_RESET}"
    printf "  ${C_BOLD}%-12s %-28s %-10s${C_RESET}\n" "ВХОД ПОРТ" "НАЗНАЧЕНИЕ" "ТИП"
    echo "  ─────────────────────────────────────────────────────────────────────────────"

    local stream_count=0
    for file in "${RULES_STREAM_DIR}"/*.json; do
        if [ -f "$file" ]; then
            stream_count=$((stream_count + 1))
            local l_port d_host d_port proto
            l_port=$(jq -r '.listen_port' "$file")
            d_host=$(jq -r '.dest_host' "$file")
            d_port=$(jq -r '.dest_port' "$file")
            proto=$(jq -r '.protocol' "$file")
            printf "  %-12s %-28s %-10s\n" "$l_port" "${d_host}:${d_port}" "$proto"
        fi
    done
    [[ $stream_count -eq 0 ]] && echo "  (Нет активных стрим-портов)"

    echo ""
    pause_prompt
}

delete_rule_wizard() {
    print_banner
    echo -e "${C_BOLD}Удаление правила${C_RESET}\n"
    echo "  1. Удалить веб-сайт / шлюз"
    echo "  2. Удалить порт (L4 Stream)"
    echo "  0. Назад"
    echo ""
    read -rp "  Выбор [0-2]: " DEL_TYPE

    case "$DEL_TYPE" in
        1)
            local files=("${RULES_HTTP_DIR}"/*.json)
            [ ! -f "${files[0]}" ] && { log_warn "Нет сайтов."; pause_prompt; return; }

            local idx=1
            local domain_list=()
            for f in "${RULES_HTTP_DIR}"/*.json; do
                local d=$(jq -r '.domain' "$f")
                echo "  $idx) $d"
                domain_list+=("$d")
                idx=$((idx + 1))
            done

            read -rp "  Номер для удаления: " NUM_CH
            local SEL_D="${domain_list[$((NUM_CH - 1))]}"
            rm -f "${NGINX_HTTP_DIR}/${SEL_D}.conf"
            rm -f "${NGINX_HTTP_DIR}/tg_${SEL_D}.conf"
            rm -f "${RULES_HTTP_DIR}/${SEL_D}.json"
            rm -f "${RULES_HTTP_DIR}/tg_${SEL_D}.json"
            certbot delete --cert-name "$SEL_D" --non-interactive > /dev/null 2>&1 || true
            systemctl reload nginx
            log_ok "Правило для ${SEL_D} удалено!"
            ;;
        2)
            local files=("${RULES_STREAM_DIR}"/*.json)
            [ ! -f "${files[0]}" ] && { log_warn "Нет портов."; pause_prompt; return; }

            local idx=1
            local port_list=()
            for f in "${RULES_STREAM_DIR}"/*.json; do
                local p=$(jq -r '.listen_port' "$f")
                echo "  $idx) Порт $p"
                port_list+=("$p")
                idx=$((idx + 1))
            done

            read -rp "  Номер для удаления: " NUM_CH
            local SEL_P="${port_list[$((NUM_CH - 1))]}"
            rm -f "${NGINX_STREAM_DIR}/stream_${SEL_P}.conf"
            rm -f "${RULES_STREAM_DIR}/stream_${SEL_P}.json"
            systemctl reload nginx
            log_ok "Порт ${SEL_P} удален!"
            ;;
    esac
    pause_prompt
}

system_health_check() {
    print_banner
    echo -e "${C_BOLD}Диагностика сервера${C_RESET}\n"
    systemctl is-active --quiet nginx && echo -e "  Nginx: ${C_GREEN}Работает${C_RESET}" || echo -e "  Nginx: ${C_RED}Остановлен${C_RESET}"
    echo -e "  CPU:   ${C_CYAN}$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')%${C_RESET}"
    echo -e "  RAM:   ${C_CYAN}$(free -m | awk '/Mem:/ {printf "%d / %d MB", $3, $2}')${C_RESET}"
    echo ""
    echo -e "${C_YELLOW}Сетевые порты (Nginx LISTEN):${C_RESET}"
    ss -tulpn | grep nginx
    echo ""
    pause_prompt
}

main_menu() {
    check_root
    init_directories

    while true; do
        print_banner
        echo -e "  ${C_BOLD}Управление шлюзом перенаправления и маршрутизации:${C_RESET}\n"
        echo -e "   ${C_CYAN}1.${C_RESET} 🌐 Добавить обычный веб-сайт (L7 HTTP/HTTPS -> IP или Домен)"
        echo -e "   ${C_GREEN}2.${C_RESET} 🚀 ${C_BOLD}Добавить Telegram WEB Proxy (tproxy / Web-UI шлюз)${C_RESET}"
        echo -e "   ${C_CYAN}3.${C_RESET} 🔌 Добавить пересылку порта (L4 TCP/UDP Stream Forwarding)"
        echo -e "   ${C_CYAN}4.${C_RESET} 📋 Показать список всех активных правил"
        echo -e "   ${C_CYAN}5.${C_RESET} 🗑  Удалить правило"
        echo -e "   ${C_CYAN}6.${C_RESET} 📈 Диагностика сервера и сокетов Nginx"
        echo -e "   ${C_CYAN}7.${C_RESET} ⚡ Переустановить/Обновить Nginx"
        echo -e "   ${C_CYAN}0.${C_RESET} 🚪 Выход"
        echo ""
        read -rp "   Выберите пункт меню [0-7]: " MAIN_CHOICE

        case "$MAIN_CHOICE" in
            1) add_http_proxy_wizard ;;
            2) add_tg_webproxy_wizard ;;
            3) add_stream_proxy_wizard ;;
            4) list_active_rules ;;
            5) delete_rule_wizard ;;
            6) system_health_check ;;
            7) setup_master_nginx_conf ;;
            0) exit 0 ;;
        esac
    done
}

main_menu
