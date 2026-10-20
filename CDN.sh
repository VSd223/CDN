#!/usr/bin/env bash
# ==============================================================================
# EDGE TRAFFIC GATEWAY & SMART REVERSE PROXY MANAGER
# High-Performance HTTP/HTTPS & TCP/UDP Stream Router for Linux Servers
# ==============================================================================

set -o pipefail

# --- КОНСТАНТЫ И ПУТИ ---
APP_NAME="EdgeProxy"
APP_VERSION="3.0.0"
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
C_BG_BLUE='\033[44m'

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ВЫВОДА ---
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

# --- ПРОВЕРКА ROOT-ПРАВ ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Этот скрипт должен быть запущен с правами root (sudo)."
        exit 1
    fi
}

# --- ОПРЕДЕЛЕНИЕ ОПЕРАЦИОННОЙ СИСТЕМЫ ---
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

# --- ИНИЦИАЛИЗАЦИЯ ДИРЕКТОРИЙ ---
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

# --- УСТАНОВКА БАЗОВЫХ ПАКЕТОВ ---
install_core_dependencies() {
    print_banner
    echo -e "${C_BOLD}Шаг 1: Проверка и установка необходимых компонентов${C_RESET}\n"
    
    detect_os
    log_info "Операционная система: ${OS_ID} ${OS_VER_ID}"

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        log_info "Обновление списка пакетов APT..."
        apt-get update -y -q
        log_info "Установка Nginx, Certbot, iptables, ufw, curl, jq, fail2ban..."
        apt-get install -y -q nginx certbot python3-certbot-nginx iptables ufw \
                              curl jq fail2ban openssl ca-certificates psmisc bc dnsutils
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" ]]; then
        log_info "Установка репозитория EPEL и Nginx..."
        dnf install -y epel-release
        dnf install -y nginx certbot python3-certbot-nginx iptables-services \
                       firewalld curl jq fail2ban openssl bc bind-utils
    else
        log_err "Дистрибутив ${OS_ID} не поддерживается автоматически."
        exit 1
    fi

    log_ok "Все системные компоненты успешно установлены!"
    setup_master_nginx_conf
    apply_system_tuning
    pause_prompt
}

# --- ОПТИМИЗАЦИЯ СЕТЕВОГО СТЕКА И ВКЛЮЧЕНИЕ BBR ---
apply_system_tuning() {
    log_info "Оптимизация сетевых параметров ядра Linux (Sysctl & BBR)..."
    
    cat <<EOF > /etc/sysctl.d/99-edge-proxy.conf
# Увеличение лимитов очередей сетевых пакетов
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Буферы сокетов для высокоскоростной передачи
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Повторное использование TIME_WAIT сокетов
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Включение пересылки пакетов (Routing / Forwarding)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Ускорение TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl --system > /dev/null 2>&1 || true

    # Лимиты дескрипторов файлов
    cat <<EOF > /etc/security/limits.d/99-edge-proxy.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    log_ok "Оптимизация сетевого стека и Google BBR активированы!"
}

# --- ГЕНЕРАЦИЯ ГЛАВНОГО NGINX.CONF ---
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

# --- L4 STREAM PROXY (TCP / UDP) ---
stream {
    log_format stream_edge '\$remote_addr [\$time_local] '
                           '\$protocol \$status \$bytes_sent \$bytes_received '
                           '\$session_time "\$upstream_addr"';

    access_log ${LOG_DIR}/stream_access.log stream_edge;
    error_log ${LOG_DIR}/stream_error.log warn;

    include ${NGINX_STREAM_DIR}/*.conf;
}

# --- L7 HTTP / HTTPS PROXY ---
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # DNS резолвер для проксирования на внешние ДОМЕНЫ
    resolver 1.1.1.1 8.8.8.8 77.88.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    # Параметры производительности
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 10000;
    types_hash_max_size 2048;
    server_tokens off;

    # Ограничения размеров и таймаутов
    client_max_body_size 500M;
    client_body_buffer_size 128k;
    proxy_connect_timeout 60s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;

    # Настройки SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_dhparam /etc/edge-proxy/ssl/dhparam.pem;

    # Зоны кэширования
    proxy_cache_path ${CACHE_DIR} levels=1:2 keys_zone=EDGE_CACHE:100m max_size=5g inactive=60m use_temp_path=off;

    # Зоны ограничения частоты запросов
    limit_req_zone \$binary_remote_addr zone=edge_ip_limit:20m rate=40r/s;
    limit_conn_zone \$binary_remote_addr zone=edge_conn_limit:20m;

    # Логирование
    log_format edge_combined '\$remote_addr - \$remote_user [\$time_local] '
                             '"\$request" \$status \$body_bytes_sent '
                             '"\$http_referer" "\$http_user_agent" '
                             'rt=\$request_time uct="\$upstream_connect_time" uht="\$upstream_header_time" urt="\$upstream_response_time" '
                             'cache="\$upstream_cache_status"';

    access_log ${LOG_DIR}/http_access.log edge_combined;
    error_log ${LOG_DIR}/http_error.log warn;

    # Gzip сжатие
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
        log_ok "Главный конфиг Nginx успешно развернут и проверен!"
    else
        log_err "Ошибка в базовой структуре nginx.conf!"
    fi
}

# --- ГЕНЕРАТОР КОНФИГА HTTP/HTTPS (L7) ---
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
        proxy_set_header Connection \"upgrade\";"
    fi

    local cache_block=""
    if [[ "$enable_cache" == "yes" ]]; then
        cache_block="
        proxy_cache EDGE_CACHE;
        proxy_cache_valid 200 302 60m;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Cache \$upstream_cache_status always;
        add_header X-Cache-Lookup \"\$upstream_cache_status from Edge-Node\" always;"
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

        # --- Проксирование на целевой IP или ДОМЕН ---
        proxy_pass ${scheme}://${target_host}:${target_port};
        proxy_set_header Host ${host_header_val};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Поддержка SSL SNI если цель домен
        proxy_ssl_server_name on;
        proxy_ssl_name ${target_host};
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_read_timeout 90s;

        # --- Метки CDN для чекеров ---
        add_header Via "1.1 Edge-CDN-Gateway" always;
        add_header X-CDN "Edge-Network-Distribution" always;
        add_header X-Served-By "Edge-RU-Node-01" always;

        # Маскировка заголовка сервера
        proxy_hide_header Server;
        add_header Server "Edge-CDN" always;
    }
}
EOF
}

# ==============================================================================
# МОДУЛЬ 1: L7 HTTP / HTTPS REVERSE PROXY
# ==============================================================================

add_http_proxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление веб-сайта (HTTP/HTTPS -> IP или Домен)${C_RESET}\n"

    read -rp "  Введите входной домен (например, site.ru или sub.mysite.com): " DOMAIN_NAME
    DOMAIN_NAME=$(echo "$DOMAIN_NAME" | xargs | tr '[:upper:]' '[:lower:]')
    if [[ -z "$DOMAIN_NAME" ]]; then
        log_err "Домен не может быть пустым!"
        pause_prompt; return
    fi

    read -rp "  Целевой IP или ДОМЕН назначения (куда слать трафик): " TARGET_HOST
    TARGET_HOST=$(echo "$TARGET_HOST" | xargs | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*||')
    if [[ -z "$TARGET_HOST" ]]; then
        log_err "Целевой хост обязателен!"
        pause_prompt; return
    fi

    read -rp "  Целевой протокол (1 - http, 2 - https) [1]: " PROTO_CHOICE
    if [[ "$PROTO_CHOICE" == "2" ]]; then
        TARGET_SCHEME="https"
        DEFAULT_PORT=443
    else
        TARGET_SCHEME="http"
        DEFAULT_PORT=80
    fi

    read -rp "  Целевой порт [по умолчанию $DEFAULT_PORT]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-$DEFAULT_PORT}

    echo ""
    echo "  Как передавать Host-заголовок на целевой сервер?"
    echo "  1) Передавать исходный Host клиента ($DOMAIN_NAME) [Стандартно для своего сервера]"
    echo "  2) Подменять Host на целевой ($TARGET_HOST) [Нужно, если бэкенд на Cloudflare/хостинге]"
    read -rp "  Выберите режим [1]: " HOST_MODE_CHOICE
    if [[ "$HOST_MODE_CHOICE" == "2" ]]; then
        HOST_MODE="rewrite"
    else
        HOST_MODE="preserve"
    fi

    echo ""
    read -rp "  Включить кэширование статических файлов (CDN режим)? [y/N]: " ENABLE_CACHE_IN
    read -rp "  Включить поддержку WebSocket (для ботов, чатов, веб-сокетов)? [Y/n]: " ENABLE_WS_IN
    read -rp "  Включить защиту от спам-запросов (Rate-limit)? [Y/n]: " ENABLE_LIMIT_IN

    ENABLE_CACHE="no"
    [[ "$ENABLE_CACHE_IN" =~ ^[YyДд]$ ]] && ENABLE_CACHE="yes"

    ENABLE_WS="yes"
    [[ "$ENABLE_WS_IN" =~ ^[Nn]$ ]] && ENABLE_WS="no"

    ENABLE_LIMIT="yes"
    [[ "$ENABLE_LIMIT_IN" =~ ^[Nn]$ ]] && ENABLE_LIMIT="no"

    CONF_FILE="${NGINX_HTTP_DIR}/${DOMAIN_NAME}.conf"
    RULE_DATA_FILE="${RULES_HTTP_DIR}/${DOMAIN_NAME}.json"

    generate_http_nginx_conf "$DOMAIN_NAME" "$TARGET_HOST" "$TARGET_PORT" "$TARGET_SCHEME" \
                             "$HOST_MODE" "$ENABLE_CACHE" "$ENABLE_WS" "$ENABLE_LIMIT" "$CONF_FILE"

    nginx -t > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_err "Ошибка конфигурации Nginx! Проверьте введенные параметры."
        rm -f "$CONF_FILE"
        pause_prompt; return
    fi

    systemctl reload nginx
    log_ok "Базовое перенаправление HTTP успешно создано!"

    # Запрос на SSL Let's Encrypt
    echo ""
    read -rp "  Выпустить бесплатный официальный SSL-сертификат Let's Encrypt? [Y/n]: " ISSUE_SSL
    SSL_ENABLED="no"
    if [[ ! "$ISSUE_SSL" =~ ^[Nn]$ ]]; then
        log_info "Запуск Certbot для домена ${DOMAIN_NAME}..."
        certbot --nginx -d "${DOMAIN_NAME}" --non-interactive --agree-tos --register-unsafely-without-email --redirect
        if [ $? -eq 0 ]; then
            log_ok "SSL Let's Encrypt успешно настроен и включен!"
            SSL_ENABLED="yes"
        else
            log_warn "Не удалось выпустить сертификат. Убедитесь, что A-запись домена указывает на IP этого сервера!"
        fi
    fi

    # Сохраняем правило в JSON
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

    log_ok "Правило для домена ${DOMAIN_NAME} активно работает!"
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 2: L4 PORT FORWARDING (TCP & UDP STREAM)
# ==============================================================================

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
    proxy_connect_timeout 10s;
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
    proxy_connect_timeout 10s;
}
EOF
            ensure_firewall_port "$l_port" tcp
            ;;
    esac
}

add_stream_proxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление пересылки портов (L4 TCP/UDP Stream)${C_RESET}\n"

    read -rp "  Введите локальный входящий порт (Listen Port): " LISTEN_PORT
    if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
        log_err "Неверный номер порта!"
        pause_prompt; return
    fi

    read -rp "  Целевой IP-адрес или ДОМЕН назначения: " DEST_HOST
    DEST_HOST=$(echo "$DEST_HOST" | xargs)
    if [[ -z "$DEST_HOST" ]]; then
        log_err "Адрес назначения обязателен!"
        pause_prompt; return
    fi

    read -rp "  Целевой порт назначения [по умолчанию $LISTEN_PORT]: " DEST_PORT
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
        log_err "Ошибка конфигурации Nginx Stream! Возможно порт ${LISTEN_PORT} уже занят."
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

    log_ok "Перенаправление порта ${LISTEN_PORT} -> ${DEST_HOST}:${DEST_PORT} (${PROTO_DESC}) запущено!"
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 3: РЕДАКТИРОВАНИЕ ПРАВИЛ
# ==============================================================================

edit_rule_wizard() {
    print_banner
    echo -e "${C_BOLD}Редактирование существующего правила${C_RESET}\n"
    echo "  1. Редактировать веб-сайт (L7 HTTP/HTTPS)"
    echo "  2. Редактировать порт (L4 TCP/UDP Stream)"
    echo "  0. Назад"
    echo ""
    read -rp "  Выберите категорию [0-2]: " EDIT_TYPE

    case "$EDIT_TYPE" in
        1)
            local files=("${RULES_HTTP_DIR}"/*.json)
            if [ ! -f "${files[0]}" ]; then
                log_warn "Нет добавленных веб-сайтов для редактирования."
                pause_prompt; return
            fi

            echo -e "\n  ${C_YELLOW}Список сайтов:${C_RESET}"
            local idx=1
            local domain_list=()
            for f in "${RULES_HTTP_DIR}"/*.json; do
                local d
                d=$(jq -r '.domain' "$f")
                echo "  $idx) $d"
                domain_list+=("$d")
                idx=$((idx + 1))
            done

            echo ""
            read -rp "  Выберите номер сайта для изменения: " NUM_CH
            if ! [[ "$NUM_CH" =~ ^[0-9]+$ ]] || [ "$NUM_CH" -lt 1 ] || [ "$NUM_CH" -gt "${#domain_list[@]}" ]; then
                log_err "Неверный номер!"
                pause_prompt; return
            fi

            local SEL_DOMAIN="${domain_list[$((NUM_CH - 1))]}"
            local JSON_FILE="${RULES_HTTP_DIR}/${SEL_DOMAIN}.json"
            local CONF_FILE="${NGINX_HTTP_DIR}/${SEL_DOMAIN}.conf"

            local cur_target_host cur_target_port cur_scheme cur_host_mode cur_cache cur_ws cur_limit cur_ssl
            cur_target_host=$(jq -r '.target_host' "$JSON_FILE")
            cur_target_port=$(jq -r '.target_port' "$JSON_FILE")
            cur_scheme=$(jq -r '.scheme' "$JSON_FILE")
            cur_host_mode=$(jq -r '.host_mode // "preserve"' "$JSON_FILE")
            cur_cache=$(jq -r '.cache // "no"' "$JSON_FILE")
            cur_ws=$(jq -r '.ws // "yes"' "$JSON_FILE")
            cur_limit=$(jq -r '.limit // "yes"' "$JSON_FILE")
            cur_ssl=$(jq -r '.ssl // "no"' "$JSON_FILE")

            echo -e "\n  ${C_CYAN}Редактирование параметров для: ${C_BOLD}${SEL_DOMAIN}${C_RESET}\n"

            read -rp "  Целевой IP или ДОМЕН [$cur_target_host]: " NEW_TARGET_HOST
            NEW_TARGET_HOST=${NEW_TARGET_HOST:-$cur_target_host}

            read -rp "  Целевой протокол (http/https) [$cur_scheme]: " NEW_SCHEME
            NEW_SCHEME=${NEW_SCHEME:-$cur_scheme}

            read -rp "  Целевой порт [$cur_target_port]: " NEW_TARGET_PORT
            NEW_TARGET_PORT=${NEW_TARGET_PORT:-$cur_target_port}

            read -rp "  Подменять Host на целевой домен? (1 - Нет, 2 - Да) [$([ "$cur_host_mode" == "rewrite" ] && echo 2 || echo 1)]: " NEW_HM_CHOICE
            if [[ "$NEW_HM_CHOICE" == "2" ]]; then
                NEW_HOST_MODE="rewrite"
            elif [[ "$NEW_HM_CHOICE" == "1" ]]; then
                NEW_HOST_MODE="preserve"
            else
                NEW_HOST_MODE="$cur_host_mode"
            fi

            read -rp "  Кэширование CDN (yes/no) [$cur_cache]: " NEW_CACHE
            NEW_CACHE=${NEW_CACHE:-$cur_cache}

            read -rp "  Поддержка WebSocket (yes/no) [$cur_ws]: " NEW_WS
            NEW_WS=${NEW_WS:-$cur_ws}

            read -rp "  Лимит запросов Rate-limit (yes/no) [$cur_limit]: " NEW_LIMIT
            NEW_LIMIT=${NEW_LIMIT:-$cur_limit}

            generate_http_nginx_conf "$SEL_DOMAIN" "$NEW_TARGET_HOST" "$NEW_TARGET_PORT" "$NEW_SCHEME" \
                                     "$NEW_HOST_MODE" "$NEW_CACHE" "$NEW_WS" "$NEW_LIMIT" "$CONF_FILE"

            # Если был SSL — заново подключаем
            if [[ "$cur_ssl" == "yes" ]]; then
                certbot --nginx -d "${SEL_DOMAIN}" --non-interactive --redirect > /dev/null 2>&1 || true
            fi

            nginx -t > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                log_err "Ошибка в новых параметрах! Откат изменений..."
                git checkout "$CONF_FILE" 2>/dev/null || true
                pause_prompt; return
            fi

            systemctl reload nginx

            cat <<EOF > "$JSON_FILE"
{
    "domain": "${SEL_DOMAIN}",
    "target_host": "${NEW_TARGET_HOST}",
    "target_port": "${NEW_TARGET_PORT}",
    "scheme": "${NEW_SCHEME}",
    "host_mode": "${NEW_HOST_MODE}",
    "cache": "${NEW_CACHE}",
    "ws": "${NEW_WS}",
    "limit": "${NEW_LIMIT}",
    "ssl": "${cur_ssl}",
    "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
            log_ok "Правило для домена ${SEL_DOMAIN} успешно обновлено!"
            pause_prompt
            ;;

        2)
            local files=("${RULES_STREAM_DIR}"/*.json)
            if [ ! -f "${files[0]}" ]; then
                log_warn "Нет активных перенаправлений портов."
                pause_prompt; return
            fi

            echo -e "\n  ${C_YELLOW}Список перенаправлений портов:${C_RESET}"
            local idx=1
            local port_list=()
            for f in "${RULES_STREAM_DIR}"/*.json; do
                local p
                p=$(jq -r '.listen_port' "$f")
                echo "  $idx) Входящий порт $p"
                port_list+=("$p")
                idx=$((idx + 1))
            done

            echo ""
            read -rp "  Выберите номер порта для изменения: " NUM_CH
            if ! [[ "$NUM_CH" =~ ^[0-9]+$ ]] || [ "$NUM_CH" -lt 1 ] || [ "$NUM_CH" -gt "${#port_list[@]}" ]; then
                log_err "Неверный номер!"
                pause_prompt; return
            fi

            local SEL_PORT="${port_list[$((NUM_CH - 1))]}"
            local JSON_FILE="${RULES_STREAM_DIR}/stream_${SEL_PORT}.json"
            local CONF_FILE="${NGINX_STREAM_DIR}/stream_${SEL_PORT}.conf"

            local cur_d_host cur_d_port cur_proto
            cur_d_host=$(jq -r '.dest_host' "$JSON_FILE")
            cur_d_port=$(jq -r '.dest_port' "$JSON_FILE")
            cur_proto=$(jq -r '.protocol' "$JSON_FILE")

            echo -e "\n  ${C_CYAN}Редактирование порта: ${C_BOLD}${SEL_PORT}${C_RESET}\n"

            read -rp "  Целевой IP/Домен [$cur_d_host]: " NEW_D_HOST
            NEW_D_HOST=${NEW_D_HOST:-$cur_d_host}

            read -rp "  Целевой порт [$cur_d_port]: " NEW_D_PORT
            NEW_D_PORT=${NEW_D_PORT:-$cur_d_port}

            read -rp "  Протокол (TCP, UDP, TCP+UDP) [$cur_proto]: " NEW_PROTO
            NEW_PROTO=${NEW_PROTO:-$cur_proto}

            generate_stream_nginx_conf "$SEL_PORT" "$NEW_D_HOST" "$NEW_D_PORT" "$NEW_PROTO" "$CONF_FILE"

            nginx -t > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                log_err "Ошибка конфигурации порта! Откат..."
                pause_prompt; return
            fi

            systemctl reload nginx

            cat <<EOF > "$JSON_FILE"
{
    "listen_port": "${SEL_PORT}",
    "dest_host": "${NEW_D_HOST}",
    "dest_port": "${NEW_D_PORT}",
    "protocol": "${NEW_PROTO}",
    "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
            log_ok "Правило для порта ${SEL_PORT} успешно обновлено!"
            pause_prompt
            ;;
        *)
            return
            ;;
    esac
}

# ==============================================================================
# МОДУЛЬ 4: СПИСОК ПРАВИЛ И УДАЛЕНИЕ
# ==============================================================================

list_active_rules() {
    print_banner
    echo -e "${C_BOLD}Активные правила перенаправления трафика${C_RESET}\n"

    echo -e "${C_YELLOW}--- [ L7 ] Сайты и Веб-сервисы (HTTP/HTTPS) ---${C_RESET}"
    printf "  ${C_BOLD}%-25s %-28s %-6s %-7s %-8s${C_RESET}\n" "ДОМЕН" "НАЗНАЧЕНИЕ" "SSL" "ПРОТО" "CDN-КЭШ"
    echo "  ─────────────────────────────────────────────────────────────────────────────"

    local http_count=0
    for file in "${RULES_HTTP_DIR}"/*.json; do
        if [ -f "$file" ]; then
            http_count=$((http_count + 1))
            local domain target_h target_p scheme ssl cache
            domain=$(jq -r '.domain' "$file")
            target_h=$(jq -r '.target_host' "$file")
            target_p=$(jq -r '.target_port' "$file")
            scheme=$(jq -r '.scheme' "$file")
            ssl=$(jq -r '.ssl // "no"' "$file")
            cache=$(jq -r '.cache // "no"' "$file")
            
            local ssl_str="${C_RED}No${C_RESET}"
            [[ "$ssl" == "yes" ]] && ssl_str="${C_GREEN}Yes${C_RESET}"

            local cache_str="${C_RED}Off${C_RESET}"
            [[ "$cache" == "yes" ]] && cache_str="${C_GREEN}On${C_RESET}"

            printf "  %-25s %-28s %-15b %-7s %-16b\n" "$domain" "${target_h}:${target_p}" "$ssl_str" "$scheme" "$cache_str"
        fi
    done
    if [ $http_count -eq 0 ]; then
        echo "  (Нет добавленных HTTP/HTTPS доменов)"
    fi

    echo ""
    echo -e "${C_YELLOW}--- [ L4 ] Порты и Стримы (TCP/UDP) ---${C_RESET}"
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
    if [ $stream_count -eq 0 ]; then
        echo "  (Нет активных правил пересылки портов)"
    fi

    echo ""
    pause_prompt
}

delete_rule_wizard() {
    print_banner
    echo -e "${C_BOLD}Удаление правила перенаправления${C_RESET}\n"
    echo "  1. Удалить веб-сайт (L7 HTTP/HTTPS)"
    echo "  2. Удалить пересылку порта (L4 TCP/UDP)"
    echo "  0. Назад"
    echo ""
    read -rp "  Ваш выбор [0-2]: " DEL_TYPE

    case "$DEL_TYPE" in
        1)
            local files=("${RULES_HTTP_DIR}"/*.json)
            if [ ! -f "${files[0]}" ]; then
                log_warn "Нет добавленных веб-сайтов для удаления."
                pause_prompt; return
            fi

            echo -e "\n  ${C_YELLOW}Список сайтов:${C_RESET}"
            local idx=1
            local domain_list=()
            for f in "${RULES_HTTP_DIR}"/*.json; do
                local d
                d=$(jq -r '.domain' "$f")
                echo "  $idx) $d"
                domain_list+=("$d")
                idx=$((idx + 1))
            done

            echo ""
            read -rp "  Выберите номер сайта для УДАЛЕНИЯ: " NUM_CH
            if ! [[ "$NUM_CH" =~ ^[0-9]+$ ]] || [ "$NUM_CH" -lt 1 ] || [ "$NUM_CH" -gt "${#domain_list[@]}" ]; then
                log_err "Неверный номер!"
                pause_prompt; return
            fi

            local DEL_DOMAIN="${domain_list[$((NUM_CH - 1))]}"
            rm -f "${NGINX_HTTP_DIR}/${DEL_DOMAIN}.conf"
            rm -f "${RULES_HTTP_DIR}/${DEL_DOMAIN}.json"

            # Удаление сертификата Certbot если был
            certbot delete --cert-name "$DEL_DOMAIN" --non-interactive > /dev/null 2>&1 || true

            systemctl reload nginx
            log_ok "Правило для домена ${DEL_DOMAIN} полностью удалено!"
            ;;
        2)
            local files=("${RULES_STREAM_DIR}"/*.json)
            if [ ! -f "${files[0]}" ]; then
                log_warn "Нет активных перенаправлений портов."
                pause_prompt; return
            fi

            echo -e "\n  ${C_YELLOW}Список портов:${C_RESET}"
            local idx=1
            local port_list=()
            for f in "${RULES_STREAM_DIR}"/*.json; do
                local p
                p=$(jq -r '.listen_port' "$f")
                echo "  $idx) Порт $p"
                port_list+=("$p")
                idx=$((idx + 1))
            done

            echo ""
            read -rp "  Выберите номер порта для УДАЛЕНИЯ: " NUM_CH
            if ! [[ "$NUM_CH" =~ ^[0-9]+$ ]] || [ "$NUM_CH" -lt 1 ] || [ "$NUM_CH" -gt "${#port_list[@]}" ]; then
                log_err "Неверный номер!"
                pause_prompt; return
            fi

            local DEL_PORT="${port_list[$((NUM_CH - 1))]}"
            rm -f "${NGINX_STREAM_DIR}/stream_${DEL_PORT}.conf"
            rm -f "${RULES_STREAM_DIR}/stream_${DEL_PORT}.json"

            systemctl reload nginx
            log_ok "Перенаправление порта ${DEL_PORT} удалено!"
            ;;
        *)
            return
            ;;
    esac
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 5: ФАЕРВОЛ И БЕЗОПАСНОСТЬ
# ==============================================================================

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

security_menu() {
    while true; do
        print_banner
        echo -e "${C_BOLD}Центр безопасности и защита от атак${C_RESET}\n"
        echo "  1. Заблокировать подозрительный IP (iptables DROP)"
        echo "  2. Разблокировать IP-адрес"
        echo "  3. Просмотреть заблокированные IP"
        echo "  4. Включить / Настроить UFW Фаервол"
        echo "  5. Перевыпустить все SSL-сертификаты Certbot"
        echo "  0. Назад в главное меню"
        echo ""
        read -rp "  Выберите действие [0-5]: " SEC_CHOICE

        case "$SEC_CHOICE" in
            1)
                read -rp "  Введите IP для полной блокировки: " BLOCK_IP
                if [[ -n "$BLOCK_IP" ]]; then
                    iptables -I INPUT -s "$BLOCK_IP" -j DROP
                    log_ok "IP $BLOCK_IP добавлен в бан через iptables DROP!"
                fi
                pause_prompt
                ;;
            2)
                read -rp "  Введите IP для разблокировки: " UNBLOCK_IP
                if [[ -n "$UNBLOCK_IP" ]]; then
                    iptables -D INPUT -s "$UNBLOCK_IP" -j DROP 2>/dev/null || true
                    log_ok "IP $UNBLOCK_IP разблокирован!"
                fi
                pause_prompt
                ;;
            3)
                echo -e "\n${C_YELLOW}Список заблокированных IP:${C_RESET}"
                iptables -L INPUT -v -n | grep DROP || echo "  (Список пуст)"
                pause_prompt
                ;;
            4)
                if command -v ufw &>/dev/null; then
                    ufw default deny incoming
                    ufw default allow outgoing
                    ufw allow 22/tcp
                    ufw allow 80/tcp
                    ufw allow 443/tcp
                    echo "y" | ufw enable
                    log_ok "Фаервол UFW включен! Порты 22, 80, 443 открыты."
                else
                    log_err "UFW не установлен в системе."
                fi
                pause_prompt
                ;;
            5)
                log_info "Проверка и продление всех сертификатов Certbot..."
                certbot renew
                systemctl reload nginx
                pause_prompt
                ;;
            0)
                break
                ;;
        esac
    done
}

# ==============================================================================
# МОДУЛЬ 6: МОНИТОРИНГ И ДИАГНОСТИКА
# ==============================================================================

live_monitor() {
    print_banner
    echo -e "${C_BOLD}Живой мониторинг трафика Nginx (Нажмите Ctrl+C для выхода)${C_RESET}\n"
    
    [ ! -f "${LOG_DIR}/http_access.log" ] && touch "${LOG_DIR}/http_access.log"

    tail -f "${LOG_DIR}/http_access.log" | awk '
    {
        ip=$1;
        time=$4;
        method=$6;
        url=$7;
        status=$9;
        rt=$(NF-1);
        
        gsub(/"/, "", method);
        gsub(/\[/, "", time);

        if (status ~ /^2/) { color="\033[0;32m" }
        else if (status ~ /^3/) { color="\033[0;36m" }
        else if (status ~ /^4/) { color="\033[1;33m" }
        else { color="\033[0;31m" }

        printf "%s \033[1m%-15s\033[0m %-6s %-30s %b%-4s\033[0m %s\n", time, ip, method, url, color, status, rt
    }'
}

system_health_check() {
    print_banner
    echo -e "${C_BOLD}Диагностика состояния сервера и шлюза${C_RESET}\n"

    if systemctl is-active --quiet nginx; then
        echo -e "  Служба Nginx:           ${C_GREEN}Работает (Active)${C_RESET}"
    else
        echo -e "  Служба Nginx:           ${C_RED}Остановлена (Failed)${C_RESET}"
    fi

    echo -e "  Нагрузка CPU:           ${C_CYAN}$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')%${C_RESET}"
    echo -e "  Оперативная память:     ${C_CYAN}$(free -m | awk '/Mem:/ {printf "%d / %d MB (%.1f%%)", $3, $2, $3*100/$2}')${C_RESET}"
    echo -e "  Диск:                   ${C_CYAN}$(df -h / | awk 'NR==2 {print $4 " свободно (" $5 " занято)"}')${C_RESET}"

    local conn_count
    conn_count=$(ss -t state established 2>/dev/null | wc -l)
    echo -e "  Активных TCP-сессий:    ${C_YELLOW}${conn_count}${C_RESET}"

    local bbr_status
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "  Алгоритм TCP:           ${C_GREEN}${bbr_status}${C_RESET}"

    echo ""
    echo -e "${C_YELLOW}Сетевые сокеты шлюза (Прослушиваемые порты):${C_RESET}"
    ss -tulnp | grep -E 'nginx|LISTEN' | head -n 12

    echo ""
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 7: РЕЗЕРВНОЕ КОПИРОВАНИЕ
# ==============================================================================

create_backup() {
    print_banner
    local bkp_file="${BACKUP_DIR}/backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
    log_info "Создание резервной копии конфигураций..."
    
    tar -czf "$bkp_file" -C /etc edge-proxy nginx > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_ok "Резервная копия сохранена в: ${C_CYAN}${bkp_file}${C_RESET}"
    else
        log_err "Не удалось создать резервную копию!"
    fi
    pause_prompt
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

main_menu() {
    check_root
    init_directories

    while true; do
        print_banner
        echo -e "  ${C_BOLD}Управление шлюзом перенаправления и маршрутизации:${C_RESET}\n"
        echo -e "   ${C_CYAN}1.${C_RESET} 🌐 Добавить веб-сайт (L7 HTTP/HTTPS -> на любой IP или ДОМЕН)"
        echo -e "   ${C_CYAN}2.${C_RESET} 🔌 Добавить пересылку порта (L4 TCP/UDP Stream Forwarding)"
        echo -e "   ${C_CYAN}3.${C_RESET} 📋 Показать список всех активных правил"
        echo -e "   ${C_CYAN}4.${C_RESET} ✏️  Редактировать правило (изменить цель, порт, SSL, кэш)"
        echo -e "   ${C_CYAN}5.${C_RESET} 🗑  Удалить правило (сайт или порт)"
        echo -e "   ${C_CYAN}6.${C_RESET} 📈 Диагностика сервера и сетевые показатели"
        echo -e "   ${C_CYAN}7.${C_RESET} 👁  Живой просмотр логов входящего трафика"
        echo -e "   ${C_CYAN}8.${C_RESET} 🛡  Центр безопасности, защита и фаервол"
        echo -e "   ${C_CYAN}9.${C_RESET} 💾 Создать резервную копию настроек (Backup)"
        echo -e "   ${C_CYAN}10.${C_RESET}⚡ Переустановить/Обновить ядро Nginx и зависимости"
        echo -e "   ${C_CYAN}0.${C_RESET} 🚪 Выход из программы"
        echo ""
        read -rp "   Выберите пункт меню [0-10]: " MAIN_CHOICE

        case "$MAIN_CHOICE" in
            1) add_http_proxy_wizard ;;
            2) add_stream_proxy_wizard ;;
            3) list_active_rules ;;
            4) edit_rule_wizard ;;
            5) delete_rule_wizard ;;
            6) system_health_check ;;
            7) live_monitor ;;
            8) security_menu ;;
            9) create_backup ;;
            10) install_core_dependencies ;;
            0)
                echo -e "\n  ${C_GREEN}Работа завершена. Все службы продолжают работу в фоне.${C_RESET}\n"
                exit 0
                ;;
            *)
                log_warn "Неверный пункт меню!"
                sleep 1
                ;;
        esac
    done
}

# Старт скрипта
main_menu
