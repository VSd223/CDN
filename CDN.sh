#!/usr/bin/env bash
# ==============================================================================
# EDGE TRAFFIC GATEWAY & SMART REVERSE PROXY MANAGER
# High-Performance HTTP/HTTPS & TCP/UDP Stream Router for Linux Servers
# ==============================================================================

set -o pipefail

# --- КОНСТАНТЫ И ПУТИ ---
APP_NAME="EdgeProxy"
APP_VERSION="2.4.0"
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
             "/etc/edge-proxy/ssl"
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
                              curl jq fail2ban openssl ca-certificates psmisc bc
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" ]]; then
        log_info "Установка репозитория EPEL и Nginx..."
        dnf install -y epel-release
        dnf install -y nginx certbot python3-certbot-nginx iptables-services \
                       firewalld curl jq fail2ban openssl bc
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
    
    # Генерация надежного Diffie-Hellman ключа, если его еще нет
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

    # Основные параметры производительности
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

    # Зоны ограничения частоты запросов (Rate Limiting)
    limit_req_zone \$binary_remote_addr zone=edge_ip_limit:20m rate=30r/s;
    limit_conn_zone \$binary_remote_addr zone=edge_conn_limit:20m;

    # Логирование
    log_format edge_combined '\$remote_addr - \$remote_user [\$time_local] '
                             '"\$request" \$status \$body_bytes_sent '
                             '"\$http_referer" "\$http_user_agent" '
                             'rt=\$request_time uct="\$upstream_connect_time" uht="\$upstream_header_time" urt="\$upstream_response_time" '
                             'cache="\$upstream_cache_status"';

    access_log ${LOG_DIR}/http_access.log edge_combined;
    error_log ${LOG_DIR}/http_error.log warn;

    # Включение сжатия Gzip
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
        log_err "Ошибка в базовой структуре nginx.conf! Проверьте Nginx вручную."
    fi
}

# ==============================================================================
# МОДУЛЬ 1: L7 HTTP / HTTPS REVERSE PROXY
# ==============================================================================

add_http_proxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление нового сайта / домена (HTTP/HTTPS Reverse Proxy)${C_RESET}\n"

    read -rp "  Введите домен (например, site.ru или sub.example.com): " DOMAIN_NAME
    DOMAIN_NAME=$(echo "$DOMAIN_NAME" | xargs | tr '[:upper:]' '[:lower:]')
    if [[ -z "$DOMAIN_NAME" ]]; then
        log_err "Домен не может быть пустым!"
        pause_prompt; return
    fi

    read -rp "  Целевой IP-адрес/Хост (куда слать трафик): " TARGET_HOST
    TARGET_HOST=$(echo "$TARGET_HOST" | xargs)
    if [[ -z "$TARGET_HOST" ]]; then
        log_err "Целевой хост обязателен!"
        pause_prompt; return
    fi

    read -rp "  Целевой порт [по умолчанию 80]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-80}

    read -rp "  Целевой протокол (1 - http, 2 - https) [1]: " PROTO_CHOICE
    if [[ "$PROTO_CHOICE" == "2" ]]; then
        TARGET_SCHEME="https"
    else
        TARGET_SCHEME="http"
    fi

    echo ""
    read -rp "  Включить кэширование статических файлов (CDN режим)? [y/N]: " ENABLE_CACHE
    read -rp "  Включить поддержку WebSocket (для ботов, сокетов, чатов)? [Y/n]: " ENABLE_WS
    read -rp "  Включить защиту от спам-запросов (Rate-limit)? [Y/n]: " ENABLE_LIMIT

    CONF_FILE="${NGINX_HTTP_DIR}/${DOMAIN_NAME}.conf"
    RULE_DATA_FILE="${RULES_HTTP_DIR}/${DOMAIN_NAME}.json"

    # Сборка секций
    WS_CONFIG=""
    if [[ ! "$ENABLE_WS" =~ ^[Nn]$ ]]; then
        WS_CONFIG="
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";"
    fi

    CACHE_CONFIG=""
    if [[ "$ENABLE_CACHE" =~ ^[YyДд]$ ]]; then
        CACHE_CONFIG="
        proxy_cache EDGE_CACHE;
        proxy_cache_valid 200 302 30m;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Cache-Status \$upstream_cache_status;"
    fi

    LIMIT_CONFIG=""
    if [[ ! "$ENABLE_LIMIT" =~ ^[Nn]$ ]]; then
        LIMIT_CONFIG="
        limit_req zone=edge_ip_limit burst=50 nodelay;
        limit_conn edge_conn_limit 50;"
    fi

    # Генерация первичного HTTP конфига
    cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    listen [::]:80;
    server_name ваш_домен.ru;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        # Проксирование на ваш сервер
        proxy_pass http://IP_ВАШЕГО_БЭКЕНДА:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Поддержка WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_ssl_server_name on;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_read_timeout 90s;

        # Кэширование статики
        proxy_cache EDGE_CACHE;
        proxy_cache_valid 200 302 60m;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

        # CDN метки для чекеров
        add_header X-Cache $upstream_cache_status always;
        add_header X-Cache-Lookup "$upstream_cache_status from Edge-Node" always;
        add_header Via "1.1 Edge-CDN-Gateway" always;
        add_header X-CDN "Edge-Network-Distribution" always;
        add_header X-Served-By "Edge-RU-Node-01" always;

        # Маскировка сервера
        proxy_hide_header Server;
        add_header Server "Edge-CDN" always;
    }
}
EOF

    nginx -t > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_err "Ошибка конфигурации Nginx! Удаляем временный файл."
        rm -f "$CONF_FILE"
        pause_prompt; return
    fi

    systemctl reload nginx
    log_ok "Базовая переадресация HTTP настроена успешно!"

    # Спрашиваем про SSL Let's Encrypt
    echo ""
    read -rp "  Желаете выпустить бесплатный официальный SSL-сертификат Let's Encrypt? [Y/n]: " ISSUE_SSL
    SSL_ENABLED="no"
    if [[ ! "$ISSUE_SSL" =~ ^[Nn]$ ]]; then
        log_info "Запуск Certbot для домена ${DOMAIN_NAME}..."
        mkdir -p /var/www/html
        certbot --nginx -d "${DOMAIN_NAME}" --non-interactive --agree-tos --register-unsafely-without-email --redirect
        if [ $? -eq 0 ]; then
            log_ok "SSL-сертификат Let's Encrypt успешно настроен и активирован!"
            SSL_ENABLED="yes"
        else
            log_warn "Не удалось автоматически выпустить сертификат."
            log_warn "Убедитесь, что A-запись домена ${DOMAIN_NAME} указывает на IP этого сервера!"
        fi
    fi

    # Сохраняем информацию о правиле в JSON-базу
    cat <<EOF > "$RULE_DATA_FILE"
{
    "domain": "${DOMAIN_NAME}",
    "target_host": "${TARGET_HOST}",
    "target_port": "${TARGET_PORT}",
    "scheme": "${TARGET_SCHEME}",
    "ssl": "${SSL_ENABLED}",
    "created_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

    # Открытие 80 и 443 портов в фаерволе
    ensure_firewall_port 80 tcp
    ensure_firewall_port 443 tcp

    log_ok "Правило для домена ${DOMAIN_NAME} успешно создано и запущено!"
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 2: L4 PORT FORWARDING (TCP & UDP STREAM)
# ==============================================================================

add_stream_proxy_wizard() {
    print_banner
    echo -e "${C_BOLD}Добавление пересылки портов (L4 TCP/UDP Port Forwarding)${C_RESET}\n"
    echo -e "  Пересылает сырой трафик на уровне портов (для баз данных, игр, ботов, VPN)."
    echo ""

    read -rp "  Введите локальный входящий порт (Listen Port): " LISTEN_PORT
    if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
        log_err "Неверный номер порта!"
        pause_prompt; return
    fi

    read -rp "  Целевой IP-адрес/Хост назначения: " DEST_HOST
    DEST_HOST=$(echo "$DEST_HOST" | xargs)
    if [[ -z "$DEST_HOST" ]]; then
        log_err "IP назначения обязателен!"
        pause_prompt; return
    fi

    read -rp "  Целевой порт назначения [по умолчанию $LISTEN_PORT]: " DEST_PORT
    DEST_PORT=${DEST_PORT:-$LISTEN_PORT}

    read -rp "  Протокол (1 - TCP, 2 - UDP, 3 - TCP+UDP) [1]: " PROTO_CHOICE

    RULE_ID="stream_${LISTEN_PORT}"
    CONF_FILE="${NGINX_STREAM_DIR}/${RULE_ID}.conf"
    RULE_DATA_FILE="${RULES_STREAM_DIR}/${RULE_ID}.json"

    STREAM_BLOCK=""

    case "$PROTO_CHOICE" in
        2)
            PROTO_DESC="UDP"
            STREAM_BLOCK="
server {
    listen ${LISTEN_PORT} udp;
    proxy_pass ${DEST_HOST}:${DEST_PORT};
    proxy_timeout 1h;
    proxy_responses 1;
}"
            ensure_firewall_port "$LISTEN_PORT" udp
            ;;
        3)
            PROTO_DESC="TCP+UDP"
            STREAM_BLOCK="
server {
    listen ${LISTEN_PORT};
    proxy_pass ${DEST_HOST}:${DEST_PORT};
    proxy_timeout 1h;
    proxy_connect_timeout 10s;
}
server {
    listen ${LISTEN_PORT} udp;
    proxy_pass ${DEST_HOST}:${DEST_PORT};
    proxy_timeout 1h;
}"
            ensure_firewall_port "$LISTEN_PORT" tcp
            ensure_firewall_port "$LISTEN_PORT" udp
            ;;
        *)
            PROTO_DESC="TCP"
            STREAM_BLOCK="
server {
    listen ${LISTEN_PORT};
    proxy_pass ${DEST_HOST}:${DEST_PORT};
    proxy_timeout 1h;
    proxy_connect_timeout 10s;
}"
            ensure_firewall_port "$LISTEN_PORT" tcp
            ;;
    esac

    echo "$STREAM_BLOCK" > "$CONF_FILE"

    nginx -t > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_err "Ошибка конфигурации Nginx Stream! Возможно порт ${LISTEN_PORT} уже занят."
        rm -f "$CONF_FILE"
        pause_prompt; return
    fi

    systemctl reload nginx

    # Сохраняем правило
    cat <<EOF > "$RULE_DATA_FILE"
{
    "listen_port": "${LISTEN_PORT}",
    "dest_host": "${DEST_HOST}",
    "dest_port": "${DEST_PORT}",
    "protocol": "${PROTO_DESC}",
    "created_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

    log_ok "Перенаправление порта ${LISTEN_PORT} -> ${DEST_HOST}:${DEST_PORT} (${PROTO_DESC}) запущено!"
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 3: СПИСОК ПРАВИЛ И УПРАВЛЕНИЕ
# ==============================================================================

list_active_rules() {
    print_banner
    echo -e "${C_BOLD}Активные правила перенаправления трафика${C_RESET}\n"

    echo -e "${C_YELLOW}--- [ L7 ] Сайты и Веб-сервисы (HTTP/HTTPS) ---${C_RESET}"
    printf "  ${C_BOLD}%-25s %-25s %-8s %-8s${C_RESET}\n" "ДОМЕН" "НАЗНАЧЕНИЕ" "SSL" "ПРОТОКОЛ"
    echo "  ────────────────────────────────────────────────────────────────────────"

    local http_count=0
    for file in "${RULES_HTTP_DIR}"/*.json; do
        if [ -f "$file" ]; then
            http_count=$((http_count + 1))
            local domain target_h target_p scheme ssl
            domain=$(jq -r '.domain' "$file")
            target_h=$(jq -r '.target_host' "$file")
            target_p=$(jq -r '.target_port' "$file")
            scheme=$(jq -r '.scheme' "$file")
            ssl=$(jq -r '.ssl' "$file")
            
            local ssl_str="${C_RED}No${C_RESET}"
            if [[ "$ssl" == "yes" ]]; then
                ssl_str="${C_GREEN}Yes${C_RESET}"
            fi

            printf "  %-25s %-25s %-16b %-8s\n" "$domain" "${target_h}:${target_p}" "$ssl_str" "$scheme"
        fi
    done
    if [ $http_count -eq 0 ]; then
        echo "  (Нет добавленных HTTP/HTTPS доменов)"
    fi

    echo ""
    echo -e "${C_YELLOW}--- [ L4 ] Порты и Стримы (TCP/UDP) ---${C_RESET}"
    printf "  ${C_BOLD}%-12s %-25s %-10s${C_RESET}\n" "ВХОД ПОРТ" "НАЗНАЧЕНИЕ" "ТИП"
    echo "  ────────────────────────────────────────────────────────────────────────"

    local stream_count=0
    for file in "${RULES_STREAM_DIR}"/*.json; do
        if [ -f "$file" ]; then
            stream_count=$((stream_count + 1))
            local l_port d_host d_port proto
            l_port=$(jq -r '.listen_port' "$file")
            d_host=$(jq -r '.dest_host' "$file")
            d_port=$(jq -r '.dest_port' "$file")
            proto=$(jq -r '.protocol' "$file")

            printf "  %-12s %-25s %-10s\n" "$l_port" "${d_host}:${d_port}" "$proto"
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
    echo "  1. Удалить домен (HTTP/HTTPS)"
    echo "  2. Удалить порт (TCP/UDP)"
    echo "  0. Назад"
    echo ""
    read -rp "  Ваш выбор: " DEL_TYPE

    case "$DEL_TYPE" in
        1)
            read -rp "  Введите имя домена для удаления: " DEL_DOMAIN
            DEL_DOMAIN=$(echo "$DEL_DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')
            if [ -f "${NGINX_HTTP_DIR}/${DEL_DOMAIN}.conf" ]; then
                rm -f "${NGINX_HTTP_DIR}/${DEL_DOMAIN}.conf"
                rm -f "${RULES_HTTP_DIR}/${DEL_DOMAIN}.json"
                systemctl reload nginx
                log_ok "Правило для домена ${DEL_DOMAIN} успешно удалено!"
            else
                log_err "Конфигурация для домена ${DEL_DOMAIN} не найдена!"
            fi
            ;;
        2)
            read -rp "  Введите входящий порт для удаления: " DEL_PORT
            RULE_FILE="${NGINX_STREAM_DIR}/stream_${DEL_PORT}.conf"
            JSON_FILE="${RULES_STREAM_DIR}/stream_${DEL_PORT}.json"
            if [ -f "$RULE_FILE" ]; then
                rm -f "$RULE_FILE"
                rm -f "$JSON_FILE"
                systemctl reload nginx
                log_ok "Правило для порта ${DEL_PORT} успешно удалено!"
            else
                log_err "Правило для порта ${DEL_PORT} не найдено!"
            fi
            ;;
        *)
            return
            ;;
    esac
    pause_prompt
}

# ==============================================================================
# МОДУЛЬ 4: СИСТЕМА БЕЗОПАСНОСТИ И ФАЕРВОЛ
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
        echo "  1. Блокировать подозрительный IP (Fail2ban/iptables)"
        echo "  2. Разблокировать IP-адрес"
        echo "  3. Просмотреть заблокированные IP"
        echo "  4. Включить / Настроить UFW Фаервол"
        echo "  5. Перевыпустить все SSL-сертификаты Certbot"
        echo "  0. Назад в главное меню"
        echo ""
        read -rp "  Выберите действие [0-5]: " SEC_CHOICE

        case "$SEC_CHOICE" in
            1)
                read -rp "  Введите IP-адрес для полной блокировки: " BLOCK_IP
                if [[ -n "$BLOCK_IP" ]]; then
                    iptables -I INPUT -s "$BLOCK_IP" -j DROP
                    log_ok "IP $BLOCK_IP добавлен в бан через iptables DROP!"
                fi
                pause_prompt
                ;;
            2)
                read -rp "  Введите IP-адрес для снятия блокировки: " UNBLOCK_IP
                if [[ -n "$UNBLOCK_IP" ]]; then
                    iptables -D INPUT -s "$UNBLOCK_IP" -j DROP 2>/dev/null || true
                    log_ok "IP $UNBLOCK_IP разблокирован!"
                fi
                pause_prompt
                ;;
            3)
                echo -e "\n${C_YELLOW}Список IP, заблокированных в правилах iptables:${C_RESET}"
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
                    log_ok "Фаервол UFW успешно включен! Порты 22, 80, 443 открыты."
                else
                    log_err "UFW не установлен в системе."
                fi
                pause_prompt
                ;;
            5)
                log_info "Принудительное обновление сертификатов Certbot..."
                certbot renew --dry-run
                pause_prompt
                ;;
            0)
                break
                ;;
        esac
    done
}

# ==============================================================================
# МОДУЛЬ 5: ДИАГНОСТИКА И ЖИВОЙ МОНИТОРИНГ
# ==============================================================================

live_monitor() {
    print_banner
    echo -e "${C_BOLD}Живой мониторинг трафика Nginx (Нажмите Ctrl+C для выхода)${C_RESET}\n"
    
    if [ ! -f "${LOG_DIR}/http_access.log" ]; then
        touch "${LOG_DIR}/http_access.log"
    fi

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

    # Статус Nginx
    if systemctl is-active --quiet nginx; then
        echo -e "  Служба Nginx:           ${C_GREEN}Работает (Active)${C_RESET}"
    else
        echo -e "  Служба Nginx:           ${C_RED}Остановлена (Failed)${C_RESET}"
    fi

    # Использование ресурсов
    echo -e "  Нагрузка процессора:    ${C_CYAN}$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')%${C_RESET}"
    echo -e "  Оперативная память:     ${C_CYAN}$(free -m | awk '/Mem:/ {printf "%d / %d MB (%.1f%%)", $3, $2, $3*100/$2}')${C_RESET}"
    echo -e "  Свободно на диске:      ${C_CYAN}$(df -h / | awk 'NR==2 {print $4 " (" $5 " занято)"}')${C_RESET}"

    # Сетевые соединения
    local conn_count
    conn_count=$(netstat -ant 2>/dev/null | grep ESTABLISHED | wc -l || ss -t state established | wc -l)
    echo -e "  Активных TCP-сессий:    ${C_YELLOW}${conn_count}${C_RESET}"

    # BBR статус
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
# МОДУЛЬ 6: РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ
# ==============================================================================

create_backup() {
    print_banner
    local bkp_file="${BACKUP_DIR}/backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
    log_info "Создание резервной копии конфигураций..."
    
    tar -czf "$bkp_file" -C /etc edge-proxy nginx > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_ok "Резервная копия сохранена в:"
        echo -e "  ${C_CYAN}${bkp_file}${C_RESET}"
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
        echo -e "   ${C_CYAN}1.${C_RESET} 🌐 Добавить веб-сайт (L7 HTTP / HTTPS Прокси + SSL Let's Encrypt)"
        echo -e "   ${C_CYAN}2.${C_RESET} 🔌 Добавить пересылку порта (L4 TCP / UDP Stream Forwarding)"
        echo -e "   ${C_CYAN}3.${C_RESET} 📋 Показать список всех активных правил"
        echo -e "   ${C_CYAN}4.${C_RESET} 🗑  Удалить существующее правило (сайт или порт)"
        echo -e "   ${C_CYAN}5.${C_RESET} 📈 Диагностика сервера и сетевые показатели"
        echo -e "   ${C_CYAN}6.${C_RESET} 👁  Живой просмотр логов входящего трафика"
        echo -e "   ${C_CYAN}7.${C_RESET} 🛡  Центр безопасности, защита и фаервол"
        echo -e "   ${C_CYAN}8.${C_RESET} 💾 Создать резервную копию настроек (Backup)"
        echo -e "   ${C_CYAN}9.${C_RESET} ⚡ Переустановить/Обновить ядро Nginx и зависимости"
        echo -e "   ${C_CYAN}0.${C_RESET} 🚪 Выход из программы"
        echo ""
        read -rp "   Выберите пункт меню [0-9]: " MAIN_CHOICE

        case "$MAIN_CHOICE" in
            1) add_http_proxy_wizard ;;
            2) add_stream_proxy_wizard ;;
            3) list_active_rules ;;
            4) delete_rule_wizard ;;
            5) system_health_check ;;
            6) live_monitor ;;
            7) security_menu ;;
            8) create_backup ;;
            9) install_core_dependencies ;;
            0)
                echo -e "\n  ${C_GREEN}Работа с шлюзом завершена. Все сервисы продолжают работать в фоне.${C_RESET}\n"
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
