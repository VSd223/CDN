# 🌐 Edge Traffic Gateway & Reverse Proxy (CDN Node)

Универсальный скрипт для Linux (Ubuntu / Debian / CentOS / AlmaLinux), превращающий ваш сервер в производительный промежуточный узел (Reverse Proxy / CDN-прослойку / шлюз перенаправления портов).

---

## 🚀 Быстрый запуск на сервере

Выполните команду в терминале вашего сервера под пользователем `root`:

```bash
git clone https://github.com/VSd223/CDN.git
cd CDN
# Если файл называется CDN.s, переименовываем в CDN.sh:
[ -f CDN.s ] && mv CDN.s CDN.sh
# Устраняем несовместимость строк Windows (CRLF -> LF)
sed -i -e 's/\r$//' CDN.sh
# Даем права на запуск и запускаем
chmod +x CDN.sh
sudo ./CDN.sh
