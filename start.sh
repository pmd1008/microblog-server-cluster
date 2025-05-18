#!/bin/bash

# Автоматизация развертывания Docker Swarm кластера для microblog
# Требует предустановленного Docker и docker-compose

set -euo pipefail

echo "Начало выполнения скрипта: $(date)"

# Проверка наличия Docker
if ! command -v docker >/dev/null || ! docker --version >/dev/null; then
    echo "Ошибка: Docker не установлен или не работает"
    echo "Пожалуйста, установите Docker вручную перед запуском скрипта"
    exit 1
fi

# Проверка docker compose
if ! docker compose version >/dev/null; then
    echo "Ошибка: Docker Compose Plugin не установлен"
    echo "Установите его командой: sudo dnf install docker-compose-plugin"
    exit 1
fi



# Проверка и установка плагина Loki
echo "Проверяем наличие плагина Loki..."
if ! docker plugin ls --format '{{.Name}}' | grep -q '^loki$'; then
    echo "Плагин Loki не установлен. Устанавливаем..."
    if ! docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions 2>/dev/null; then
        echo "Ошибка: Не удалось установить плагин Loki. Проверьте интернет-соединение или репозиторий плагинов."
        exit 1
    fi
    echo "Плагин Loki успешно установлен."
else
    echo "Плагин Loki уже установлен или существует."
fi


# Шаг 1: Проверка конфиг файла
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

if ! echo "$MANAGER_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$' >/dev/null; then
    echo "Ошибка: Неверный формат MANAGER_IP ($MANAGER_IP)"
    exit 1
fi

# Основные переменные
REGISTRY_URL="${MANAGER_IP}:5001"
COMPOSE_FILE="docker-compose.yml"
REGISTRY_COMPOSE_FILE="docker-compose-registry.yml"
STACK_NAME="microblog"
DAEMON_JSON="/etc/docker/daemon.json"

# Проверка файлов конфигурации
for file in "$COMPOSE_FILE" "$REGISTRY_COMPOSE_FILE"; do
    if [ ! -f "$file" ]; then
        echo "Ошибка: Файл $file не найден"
        exit 1
    fi
done

# Шаг 2: Улучшенная проверка и инициализация Swarm
echo "Проверяем состояние Docker Swarm..."

SWARM_STATUS=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)

case "$SWARM_STATUS" in
    "active")
        # Проверяем, является ли узел менеджером
        if docker node ls &>/dev/null; then
            echo "Swarm уже активен, текущий узел является менеджером"
        else
            echo "Ошибка: Узел не является менеджером Swarm"
            echo "1. Если хотите пересоздать Swarm, выполните: docker swarm leave --force"
            echo "2. Затем запустите скрипт снова"
            exit 1
        fi
        ;;
    "inactive"|"")
        echo "Инициализируем новый Swarm кластер..."
        docker swarm init --advertise-addr "$MANAGER_IP" || {
            echo "Ошибка при инициализации Swarm"
            exit 1
        }
        ;;
    *)
        echo "Неизвестное состояние Swarm: $SWARM_STATUS"
        exit 1
        ;;
esac

# Получение токена для worker-нод
WORKER_TOKEN=$(docker swarm join-token -q worker 2>/dev/null || true)
if [ -z "$WORKER_TOKEN" ]; then
    echo "Ошибка: Не удалось получить токен для присоединения worker-нод"
    exit 1
fi

echo "Команда для присоединения worker-нод:"
echo "docker swarm join --token $WORKER_TOKEN $MANAGER_IP:2377"


# Шаг 3: Генерация самоподписанных ключей для Nginx
echo "Генерируем SSL-ключи для Nginx..."
if [ -f "nginx.crt" ] && [ -f "nginx.key" ]; then
    echo "Ключи уже существуют, используются в данном запуске"
else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout nginx.key -out nginx.crt -subj "/CN=$MANAGER_IP" || {
        echo "Ошибка при генерации ключей"
        exit 1
    }
fi

# Шаг 4: Настройка /etc/docker/daemon.json, для http доступа 
echo "Настраиваем $DAEMON_JSON для HTTP-реестра..."
NEED_DOCKER_RESTART=0
if [ -f "$DAEMON_JSON" ]; then
    # Файл существует, проверяем наличие insecure-registries
    if ! jq '.["insecure-registries"] | contains(["'"$REGISTRY_URL"'"])' "$DAEMON_JSON" | grep -q "true"; then
        jq '.["insecure-registries"] += ["'"$REGISTRY_URL"'"]' "$DAEMON_JSON" > /tmp/daemon.json && \
        mv -f /tmp/daemon.json "$DAEMON_JSON" || {
            echo "Ошибка при обновлении $DAEMON_JSON"
            exit 1
        }
        NEED_DOCKER_RESTART=1
        echo "Добавлен $REGISTRY_URL в $DAEMON_JSON"
    else
        echo "Реестр $REGISTRY_URL уже в $DAEMON_JSON"
    fi
else
    # Файл не существует, создаём
    mkdir -p /etc/docker
    echo '{"insecure-registries": ["'"$REGISTRY_URL"'"]}' > "$DAEMON_JSON" || {
        echo "Ошибка при создании $DAEMON_JSON"
        exit 1
    }
    NEED_DOCKER_RESTART=1
    echo "Создан $DAEMON_JSON с $REGISTRY_URL"
fi

# Перезапуск Docker, только если daemon.json изменён
if [ "$NEED_DOCKER_RESTART" -eq 1 ]; then
    echo "Перезапускаем Docker: $(date)"
    systemctl restart docker || {
        echo "Ошибка при перезапуске Docker"
        exit 1
    }
    # Проверка, что Swarm всё ещё активен
    if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
        echo "Ошибка: Swarm неактивен после перезапуска Docker"
        exit 1
    fi
else
    echo "Перезапуск Docker не требуется"
fi

# Шаг 5: Запуск Docker-реестра через Docker Compose
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

# Шаг 6: Сборка и пуш образов
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

# Шаг 7: Запуск стека в Swarm
echo "Разворачиваем стек..."
export REGISTRY_URL
docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME" || {
    echo "Ошибка при развёртывании стека"
    exit 1
}

# Шаг 8: Ожидание готовности postgres и миграция базы
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
    echo "Ошибка при миграции базы данных"
    exit 1
}
docker exec "$CONTAINER_ID" flask db upgrade || {
    echo "Ошибка при обновлении базы данных"
    exit 1
}

# Проверка состояния сервисов
echo "Проверяем состояние сервисов..."
sleep 5
docker stack ps "$STACK_NAME" --no-trunc

echo "Развёртывание завершено!"
echo "Логи сервисов: docker service logs ${STACK_NAME}_<service_name>"
echo "Логи реестра: docker compose -f $REGISTRY_COMPOSE_FILE logs registry"

