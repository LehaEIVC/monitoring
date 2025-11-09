#!/bin/bash
#shopt -s extdebug

LANG='en_US.utf8'
# Количество секунд ожидания инициализиции БД
_WAIT_SEC=60
_COUNT_STEPS=13

main() {
    _currentStep=0    
    # Запрещено запускать скрипт под пользователем root или через sudo
    [ "$(id -u)" -eq 0 ] && {
        _error "Запрещен запуск скрипта под пользователем 'root' или через 'sudo'!"
        return 100
    }

    [ -z "${1}" ] && {
        _error "Не указана директория для установки"
        echo -e "${COLORS[BRIGHT_YELLOW]}USE:${COLORS[RESET]} ${0} <директория установки>"
        echo -e "${COLORS[BRIGHT_YELLOW]}Например:${COLORS[RESET]} ${0} /opt/app/zabbix"
        return 101
    }  
    
    [ ! -d "${1}" ] &&  { _error "Директория не найдена: '${1}'"; return 102; }

    _pathApp=$1
    # ---
    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    # Перейти в директорию приложения
    _info "Установлена директория приложения: '${_pathApp}'"
    cd "${_pathApp}"


    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _info 'Проверка наличия файлов конфигураций'
    _CheckForExistenceOfConfigurationFiles


    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _info "Установка переменных:"
    _SetVariable

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _installPackages=(docker-ce docker-compose openssl bash-completion)
    _info "Установить пакеты: ${_installPackages[*]}"
    _InstallDocker "${_installPackages[@]}"

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    sudo docker-compose down || { _error "Ошибка выполнения: docker-compose down"; return 115; }
    _info "Останавлены все контейнеры: zabbix-server, zabbix-web-nginx-pgsql, zabbix-postgres, zabbix-backup-pg"

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _info "Настройка proxy для Docker..."
    _SetProxy

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _BuildImageZabbixServer

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _CheckZabbixServer 'zabbix-server-check'

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _info "Создание файлов с паролями..."
    _SetPermissionFilesPassword
    _info "Файлы с паролями созданы"

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _info "Инициализация БД или изменение пароля для пользователя '${_postgresUser}' в БД"
    _InitDbOrChangePasswordUserDB

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"
    _info "Запуск docker compose..."
    _RunDockerCompose

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"    
    _info "Проверка партицированния таблиц БД Zabbix"
    _CheckPartitionTables

    ((_currentStep++)); echo ""; _info "--- Шаг ${_currentStep} из ${_COUNT_STEPS}"    
    _info "Информация о версиях zabbix-server и timescaledb"
    _warning "Проверка версии расширения timescaledb. Убедиться, что Zabbix работает с версией TimescaleBD (https://www.zabbix.com/documentation/current/en/manual/installation/requirements Найти: TimescaleDB for PostgreSQL)"
    sudo docker exec zabbix-server zabbix_server --version | grep "zabbix_server"
    sudo docker exec zabbix-postgres psql -U "${_postgresUser}" -d "${_postgresDb}" -c '\dx' | grep "timescaledb"
    echo ""

}

_CheckForExistenceOfConfigurationFiles() {
    # Проверить файл параметров '.env'        
    [ ! -f "${_pathApp}/.env" ] && { _error "Файл не найден: '${_pathApp}/.env'"; _exit 110; }
    _info "Файл существует: ${_pathApp}/.env"

    # Проверить файл 'Dockerfile'
    [ ! -f "${_pathApp}/Dockerfile" ] && { _error "Файл не найден: '${_pathApp}/Dockerfile'"; _exit 112; }
    _info "Файл существует: ${_pathApp}/Dockerfile"

    [ ! -f "${_pathApp}/docker-compose.yaml" ] && { _error "Файл не найден: '${_pathApp}/docker-compose.yaml'"; _exit 114; }
    _info "Файл существует: ${_pathApp}/docker-compose.yaml"
}

_SetVariable() {
    _dbServerHost="$(sudo grep -E '^DB_SERVER_HOST=' ${_pathApp}/.env | cut -d '=' -f 2)"; _info "_dbServerHost=${_dbServerHost}"
    _dbServerPort="$(sudo grep -E '^DB_SERVER_PORT=' ${_pathApp}/.env | cut -d '=' -f 2)"; _info "_dbServerPort=${_dbServerPort}"
    _postgresDb="$(sudo grep -E '^POSTGRES_DB=' ${_pathApp}/.env | cut -d '=' -f 2)"; _info "_postgresDb=${_postgresDb}"
    _postgresUser="$(sudo grep -E '^POSTGRES_USER=' ${_pathApp}/.env | cut -d '=' -f 2)"; _info "_postgresUser=${_postgresUser}"
    _nexus="$(sudo grep -E '^NEXUS=' .env | cut -d '=' -f 2)"; _info "_nexus=${_nexus}"
    _tagZabbix="$(sudo grep -E '^TAG_ZABBIX=' .env | cut -d '=' -f 2)"; _info "_tagZabbix=${_tagZabbix}"
    _tagTimescaledb="$(sudo grep -E '^TAG_TIMESCALEDB=' ${_pathApp}/.env | cut -d '=' -f 2)"; _info "_tagTimescaledb=${_tagTimescaledb}"
    _localImagesZabbixName="$(sudo grep -E '^IMAGE_ZABBIX_SERVER=' .env | cut -d '=' -f 2)"; _info "_localImagesZabbixName=${_localImagesZabbixName}"
    _pgData="$(sudo grep -E '^PG_DATA=' .env | cut -d '=' -f 2)"; _info "_pgData=${_pgData}"
    _zabbixLog="$(sudo grep -E '^ZABBIX_LOG=' .env | cut -d '=' -f 2)"; _info "_zabbixLog=${_zabbixLog}"
    _httpProxy="$(sudo grep -E '^HTTP_PROXY=' .env | cut -d '=' -f 2)"; _info "_httpProxy=${_httpProxy}"
    _httpsProxy="$(sudo grep -E '^HTTPS_PROXY=' .env | cut -d '=' -f 2)"; _info "_httpsProxy=${_httpsProxy}"
}

_InstallDocker() {    
    (command -v dnf >> /dev/null && sudo dnf install -y "$@") \
    || (command -v apt >> /dev/null && sudo apt install -y "$@") \
    || (command -v yum >> /dev/null && sudo yum install -y "$@") \
        && _info "Установлены пакеты: $*" \
        || { _error "Ошибка установки пакетов: $*"; _exit 120; }
    
    # ---
    _info "Запустить docker и установить автозагрузку"
    sudo systemctl enable --now docker \
        && _info "Сервис "docker" запущен и добавлен в автозагрузку" \
        || { _error "Ошибка при запуске сервиса 'docker'"; _exit 125; }
}

_RemoveContainer() {
    _containerName="$1"
    # Проверка, существует ли контейнер
    sudo docker container inspect "${_containerName}" &> /dev/null && {
        _info "Остановка и удаление существуещего контейнера '${_containerName}'"
        sudo docker rm -f "${_containerName}" 1> /dev/null
    }
}

_SetPermissionFilesPassword() {
    #---
    _info 'Создание директории для паролей'
    sudo mkdir -p ${_pathApp}/.secret
       
    _info "Создание файла с паролем для пользователя '${_postgresUser}' БД '${_postgresDb}'"
    echo "$(openssl rand -base64 32 | tr -d '\n')" | sudo tee ${_pathApp}/.secret/db_password 1> /dev/null \
        && _info "Пароль для БД сгенерирован и сохранен в файле '${_pathApp}/.secret/db_password'" \
        || { _error "Ошибка при генерации пароля для БД в файл '${_pathApp}/.secret/db_password'"; _exit 140; }

    sudo cp ${_pathApp}/.secret/db_password ${_pathApp}/.secret/db_password_zabbix_server \
        && _info "Пароль для БД скопирован в файл '${_pathApp}/.secret/db_password_zabbix_server'" \
        || { _error "Ошибка при копировании пароля в файл '${_pathApp}/.secret/db_password_zabbix_server'"; _exit 141; }
    sudo chown "${_userId}":"${_groupId}" "${_pathApp}/.secret/db_password_zabbix_server" \
        && _info "Назначены права для файла '${_pathApp}/.secret/db_password_zabbix_server'" \
        || { _error "Ошибка назначения прав на файл '${_pathApp}/.secret/db_password_zabbix_server'"; _exit 142; }
    
    sudo cp ${_pathApp}/.secret/db_password ${_pathApp}/.secret/db_password_zabbix_web \
        && _info "Пароль для БД скопирован в файл '${_pathApp}/.secret/db_password_zabbix_web'" \
        || { _error "Ошибка при копировании пароля в файл '${_pathApp}/.secret/db_password_zabbix_web'"; _exit 143; }
    sudo chown "${_userId}":"${_groupId}" "${_pathApp}/.secret/db_password_zabbix_web" \
        && _info "Назначены права для файла '${_pathApp}/.secret/db_password_zabbix_web'" \
        || { _error "Ошибка назначения прав на файл '${_pathApp}/.secret/db_password_zabbix_web'"; _exit 144; }

    # Создать файл .pgpass контейнера бекапирования СУБД
    echo "${_dbServerHost}:${_dbServerPort}:${_postgresDb}:${_postgresUser}:$(sudo cat ${_pathApp}/.secret/db_password)" \
                        | sudo tee ${_pathApp}/.secret/pgpass 1> /dev/null \
        && _info "Файл с параметрами подключения к БД создан успешно: '${_pathApp}/.secret/pgpass'" \
        || { _error "Ошибка при создании файла параметров подключения к БД: ${_pathApp}/.secret/pgpass'"; _exit 145; }

    # Установка прав доступа к директории и файлам паролей
    sudo chmod -R 400 ${_pathApp}/.secret \
        && _info "Права доступа к диреткории с файлами паролей установлены: $(stat -c "%a" ${_pathApp}/.secret) -> '${_pathApp}/.secret'" \
        || { _error "Ошибка установки прав доступа к директории с файлами паролей: '${_pathApp}/.secret'"; _exit 146; }

    _info "Назначить владельцем пользователя zabbix из контейнера zabbix-server для директории логов '${_zabbixLog}' и файлов паролей"
    sudo mkdir -p "${_zabbixLog}" && _info "Директория для контейнера 'zabbix-server' создана" \
        || _warning "Не создана директория для 'zabbix-server'"
    sudo chown "${_userId}":"${_groupId}" "${_zabbixLog}" \
        && _info "Назначены права для контейнера 'zabbix-server'" \
        || { _error "Ошибка назначения прав на директорию для 'zabbix-server'"; _exit 147; }    
}

_SetProxy() {
    [[ ! -z "${_httpProxy}" ]] && [ $(sudo grep -P "${_httpProxy}|${_httpsProxy}" /etc/systemd/system/docker.service.d/proxy.conf \
                                           | wc -l) -ne 2 ] && {
        
        _info "Создать директорию '/etc/systemd/system/docker.service.d'"
        sudo mkdir -p /etc/systemd/system/docker.service.d
        _info "Создать файл /etc/systemd/system/docker.service.d/proxy.conf"
        sudo tee /etc/systemd/system/docker.service.d/proxy.conf << EOF
[Service]
Environment="HTTP_PROXY=${_httpProxy}"
Environment="HTTPS_PROXY=${_httpsProxy}"
Environment="NO_PROXY=localhost,127.0.0.1,.local,.rzd"
EOF
        _info "Перезапуск Docker..."
        sudo systemctl daemon-reload
        sudo systemctl restart docker && _info "Proxy для Docker успешно настроен" \
                || { _error "Ошибка настройки Proxy для Docker"; exit 119; }
    } || _info "Настройка Proxy не требуется"
}

_BuildImageZabbixServer() {
    _info 'Собрать образ '${_localImagesZabbixName}' с установленными утилитами: curl и js'
    sudo HTTP_PROXY="${_httpProxy}" HTTPS_PROXY="${_httpsProxy}" docker build --progress=plain --build-arg NEXUS="${_nexus}" \
                      --build-arg HTTP_PROXY="${_httpProxy}" --build-arg HTTPS_PROXY="${_httpsProxy}" \
                      --build-arg TAG_ZABBIX="${_tagZabbix}" \
                      -t "${_localImagesZabbixName}" \
                      . \
        && _info "Образ '${_localImagesZabbixName}' собран успешно" \
        || { _error "Ошибка при сборке образа: '${_localImagesZabbixName}'"; _exit 130; }

    # Проверить образ
    sudo docker images | grep "$(echo ${_localImagesZabbixName} | cut -d ':' -f 1)" \
        || { _error "Образ '$(echo ${_localImagesZabbixName} | cut -d ':' -f 1)' не найден"; _exit 120; }
}

_CheckZabbixServer() {
    _containerName="$1"

    _RemoveContainer "${_containerName}"
    
    _info "Запустить контейнер '${_containerName}'..."
    sudo docker run -d --rm --name "${_containerName}" ${_localImagesZabbixName} tail -f /dev/null > /dev/null \
        && _info "Контейнер '${_containerName}' запущен успешно" \
        || { _error "Ошибка запуска контейнера '${_containerName}'"; _exit 132; }

    _info "Проверяем установленный пакет 'curl' в контейнере '${_containerName}'..."
    sudo docker exec "${_containerName}" curl --version > /dev/null && _info "Пакет 'curl' - установлен" \
        || _warning "Пакет 'curl' - НЕ установлен. Не будет возможности отправлять события в Alertmanager. Проверьте ошибки при сборке образа '${_localImagesZabbixName}'"
    _info "Проверяем установленный пакет 'jq' в контейнере '${_containerName}'..."
    sudo docker exec "${_containerName}" jq --version > /dev/null && _info "Пакет 'jq' - установлен" \
        || _warning "Пакет 'jq' - НЕ установлен. Не будет возможности отправлять события в Alertmanager. Проверьте ошибки при сборке образа '${_localImagesZabbixName}'"

    _info "Получениe ID пользователя 'zabbix' и группы в контейнере '${_containerName}'"
    # _userId="$(sudo docker run --rm ${_localImagesZabbixName} id -u)" \
    _userId="$(sudo docker exec "${_containerName}" id -u)" \
        || { _error "Ошибка получения ID пользователя"; _exit 133; }
    # _groupId="$(sudo docker run --rm ${_localImagesZabbixName} id -g)" \
    _groupId="$(sudo docker exec "${_containerName}" id -g)" \
        || { _error "Ошибка получения ID группы"; _exit 134; }
    _info "userId=${_userId}, groupId=${_groupId}"

    _info "Останавка контейнера '${_containerName}'..."
    sudo docker stop ${_containerName} > /dev/null || true
    _info "Останавка контейнера '${_containerName}' выполнена успешно"
}

_InitDbOrChangePasswordUserDB() {
    [ -d "${_pgData}" ] && sudo ls -A "${_pgData}" | grep -q . && {
        _warning "Инициализация БД пропущена. Директория БД не пустая: ${_pgData}"
        _warning "Для инициализации БД выполнить команду УДАЛЕНИЯ ДИРЕКТОРИИ БД и ВСЕХ ЕЕ ДАННЫХ, затем повторить установку: sudo rm -rf ${_pgData}"

        _containerName='postgres-change-pass'
        _RemoveContainer "${_containerName}"
            
        _info "Изменение пароля для пользователя '${_postgresUser}' БД '${_postgresDb}'..."
        _info "Запуск контейнера '${_containerName}'"
        sudo docker run -d --name "${_containerName}" -v "${_pgData}":/var/lib/postgresql/data:rw \
                                  "${_nexus}timescale/timescaledb:${_tagTimescaledb}" > /dev/null

        _info "Ожидание запуска БД в течении ${_WAIT_SEC} сек..."
        _isRunDB=false
        for ((i=1; i<_WAIT_SEC; i++)); do
            sudo docker exec "${_containerName}" pg_isready -U "${_postgresUser}" -d "${_postgresDb}" \
            && {
                _info "Запуск БД выполнен успешно"
                _isRunDB=true
                break
            } || {
                echo "Ожидание $i сек..."; 
                sleep 1;
            }
        done
        ! $_isRunDB && {
             _error "Не удалось запустить БД. Изучите логи контейнера инициализации: sudo docker logs ${_containerName}";
            _exit 152;
        }

        sudo docker exec -i "${_containerName}" psql -U "${_postgresUser}" -d "${_postgresDb}" \
                              -c "ALTER USER ${_postgresUser} PASSWORD '$(sudo cat ${_pathApp}/.secret/db_password)';" \
            && _info "Пароль в БД '${_postgresDb}' для пользователя '${_postgresUser}' успешно изменен" \
            || { _info "Ошибка изменения пароля в БД '${_postgresDb}' для пользователя '${_postgresUser}'"; exit 154; }

    } || {
        _containerName='postgres-init'
        _RemoveContainer "${_containerName}"
        
        # Запустить контейнер timescaledb который выполнит инициализацию (создать БД и пользователя)
        _info "Запуск контейнера '${_containerName}'..." 
        sudo docker run -d --name "${_containerName}" --env-file .env -e POSTGRES_PASSWORD="$(sudo cat ${_pathApp}/.secret/db_password)" \
                        -v ${_pgData}:/var/lib/postgresql/data:rw ${_nexus}timescale/timescaledb:${_tagTimescaledb} > /dev/null \
            && _info "Контейнер '${_containerName}' запущен. Инициализация БД..." \
            || { _error "Ошибка запуска контейнера '${_containerName}'"; _exit 158; }

        # Следующие команды дожидаются в контейнере postgres-init готовности принимать подключения БД 'pg_isready'
        # и установки расширения 'timescaledb' в течении $_WAIT_SEC секунд
        _info "Ожидание инициализации БД и установки расширения 'timescaledb' в течении ${_WAIT_SEC} сек..."
        _isInitDB=false
        for ((i=1; i<_WAIT_SEC; i++)); do
            sudo docker exec "${_containerName}" pg_isready -U "${_postgresUser}" -d "${_postgresDb}" \
                    && sudo docker exec "${_containerName}" psql -U "${_postgresUser}" -d "${_postgresDb}" \
                                -c "select extname, extversion from pg_extension;" | grep "timescaledb" \
            && {
                _info "Инициализация БД выполнена успешно"
                _isInitDB=true
                break                
            } || {
                echo "Ожидание $i сек..."; 
                sleep 1;
            }
        done
        ! $_isInitDB && {
            _error "Не удалось инициализировать БД. Изучите логи контейнера инициализации: sudo docker logs ${_containerName}";
            _exit 152;
        }
    }

    _info "Остановка контейнера '${_containerName}'..."
    sudo docker stop "${_containerName}" > /dev/null \
        && _info "Контейнер '${_containerName}' остановлен" \
        || { _error "Ошибка остановки контейнера '${_containerName}'"; _exit 156; }
}

_RunDockerCompose() {
    _info "Определяем, используется плагин 'docker compose' или утилита 'docker-compose'..."
    sudo docker --help | grep -q "Docker Compose" && _cmd_compose='docker compose' \
                                                  || _cmd_compose='docker-compose'
    _info "Определен: ${_cmd_compose}"

    _info "Проверка корректности файла 'docker-compose.yaml'"
    sudo ${_cmd_compose} config && _info "Ошибок в файле 'docker-compose.yaml' не выявлено" \
                                  || { _error "Ошибки в файле 'docker-compose.yaml'"; return 160; }

    _info "Запуск docker-compose..."
    sudo ${_cmd_compose} up -d && _info "Запуск выполнен успешено" \
                                 || { _error "Ошибка при запуске docker-compose"; return 162; }
}

_CheckPartitionTables() {
    _info "Проверка настройки партицирования таблиц для БД Zabbix..."
    sudo docker exec zabbix-postgres psql -U "${_postgresUser}" -d "${_postgresDb}" \
                -c 'SELECT * FROM timescaledb_information.hypertables;' | grep -P "history_|auditlog|trends" \
        && _info "Партицирование таблиц для БД Zabbix настроено" \
        || {
            _warning "Партицирование НЕ натроено, производится настройка..."
            sudo docker exec zabbix-server bash -c "PGPASSWORD=\"$(sudo cat ${_pathApp}/.secret/db_password)\" \
                                                    psql -h "${_dbServerHost}" \
                                                    -p \"${_dbServerPort}\" \
                                                    -U \"${_postgresUser}\" \
                                                    -d \"${_postgresDb}\" \
                                                    -f /usr/share/doc/zabbix-server-postgresql/timescaledb.sql" \
                || { _error "Ошибка настройки партицирования таблиц для БД Zabbix"; _exit 170; }

                _info "Проверка настройки партицированных таблиц для БД Zabbix..."
                sudo docker exec zabbix-postgres psql -U "${_postgresUser}" -d "${_postgresDb}" \
                        -c 'SELECT * FROM timescaledb_information.hypertables;' | grep -P "history_|auditlog|trends" \
                    && _info "Партицирование таблиц для БД Zabbix настроено успешно" \
                    || { _error "Ошибка настройки партицирования таблиц для БД Zabbix"; _exit 172; }
        }
}

_error() {
    echo -e "${COLORS[BRIGHT_RED]}ERROR:${COLORS[RESET]} ${1}"
}

_warning() {
    echo -e "${COLORS[BRIGHT_YELLOW]}WARNING:${COLORS[RESET]} ${1}"
}

_info() {
    echo -e "${COLORS[BRIGHT_GREEN]}INFO:${COLORS[RESET]} ${1}"
}

declare -Ar COLORS=(
    # Сброс стилей
    ["RESET"]="\033[0m"
    # Основные цвета текста (30-37)
    ["BLACK"]="\033[0;30m"
    ["RED"]="\033[0;31m"
    ["GREEN"]="\033[0;32m"
    ["YELLOW"]="\033[0;33m"
    ["BLUE"]="\033[0;34m"
    ["MAGENTA"]="\033[0;35m"
    ["CYAN"]="\033[0;36m"
    ["WHITE"]="\033[0;37m"
    # Яркие цвета текста (90-97)
    ["BRIGHT_BLACK"]="\033[0;90m"
    ["BRIGHT_RED"]="\033[0;91m"
    ["BRIGHT_GREEN"]="\033[0;92m"
    ["BRIGHT_YELLOW"]="\033[0;93m"
    ["BRIGHT_BLUE"]="\033[0;94m"
    ["BRIGHT_MAGENTA"]="\033[0;95m"
    ["BRIGHT_CYAN"]="\033[0;96m"
    ["BRIGHT_WHITE"]="\033[0;97m"
    # Основные цвета фона (40-47)
    ["BG_BLACK"]="\033[0;40m"
    ["BG_RED"]="\033[0;41m"
    ["BG_GREEN"]="\033[0;42m"
    ["BG_YELLOW"]="\033[0;43m"
    ["BG_BLUE"]="\033[0;44m"
    ["BG_MAGENTA"]="\033[0;45m"
    ["BG_CYAN"]="\033[0;46m"
    ["BG_WHITE"]="\033[0;47m"
    # Яркие цвета фона (100-107)
    ["BG_BRIGHT_BLACK"]="\033[0;100m"
    ["BG_BRIGHT_RED"]="\033[0;101m"
    ["BG_BRIGHT_GREEN"]="\033[0;102m"
    ["BG_BRIGHT_YELLOW"]="\033[0;103m"
    ["BG_BRIGHT_BLUE"]="\033[0;104m"
    ["BG_BRIGHT_MAGENTA"]="\033[0;105m"
    ["BG_BRIGHT_CYAN"]="\033[0;106m"
    ["BG_BRIGHT_WHITE"]="\033[0;107m"
    # Стили текста
    ["BOLD"]="\033[1m"
    ["DIM"]="\033[2m"
    ["ITALIC"]="\033[3m"
    ["UNDERLINE"]="\033[4m"
    ["BLINK"]="\033[5m"
    ["REVERSE"]="\033[7m"
    ["HIDDEN"]="\033[8m"
    ["STRIKETHROUGH"]="\033[9m"
)

_exit() {
    local _returnCode=$1
    echo -e "[_exit]: _returnCode=${COLORS[BRIGHT_RED]}${_returnCode}${COLORS[RESET]}"

    exit ${_returnCode}
}

main "$@"
_returnCode=$?
echo -e "\nОткройте в браузере: http://`hostname`/ \n"

[ "${BASH_SOURCE[0]}" == "$0" ] && {
    [ "${_returnCode}" == "0" ] && _outReturnCode="${COLORS[BRIGHT_GREEN]}${_returnCode}${COLORS[RESET]}" \
                                || _outReturnCode="${COLORS[BRIGHT_RED]}${_returnCode}${COLORS[RESET]}"
    echo -e "console: _returnCode=${_outReturnCode}"
    exit ${_returnCode}
}
