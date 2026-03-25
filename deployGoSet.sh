#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

ask() {
    local prompt="$1"
    local default="$2"
    local var
    read -p "$prompt [$default]: " var
    echo "${var:-$default}"
}

echo "========================================="
echo "    Установка сервера для Go-приложения"
echo "========================================="

APP_NAME=$(ask "Имя приложения" "myapp")
DOMAIN=$(ask "Домен (или _ для IP)" "_")
ADMIN_EMAIL=$(ask "Email администратора" "admin@example.com")
GO_PORT=$(ask "Порт для Go приложения" "8080")

DB_NAME=$(ask "Имя базы данных" "${APP_NAME}_db")
DB_USER=$(ask "Имя пользователя БД" "$APP_NAME")
DB_PASS=$(ask "Пароль пользователя БД" "$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-16)")

APP_DIR="/var/www/$APP_NAME"

log "Каталог приложения: $APP_DIR"
log "Пароль БД: $DB_PASS (сохраните!)"

# 1. Обновление системы
log "Обновление системы..."
apt update && apt upgrade -y

# 2. Установка пакетов
log "Установка пакетов: nginx, postgresql, git, curl, unzip..."
apt install -y curl wget git nginx postgresql postgresql-contrib unzip

# 3. Создание пользователя и каталогов
log "Создание пользователя $APP_NAME..."
if ! id "$APP_NAME" &>/dev/null; then
    useradd -m -s /bin/bash "$APP_NAME"
fi

log "Создание структуры каталогов..."
mkdir -p "$APP_DIR"/{bin,static,logs,config}
chown -R "$APP_NAME":"$APP_NAME" "$APP_DIR"

# 4. Настройка PostgreSQL
log "Настройка PostgreSQL..."
systemctl enable postgresql
systemctl start postgresql

if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
    log "База данных $DB_NAME создана."
else
    warn "База данных $DB_NAME уже существует"
fi

# Сохраняем конфиг окружения
cat > "$APP_DIR/config/.env" <<EOF
DATABASE_URL=postgres://$DB_USER:$DB_PASS@localhost/$DB_NAME?sslmode=disable
APP_NAME=$APP_NAME
GO_PORT=$GO_PORT
DOMAIN=$DOMAIN
EOF
chown "$APP_NAME":"$APP_NAME" "$APP_DIR/config/.env"

# 5. Systemd unit для Go-бинарника
log "Создание systemd unit..."
cat > "/etc/systemd/system/$APP_NAME.service" <<EOF
[Unit]
Description=$APP_NAME Go Application
After=network.target postgresql.service

[Service]
User=$APP_NAME
Group=$APP_NAME
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/config/.env
ExecStart=$APP_DIR/bin/$APP_NAME
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME"

# 6. Конфигурация Nginx
log "Настройка Nginx..."
cat > "/etc/nginx/sites-available/$APP_NAME" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $APP_DIR/static;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:$GO_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default
nginx -t || error "Ошибка в конфигурации Nginx"
systemctl restart nginx

# 7. Скрипт для обновления бинарника и статики (без компиляции)
log "Создание скрипта обновления..."
cat > "$APP_DIR/update.sh" <<EOF
#!/bin/bash
set -e
# Копируем новый бинарник (предполагается, что он лежит в текущей папке при запуске скрипта)
if [ -f "./$APP_NAME" ]; then
    cp ./$APP_NAME $APP_DIR/bin/
    chown $APP_NAME:$APP_NAME $APP_DIR/bin/$APP_NAME
    chmod +x $APP_DIR/bin/$APP_NAME
fi

# Копируем статику (если есть папка ./static)
if [ -d "./static" ]; then
    cp -r ./static/* $APP_DIR/static/
    chown -R $APP_NAME:$APP_NAME $APP_DIR/static
fi

# Перезапускаем сервис
systemctl restart $APP_NAME
EOF

chmod +x "$APP_DIR/update.sh"
chown "$APP_NAME":"$APP_NAME" "$APP_DIR/update.sh"

log "========================================="
log "Установка завершена!"
log "Каталог приложения: $APP_DIR"
log ""
log "Для развертывания приложения:"
log "1. Скопируйте скомпилированный бинарник и статику на сервер (например, в /tmp)"
log "2. Запустите от root:"
log "   cd /tmp"
log "   sudo -u $APP_NAME $APP_DIR/update.sh"
log ""
log "Или вручную:"
log "   cp myapp $APP_DIR/bin/"
log "   cp -r dist/* $APP_DIR/static/"
log "   systemctl restart $APP_NAME"
log ""
log "Nginx слушает 80 порт, прокси /api/ на порт $GO_PORT"
log "Пароль БД: $DB_PASS (сохранён в $APP_DIR/config/.env)"
log "========================================="
