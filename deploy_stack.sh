#!/bin/bash

# Автоматизация развертывания Docker Swarm кластера для microblog
# Запуск реестра через Docker Compose, остальной стек в Swarm
# Работает на Fedora/CentOS

set -e # Прерывать выполнение при любой ошибке

# Проверка наличия .env
if [ ! -f ".env" ]; then
    echo "Ошибка: Файл .env не найден"
    exit 1
fi

# Загрузка переменных из .env
export $(grep -v '^#' .env | grep -v '^$' | xargs)

# Проверка MANAGER_IP
if [ -z "$MANAGER_IP" ]; then
    echo "Ошибка: MANAGER_IP не задан в .env"
    exit 1
fi

# Настройки
REGISTRY_URL="${MANAGER_IP}:5001"
COMPOSE_FILE="docker-compose.yml"
REGISTRY_COMPOSE_FILE="docker-compose-registry.yml"
STACK_NAME="microblog"
DAEMON_JSON="/etc/docker/daemon.json"

# Проверка наличия docker-compose-registry.yml
if [ ! -f "$REGISTRY_COMPOSE_FILE" ]; then
    echo "Ошибка: Файл $REGISTRY_COMPOSE_FILE не найден"
    exit 1
fi

# Шаг 1: Инициализация Docker Swarm
echo "Проверяем/инициализируем Docker Swarm..."
if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
    docker swarm init --advertise-addr "$MANAGER_IP" || {
        echo "Ошибка при инициализации Swarm"
        exit 1
    }
    echo "Swarm инициализирован"
else
    echo "Swarm уже активен"
fi

# Вывод команды для присоединения воркер-нод
WORKER_TOKEN=$(docker swarm join-token -q worker)
echo "Команда для присоединения воркер-нод:"
echo "docker swarm join --token $WORKER_TOKEN $MANAGER_IP:2377"

# Шаг 2: Генерация самоподписанных ключей для Nginx
echo "Генерируем SSL-ключи для Nginx..."
if [ -f "nginx.crt" ] && [ -f "nginx.key" ]; then
    echo "Ключи уже существуют, пропускаем"
else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout nginx.key -out nginx.crt -subj "/CN=$MANAGER_IP" || {
        echo "Ошибка при генерации ключей"
        exit 1
    }
fi

# Шаг 3: Запуск Docker-реестра через Docker Compose
echo "Запускаем Docker-реестр через Docker Compose..."
docker compose -f "$REGISTRY_COMPOSE_FILE" up -d || {
    echo "Ошибка при запуске реестра"
    exit 1
}

# Ожидание доступности реестра
echo "Ожидаем доступности реестра на $REGISTRY_URL..."
until curl -s "http://$REGISTRY_URL/v2/" | grep -q "{}"; do
    echo "Реестр недоступен, ждём 5 секунд..."
    sleep 5
done
echo "Реестр доступен"

# Шаг 4: Настройка /etc/docker/daemon.json
echo "Настраиваем $DAEMON_JSON для HTTP-реестра..."
if [ -f "$DAEMON_JSON" ]; then
    # Файл существует, добавляем insecure-registries
    if ! jq '.["insecure-registries"] | contains(["'$REGISTRY_URL'"])' "$DAEMON_JSON" | grep -q "true"; then
        jq '.["insecure-registries"] += ["'$REGISTRY_URL'"]' "$DAEMON_JSON" > /tmp/daemon.json && \
        mv /tmp/daemon.json "$DAEMON_JSON" || {
            echo "Ошибка при обновлении $DAEMON_JSON"
            exit 1
        }
    else
        echo "Реестр $REGISTRY_URL уже в $DAEMON_JSON"
    fi
else
    # Файл не существует, создаём
    mkdir -p /etc/docker
    echo '{"insecure-registries": ["'$REGISTRY_URL'"]}' > "$DAEMON_JSON" || {
        echo "Ошибка при создании $DAEMON_JSON"
        exit 1
    }
fi

# Перезапуск Docker
echo "Перезапускаем Docker..."
systemctl restart docker || {
    echo "Ошибка при перезапуске Docker"
    exit 1
}

# Проверка, что Swarm всё ещё активен
if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
    echo "Ошибка: Swarm неактивен после перезапуска Docker"
    exit 1
fi

# Перезапуск реестра после перезапуска Docker
echo "Перезапускаем Docker-реестр после перезапуска Docker..."
docker compose -f "$REGISTRY_COMPOSE_FILE" up -d || {
    echo "Ошибка при перезапуске реестра"
    exit 1
}

# Повторное ожидание доступности реестра
echo "Ожидаем доступности реестра на $REGISTRY_URL после перезапуска..."
until curl -s "http://$REGISTRY_URL/v2/" | grep -q "{}"; do
    echo "Реестр недоступен, ждём 5 секунд..."
    sleep 5
done
echo "Реестр доступен"

# Шаг 5: Сборка и пуш образов
echo "Собираем и пушим образы в реестр..."
for IMAGE in "microblog" "nginx" "prometheus"; do
    DOCKERFILE="Dockerfile"
    [ "$IMAGE" = "nginx" ] && DOCKERFILE="Dockerfile-nginx"
    [ "$IMAGE" = "prometheus" ] && DOCKERFILE="Dockerfile-prometheus"

    echo "Собираем $IMAGE..."
    docker build -f "$DOCKERFILE" -t "$REGISTRY_URL/$IMAGE:latest" . || {
        echo "Ошибка при сборке $IMAGE"
        exit 1
    }

    echo "Пушим $IMAGE..."
    docker push "$REGISTRY_URL/$IMAGE:latest" || {
        echo "Ошибка при пуше $IMAGE"
        exit 1
    }
done

# Шаг 6: Запуск стека в Swarm
echo "Разворачиваем стек..."
export REGISTRY_URL
docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME" || {
    echo "Ошибка при развёртывании стека"
    exit 1
}

# Шаг 7: Ожидание готовности postgres и миграция базы
echo "Ожидаем готовности postgres..."
until docker run --rm --network "${STACK_NAME}_microblog-net" postgres:14 pg_isready -h postgres -U postgres; do
    echo "Postgres недоступен, ждём 2 секунды..."
    sleep 2
done

echo "Выполняем миграции базы данных..."
CONTAINER_ID=$(docker ps -q -f name="${STACK_NAME}_microblog" | head -n1)
if [ -z "$CONTAINER_ID" ]; then
    echo "Ошибка: Контейнер microblog не найден"
    exit 1
fi

docker exec "$CONTAINER_ID" flask db init || true
docker exec "$CONTAINER_ID" flask db migrate || {
    echo "Ошибка при миграции базы"
    exit 1
}
docker exec "$CONTAINER_ID" flask db upgrade || {
    echo "Ошибка при обновлении базы"
    exit 1
}

# Проверка состояния сервисов
echo "Проверяем состояние сервисов..."
sleep 5
docker stack ps "$STACK_NAME" --no-trunc

echo "Развёртывание завершено!"
echo "Логи сервисов: docker service logs ${STACK_NAME}_<service_name>"
echo "Логи реестра: docker compose -f $REGISTRY_COMPOSE_FILE logs registry"
