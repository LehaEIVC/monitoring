# Zabbix

## Установка Zabbix-сервера в Docker
DockerHub: https://hub.docker.com/r/zabbix/zabbix-server-pgsql

Для данных подключить отдельный диск.
В примере sdb, разделы и LVM не создаю (диск в виртуальной инфраструктуре).
Для "железного" сервера настаиваю на LVM.
```bash
# Создаем директорию для точки монтирования нового диска
sudo mkdir -p /opt/app
# Добавляем запись в fstab
echo "/dev/sdb /opt/app                    ext4    defaults        1 2" | sudo tee -a /etc/fstab
# Проверяем возможность монтирования
mount -a
# Проверяем точку монтирования 
lsblk | grep app
```

Создать директории
```bash
# Для zabbix данных
sudo mkdir -p /opt/app/zabbix
# Назначить владельцем директории текущего пользователя
sudo chown "${USER}" /opt/app/zabbix
```

Создать файл с переменными .env
```bash
tee /opt/app/zabbix/.env << EOF
# Имя хоста БД, в нашем случаее имя контейнера
DB_SERVER_HOST=zabbix-postgres
# Порт Postgres
DB_SERVER_PORT=5432
# Имя БД Zabbix
POSTGRES_DB=db_zabbix
# Пользователь БД Zabbix
POSTGRES_USER=usr_zabbix

# Количество дней старше которых будут удалены ежедневные бекапы
BACKUP_DB_MAX_DAYS=7
# Количество дней старше которых будут удалены ежемесячные бекапы. 1825 - старше трех лет.
# 12 * 3 = 36 месячных бекапов на 01 число каждого месяца
BACKUP_DB_MAX_MONTHLY_DAYS=1825
# Директория на хосте для бекапов БД, можно создать отдлеьную точку монитрования (cifs, nfs или другой диск)
BACKUP_PATH=/mnt/zabbix-db/
# Периодичность создания бекапа
BACKUP_PERIOD=24h

# Маппинг директории для БД Zabbix на хост
PG_DATA=/opt/app/zabbix/pg_data
# Маппинг директории для Zabbix на хост
ZABBIX_DATA=/opt/app/zabbix/data
ZABBIX_LOG=/var/log/zabbix/server
ZABBIX_DEBUG_LEVEL=3

# Нексус (СЛЕШ в конце ОБЯЗАТЕЛЕН!), если не нужен - закоментировать
#NEXUS=nexus.dc-12.local/
# При необходимости указать прокси, если не нужен - закоментировать
#HTTP_PROXY=http://192.168.0.1:3128
#HTTPS_PROXY=http://192.168.0.1:3128

# Проверьте совместимость TimescaleDB с выбранной версией Zabbix:
# https://www.zabbix.com/documentation/current/en/manual/installation/requirements
# Найдите: TimescaleDB for PostgreSQL
# Тег для образа TimescaleDB
TAG_TIMESCALEDB=2.21.4-pg17
# Тег для образа БД Postgresql, контейнер которой будет производить бекап БД
#TAG_POSTGRESQL=17.6-alpine
# Тег для образа psql, контейнер которой будет производить бекап БД
TAG_PSQL=17.6
# Тег для образа Zabbix-server и Web-Zabbix
TAG_ZABBIX=7.4.3-alpine

# Имя образа, в который будет пересобираться Zabbix-сервер (установка пакетов curl и js для отправки Проблем в Alertmanager)
IMAGE_ZABBIX_SERVER=local/zabbix-server:7.4.3-alpine

# Подсеть для контейнеров - 14 ip (1-14)
SUBNET=172.16.1.0/28
# IP для Zabbix-сервера, нужно для настройки zabbix-agent на хосте
# Выбираем последний в сети, что бы не было проблем при загрузке контейнеров
# (ip рандомно назначаются контейнерам сначала диапазона сети,
# поэтому при перезагрузке ip у контейнеров могут измениться)
IP_ZABBIX_SERVER=172.16.1.14

# Имя хоста
HOST_ZABBIX=$(hostname -f)
EOF
```

Создать Dockerfile: для отправки событий в Alertmanager необходимо в образ установить пакеты: curl, jq
```bash
tee /opt/app/zabbix/Dockerfile << 'EOF'
# Устанавилваем переменную NEXUS и TAG_ZABBIX для использования в FROM (из передаваемых параметров)
# или используются дефолтные значения.
ARG NEXUS=""
ARG TAG_ZABBIX="latest"

# Используем официальный образ Zabbix-сервера как основу
FROM ${NEXUS}zabbix/zabbix-server-pgsql:${TAG_ZABBIX}

# Сохраняем ARG в ENV для использования в RUN (если переменные не передаются, то примут пустые значения)
ARG NEXUS=""
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
# Передаём прокси в среду сборки
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}

# Обновляем список пакетов и устанавливаем curl и jq
# Переключаем пользователя на root
USER root
# Если сервер zabbix в корпоративной сети, то заменяем репозиторий Alpine Linux (apk) на Нексус
# Если сервер zabbix в ДМЗ, то устанвливаем прокси и в репозитории заменяем на зеркало yandex
# Если сервер zabbix с прямым доступом в интернет, то в репозитории заменяем на зеркало yandex
RUN set -eux; \
    echo "NEXUS=${NEXUS}"; \
    echo "HTTP_PROXY=${HTTP_PROXY}"; \
    echo "HTTPS_PROXY=${HTTPS_PROXY}"; \
    echo "http_proxy=${http_proxy}"; \
    echo "https_proxy=${https_proxy}"; \
    cat /etc/apk/repositories; \
    if [ ! -z "${NEXUS}" ]; then \
       sed -i "s|.*dl-cdn.alpinelinux.org|http://${NEXUS}repository/yandex/mirrors|g" /etc/apk/repositories; \
    else \
       sed -i "s|.*dl-cdn.alpinelinux.org|http://mirror.yandex.ru/mirrors|g" /etc/apk/repositories; \
    fi; \
    cat /etc/apk/repositories; \
    apk add --no-cache curl jq && \
    rm -rf /var/cache/apk/*
# Переключаем пользователя на zabbix
USER zabbix
EOF
```

Создать файл docker-compose.yaml
```bash
tee /opt/app/zabbix/docker-compose.yaml << 'EOF'
#version: '3.8'

x-common-variables:
  &common-pg
  POSTGRES_DB: "${POSTGRES_DB}"
  POSTGRES_USER: "${POSTGRES_USER}"
  DB_SERVER_HOST: "${DB_SERVER_HOST}"
  DB_SERVER_PORT: "${DB_SERVER_PORT}"

services:
  zabbix-postgres:
    # Проверьте совместимость TimescaleDB с выбранной версией Zabbix:
    # https://www.zabbix.com/documentation/current/en/manual/installation/requirements
    # Найдите: TimescaleDB for PostgreSQL
    image: ${NEXUS}timescale/timescaledb:${TAG_TIMESCALEDB}
    container_name: zabbix-postgres
    environment:
      POSTGRES_CONF_ARGS: >
        -c shared_buffers=1024MB
        -c effective_cache_size=3GB
        -c maintenance_work_mem=512MB
        -c work_mem=64MB
        -c max_connections=200
    volumes:
      - ${PG_DATA}:/var/lib/postgresql/data:rw
    tmpfs: /tmp
    ulimits:
      nproc: 65535
      nofile:
        soft: 20000
        hard: 40000
#    Если необходим доступ к БД из сети - раскомментировать две строки ниже
#    ports:
#      - 5432:5432
    command:
      - "postgres"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    restart: unless-stopped
    networks:
      zabbix-net:

  zabbix-backup-pg:
    #image: ${NEXUS}postgres:${TAG_POSTGRESQL}
    image: ${NEXUS}alpine/psql:${TAG_PSQL}
    container_name: zabbix-backup-pg
    entrypoint: [""]
    environment:
      <<: *common-pg
      PGPASSFILE: /run/secrets/secret_pgpass
      BACKUP_DB_MAX_DAYS: "$BACKUP_DB_MAX_DAYS"
      BACKUP_DB_MAX_MONTHLY_DAYS: "$BACKUP_DB_MAX_MONTHLY_DAYS"
      BACKUP_PERIOD: "$BACKUP_PERIOD"
    secrets:
      - secret_pgpass
    command: |
      sh -c 'sleep 10h    # После перезапуска контейнера ждем 10 часов до первого запуска бекапа
             while true; do
                 echo "$$(date "+%Y-%m-%d_%H-%M-%S"): Start backup Postgres DB Zabbix..."
                 CURRENT_DAY=$$(date "+%d")
                 BACKUP_FILENAME="zabbix-postgres-backup-$$(date "+%Y-%m-%d_%H-%M").gz"
                 MONTHLY_BACKUP_FILENAME="zabbix-postgres-backup-$$(date "+%Y-%m-%d")-monthly.gz"
                 if [ "$$CURRENT_DAY" = "01" ]; then
                     echo "$$(date "+%Y-%m-%d_%H-%M-%S"): Creating a monthly backup..."
                     pg_dump -h "$$DB_SERVER_HOST" -p "$$DB_SERVER_PORT" -d "$$POSTGRES_DB" -U "$$POSTGRES_USER" | gzip > /pg_backup/"$$MONTHLY_BACKUP_FILENAME"
                     echo "$$(date "+%Y-%m-%d_%H-%M-%S"): Deleting monthly backups older $$BACKUP_DB_MAX_MONTHLY_DAYS days..."
                     find /pg_backup/ -type f -name "*-monthly.gz" -mtime +"$$BACKUP_DB_MAX_MONTHLY_DAYS" | xargs rm -f -v
                 else
                     echo "$$(date "+%Y-%m-%d_%H-%M-%S"): Creating a daily backup..."
                     pg_dump -h "$$DB_SERVER_HOST" -p "$$DB_SERVER_PORT" -d "$$POSTGRES_DB" -U "$$POSTGRES_USER" | gzip > /pg_backup/"$$BACKUP_FILENAME"
                 fi
                 echo "$$(date "+%Y-%m-%d_%H-%M-%S"): Deleting daily backups older $$BACKUP_DB_MAX_DAYS days..."
                 find /pg_backup/ -type f ! -name "*-monthly.gz" -mtime +"$$BACKUP_DB_MAX_DAYS" | xargs rm -f -v
                 echo "$$(date "+%Y-%m-%d_%H-%M-%S"): End. Sleep $$BACKUP_PERIOD..."
                 sleep "$$BACKUP_PERIOD";
             done'
    volumes:
      - ${BACKUP_PATH}:/pg_backup
    networks:
      zabbix-net:
    restart: unless-stopped
    depends_on:
      zabbix-postgres:
        condition: service_healthy      
    healthcheck:
       test: |
         timeout 10 bash -c '
           pg_isready -h "$$DB_SERVER_HOST" -p "$$DB_SERVER_PORT" -d "$$POSTGRES_DB" -U "$$POSTGRES_USER" -t 5 || {
             echo "Ошибка подключения к БД (zabbix-postgres)"
             exit 1
           }
           [ ! -w /pg_backup ] && {
             echo "Нет доступа на запись в директорию /pg_backup"
             exit 1
           }
           # Проверяем что основной процесс запущен
           ps aux | grep -q -E "[s]leep|[p]g_dump" || {
             echo "Нет запущенных процессов для бекапирования: ps aux | grep -q -E \"[s]leep|[p]g_dump\""
             exit 1
           }
         ' || exit 1
       interval: 60s
       timeout: 30s
       retries: 2
       start_period: 30s

  zabbix-server:
    build:
      context: .    # Указывает на текущую директорию, где находится Dockerfile
      args:
        NEXUS: ${NEXUS}
        TAG_ZABBIX: ${TAG_ZABBIX}
      dockerfile: Dockerfile
    image: ${IMAGE_ZABBIX_SERVER}
    container_name: zabbix-server
    #hostname: ${HOST_ZABBIX}
    environment:
      <<: *common-pg
      TZ: "Europe/Moscow"
      ZBX_NODEADDRESS: ${HOST_ZABBIX}
      ZBX_STARTCONNECTORS: "5"
      #ZBX_STARTPOLLERS: "250"
      #ZBX_STARTPOLLERSUNREACHABLE: "50"
      #ZBX_STARTPINGERS: "100"
      #ZBX_CACHESIZE: "2G"
      #ZBX_HISTORYCACHESIZE: "512M"
      #ZBX_TRENDCACHESIZE: "512M"
      #ZBX_TRENDFUNCTIONCACHESIZE: "512M"
      #ZBX_VALUECACHESIZE: "512M"
      #ZBX_WEBSERVICEURL: "http://${HOST_ZABBIX}:10053/report"
      ZBX_LOGTYPE: "file"
      ZBX_DEBUGLEVEL: ${ZABBIX_DEBUG_LEVEL}
      POSTGRES_PASSWORD_FILE: /run/secrets/secret_db_pass
    #secrets:
    #  - secret_db_pass
    volumes:
      # Установить права на скрипт отправки в alertmanager с UID и GID как у пользователя zabbix в контейнере!
      # Проверить: docker exec zabbix-server cat /etc/passwd | grep zabbix
      # zabbix:x:1997:1995:Zabbix monitoring system:/var/lib/zabbix:/sbin/nologin
      # Установить на хостовой машине:
      # chown 1997:1995 /opt/app/zabbix/data/alertscripts/send_to_alertmanager.sh
      # chmod 700 /opt/app/zabbix/data/alertscripts/send_to_alertmanager.sh
      - ${ZABBIX_DATA}/alertscripts:/usr/lib/zabbix/alertscripts:ro
      - ${ZABBIX_DATA}/mibs:/var/lib/zabbix/mibs:ro
      - ${ZABBIX_LOG}:/var/log/zabbix:rw
      - ./.secret/db_password_zabbix_server:/run/secrets/secret_db_pass:ro
    ports:
      # открытия порта на хосте для проброса в контейнер. Для доступа агентов с серверов/ВМ
      - 10051:10051
    restart: unless-stopped
    depends_on:
      - zabbix-postgres
    healthcheck:
      test: ["CMD", "bash", "-c", "nc -z localhost 10051 && ps aux | grep -q '[z]abbix_server'"]
      interval: 10s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      zabbix-net:
        ipv4_address: ${IP_ZABBIX_SERVER}      

  zabbix-web-nginx-pgsql:
    container_name: zabbix-web-nginx-pgsql
    image: ${NEXUS}zabbix/zabbix-web-nginx-pgsql:${TAG_ZABBIX}
    environment:
      <<: *common-pg
      TZ: "Europe/Moscow"
      #ZBX_SERVER_NAME: ${HOST_ZABBIX}
      # Имя контейнера zabbix сервера (см выше): container_name: zabbix-server
      ZBX_SERVER_NAME: ${DB_SERVER_HOST}
      POSTGRES_PASSWORD_FILE: /run/secrets/secret_db_pass
    secrets: 
      - secret_db_pass
    volumes:
      - /etc/timezone:/etc/timezone:ro
      - ./.secret/db_password_zabbix_web:/run/secrets/secret_db_pass:ro
    ports:
      - 80:8080
      - 443:8443
    restart: unless-stopped
    depends_on:
      zabbix-server:
        condition: service_healthy
    healthcheck:
      test: |
        timeout 5 bash -c '
          curl -f http://localhost:8080 > /dev/null 2>&1 || {
            echo "Веб-сервер недоступен!"
            exit 1
          }
          nc -z zabbix-server 10051 || {
            echo "Ошибка подключения к zabbix-server"
            exit 1
          }
          echo "Проверки успешны"
        ' || exit 1
      interval: 10s
      timeout: 20s
      retries: 3
      start_period: 30s
    networks:
      zabbix-net:

networks:
  zabbix-net:
    driver: bridge
    driver_opts:
      com.docker.network.enable_ipv6: "false"
    ipam:
      driver: default
      config:
      - subnet: ${SUBNET}

secrets:
  secret_pgpass:
    file: ./.secret/pgpass
  secret_db_pass:
    file: ./.secret/db_password
EOF
```
Проверьте в файле параметры:
- POSTGRES_CONF_ARGS - аргументы для Postgres
- ZBX_* - параметры zabbix посчитайте и замените

Запустить установку:
```bash
bash /opt/app/zabbix/install-zabbix-server-docker.sh /opt/app/zabbix
```

Откройте веб-интерфейс (в примере: http://zabbix.dc-12.local/). По дефолту логин и пароль: Admin/zabbix. Обязательно изменить пароль!


## Установка агента zabbix
```bash
# Проверка доступных версий в репозиториях
(command -v dnf && sudo dnf list zabbix-agent2) || (command -v apt && sudo apt list zabbix-agent2) || (command -v yum && sudo yum list zabbix-agent2)
# Установка
(command -v dnf && sudo dnf install zabbix-agent2) || (command -v apt && sudo apt install zabbix-agent2) || (command -v yum && sudo yum install zabbix-agent2)
```

### Настройка агента zabbix
```bash
sudo tee /etc/zabbix/zabbix_agent2.d/plugins.d/dc-12.conf << EOF
# Для всех серверов
#Server=zabbix.dc-12.local
# Для сервера где установлен zabbix-server
Server=$(command -v docker > /dev/null && sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zabbix-server)
#ServerActive=zabbix.dc-12.local
# Для сервера где установлен zabbix-server
ServerActive=$(command -v docker > /dev/null && sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zabbix-server)
SourceIP=$(hostname -I | grep -oP "(10|192).\d+.\d+.\d+" | head -n 1)
ListenIP=$(hostname -I | grep -oP "(10|192).\d+.\d+.\d+" | head -n 1)
Hostname=`hostname`
ListenPort=10050
LogFileSize=50
EOF
```

Проверить параметры
```bash
cat /etc/zabbix/zabbix_agent2.d/plugins.d/dc-12.conf
```

Запустить zabbix-agent2
```bash
sudo systemctl enable --now zabbix-agent2
```

В веб-zabbix в настройке хоста "Zabbix server" измените IP на IP хостового сервера. Замените шаблон "Linux by Zabbix agent" на "Linux by Zabbix agent active"

Приступайте к установке Zabbix-agent на серверах и подключению их в веб-zabbix.


## Описание и рекомендации по параметрам Zabbix Server
### Процессы (Pollers)
Эти параметры определяют количество рабочих процессов Zabbix Server, которые выполняют проверки и собирают данные.
| Параметр | Описание | Рекомендации по подбору |
| :--- | :--- | :--- |
| ZBX_STARTPOLLERS | Количество процессов поллеров, выполняющих пассивные проверки Zabbix Agent (порт 10050), а также проверки SNMP, IPMI, HTTP, ODBC и прокси-поллеров. | Должен покрывать пиковую потребность в параллельных проверках. <br><br>Правило: Начните с 100-200. Если в очереди появляются задержки (Queue), увеличивайте количество, пока время ожидания не стабилизируется. 100 активных элементов = \~1 поллер. |
| ZBX_STARTPOLLERSUNREACHABLE | Количество процессов, которые проверяют недоступные узлы сети (хосты, которые временно отключены). | Должно быть достаточно, чтобы быстро проверять узлы, находящиеся в состоянии "недоступно", не отвлекая основные поллеры. <br><br>Правило: Обычно 10-20% от ZBX_STARTPOLLERS. Ваши 50 – это достаточно много, что указывает на большой парк хостов. |
| ZBX_STARTPINGERS | Количество процессов, которые выполняют простые проверки доступности (ICMP ping, fping). | Эти проверки очень быстрые. <br><br>Правило: Начните с 5-10. Ваши 100 – слишком много, если только у вас нет десятков тысяч хостов. Чрезмерное количество пингеров может замедлить другие процессы. |

### Кэш базы данных (Cache)
Эти параметры определяют, сколько памяти Zabbix Server выделяет для кэширования конфигурации и данных, чтобы минимизировать количество запросов к базе данных (PostgreSQL/TimescaleDB).
| Параметр | Описание | Рекомендации по подбору |
| :--- | :--- | :--- |
| ZBX_CACHESIZE | Размер кэша конфигурации Zabbix. В нем хранится вся информация о хостах, элементах данных, триггерах, правилах низкоуровневого обнаружения (LLD). | Самый важный кэш. Если он заполнен, Zabbix Server постоянно обращается к БД. <br><br>Правило: Должен быть достаточно большим, чтобы хранить всю активную конфигурацию. Контролируйте метрику "Cache usage" в Zabbix: если она стабильно выше 80%, необходимо увеличить кэш. |
| ZBX_HISTORYCACHESIZE | Размер кэша для исторических числовых и текстовых данных, ожидающих записи в БД. | Используется для буферизации данных перед записью в таблицы history и history_uint. <br><br>Правило: Зависит от объема входящих данных. Убедитесь, что метрика "History cache usage" не достигает 100%, иначе данные могут быть потеряны. |
| ZBX_TRENDCACHESIZE | Размер кэша для трендовых данных, ожидающих записи в БД. | Используется для буферизации усредненных данных перед записью в таблицы trends. <br><br>Правило: Трендовых данных меньше, чем исторических. Убедитесь, что использование кэша трендов (метрика) находится на низком уровне. |
| ZBX_TRENDFUNCTIONCACHESIZE | Размер кэша для функций трендов, используемых при вычислении агрегаций. | <br><br>Правило: Обычно достаточно 32M-64M, если вы не используете много сложных функций трендов в выражениях триггеров. Ваш размер 512M, скорее всего, избыточен. |
| ZBX_VALUECACHESIZE | Размер кэша для кэширования последних значений элементов данных. Критически важен для быстрой работы триггеров и вычисляемых элементов. | Позволяет триггерам быстро получить последнее значение без запроса к БД. <br><br>Правило: Убедитесь, что метрика "Value cache usage" не превышает 80-90%. Это может быть узким местом при большом количестве триггеров. |

### Общие рекомендации по настройке
1.  Начните с мониторинга: Прежде чем менять эти параметры, запустите Zabbix с настройками по умолчанию и включите мониторинг самого Zabbix Server. Используйте шаблон Template App Zabbix Server.
2.  Смотрите на Queue (Очередь): Если "Zabbix queue" (очередь проверок) стабильно растет, это означает, что у вас недостаточно поллеров (ZBX_STARTPOLLERS) для обработки входящих данных.
3.  Смотрите на Cache Usage: Если любая из метрик кэша (ZBX_CACHESIZE, ZBX_VALUECACHESIZE и т.д.) стабильно выше 80%, необходимо увеличить размер соответствующего кэша.
4.  Сбалансируйте память: Общая сумма всех ваших кэшей (2G + 4 * 512M = 4G) плюс оперативная память для процессов Zabbix и PostgreSQL не должна превышать физический объем RAM, доступный контейнеру. Если вы используете TimescaleDB, большая часть RAM должна быть отдана PostgreSQL для его кэша.
5.  Пингеры: Уменьшите ZBX_STARTPINGERS до 5-10, если вы не обнаружите, что это вызывает проблемы с доступностью. Ваше текущее значение 100 – это большая трата ресурсов.

### Методика расчета оптимальных параметров
Оптимизация TimescaleDB для Zabbix фокусируется на двух ключевых областях:
1.  Рабочая память: Сколько памяти выделяется на запросы.
2.  Общий кэш: Сколько памяти PostgreSQL использует для кэширования данных и индексации.
#### Базовый принцип
Для сервера БД, который почти не занят ничем, кроме базы Zabbix, от 50% до 75% доступной оперативной памяти контейнера должно быть выделено под shared_buffers и effective_cache_size.
#### Расчетные параметры
| Параметр | Описание | Формула расчета |
| :--- | :--- | :--- |
| shared_buffers | Основной кэш, который PostgreSQL использует для хранения часто используемых данных и метаданных. | 25% от доступной RAM. (Максимум 8GB-16GB, даже если RAM больше) |
| effective_cache_size | Оценка того, сколько всего памяти доступно для кэширования (включая shared_buffers и кэш ОС). | 50% - 75% от доступной RAM. |
| maintenance_work_mem | Память, используемая для операций обслуживания, таких как VACUUM, CREATE INDEX, ALTER TABLE. | 10% от доступной RAM. (Максимум 1GB-2GB) |
| work_mem | Память, используемая для внутренних операций запросов (сортировка, хэширование). | Начните с 4MB–8MB. В TimescaleDB его иногда повышают до 64MB или 128MB, если есть сложные запросы. |
-----
### Оптимальные параметры для контейнера TimescaleDB
Предположим, что вы выделили контейнеру 4GB RAM. Вот примеры оптимальных настроек, которые можно передать через файл .conf или переменные окружения (например, через POSTGRES_CONF_ARGS или специальный скрипт инициализации).
| Параметр | Рекомендуемое значение (для 4GB RAM) | Обоснование |
| :--- | :--- | :--- |
| shared_buffers | 1024MB (1GB) | 25% от 4GB. Оптимальный размер для внутренней работы БД. |
| effective_cache_size | 3GB | 75% от 4GB. Помогает планировщику запросов. |
| maintenance_work_mem | 512MB | 12.5% от 4GB. Для быстрых операций обслуживания и создания чанков. |
| work_mem | 64MB | Увеличен для обработки больших запросов Zabbix и операций партиционирования. |
| max_connections | 100 – 300 | Должно быть немного больше, чем сумма всех поллеров, историанцев и трэпперов Zabbix Server. |
| timescaledb.max_background_workers | 8 | Должно быть установлено в соответствии с количеством ядер CPU, выделенных контейнеру. |
#### Конфигурация для Zabbix
Убедитесь также, что следующие параметры установлены, так как они важны для TimescaleDB:
1.  Опции TimeScaleDB:
```conf
# Разрешить параллельное выполнение запросов TimescaleDB
timescaledb.max_background_workers = 8
```
2.  Автовакуум (Auto-Vacuum): Автовакуум важен для очистки "мертвых" кортежей.
```conf
autovacuum = on
# Агрессивный автовакуум для занятых таблиц Zabbix
autovacuum_max_workers = 5 
autovacuum_vacuum_cost_delay = 10
```
### Настройка в Docker Compose
Вы можете передать эти параметры в контейнер TimescaleDB с помощью переменной окружения POSTGRES_CONF_ARGS (если ваш образ поддерживает это) или смонтировать файл конфигурации.
#### Пример через POSTGRES_CONF_ARGS
Если ваш образ поддерживает установку конфигурации через эту переменную (как это делают некоторые стандартные образы):
```yaml
services:
zabbix-postgres:
image: nexus.dc-12.local/timescale/timescaledb:2.21.4-pg17
environment:
  POSTGRES_DB: "${POSTGRES_DB}"
  # ...
  # Передача параметров конфигурации
  POSTGRES_CONF_ARGS: >
    -c shared_buffers=1024MB 
    -c effective_cache_size=3GB 
    -c maintenance_work_mem=512MB 
    -c work_mem=64MB
    -c max_connections=200
```
