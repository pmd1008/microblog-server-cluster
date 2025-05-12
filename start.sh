#!/bin/bash

# Проверяем наличие .env
if [ ! -f .env ]; then
    echo "Ошибка: Файл .env не найден. Скопируйте exapmle.env в .env и настройте переменные."
    exit 1
fi

# Загружаем переменные из .env
set -a
source .env
set +a

# Проверяем наличие MANAGER_IP
if [ -z "$MANAGER_IP" ]; then
    echo "Ошибка: MANAGER_IP не указан в .env."
    exit 1
fi

# Удаляем существующий Docker
echo "Удаление существующего Docker..."
sudo systemctl stop docker.socket docker.service || true
sudo dnf -y remove docker docker-client docker-client-latest docker-common docker-compose docker-logrotate docker-selinux docker-engine-selinux docker-engine || true
sudo rm -rf /var/lib/docker /var/run/docker.sock
sudo dnf -y autoremove

# Устанавливаем Docker с нуля
echo "Установка Docker..."
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io
sudo systemctl enable docker
sudo systemctl start docker

# Проверяем, установлен ли Docker
if ! command -v docker &> /dev/null; then
    echo "Ошибка: Docker не установлен."
    exit 1
fi

# Генерируем SSL-сертификаты для Nginx
echo "Генерация SSL-сертификатов..."
mkdir -p nginx/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/certs/nginx.key \
    -out nginx/certs/nginx.crt \
    -subj "/C=RU/ST=State/L=City/O=Organization/OU=Unit/CN=${MANAGER_IP}"

# Инициализируем Docker Swarm
echo "Инициализация Docker Swarm..."
docker swarm init --advertise-addr ${MANAGER_IP} || {
    echo "Swarm уже инициализирован или произошла ошибка."
}

# Деплоим стек
echo "Запуск приложения..."
docker stack deploy -c docker-compose.yml microblog-stack

# Ждём, пока сервисы запустятся
echo "Ожидание запуска сервисов..."
sleep 30

# Выполняем миграции БД
echo "Выполнение миграций БД..."
container_id=$(docker ps -q -f name=microblog-stack_microblog | head -n1)
if [ -z "$container_id" ]; then
    echo "Ошибка: Контейнер microblog не найден."
    exit 1
fi
docker exec $container_id flask db init || true
docker exec $container_id flask db migrate
docker exec $container_id flask db upgrade

# Выводим информацию
echo "Приложение запущено!"
echo "Микроблог: https://${MANAGER_IP}"
echo "Prometheus: http://${MANAGER_IP}:9090"
echo "Grafana: http://${MANAGER_IP}:3000"
