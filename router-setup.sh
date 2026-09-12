#!/bin/sh
#
# Единая точка запуска настройки роутера.
#
# 1-й запуск на чистом OpenWrt:
#   -> запускает первоначальную настройку
#   -> после успешного завершения ставит маркер этапа 1
#
# 2-й и последующие запуски:
#   -> видит маркер этапа 1
#   -> запускает подготовку к выдаче клиенту
#   -> prepare-for-client сам спросит подтверждение, что SSClash/WARP/VLESS проверены
#

set -u

STAGE1_FLAG="/etc/router_setup_stage1_done"

BASE_URL="https://raw.githubusercontent.com/zhilmax/router-setup/main"
SETUP_URL="$BASE_URL/setup-router.sh"
PREPARE_URL="$BASE_URL/prepare-for-client.sh"

SETUP_FILE="/tmp/setup-router.sh"
PREPARE_FILE="/tmp/prepare-for-client.sh"

download() {
    url="$1"
    dest="$2"

    echo "Скачиваю: $url"

    rm -f "$dest"

    if ! wget -T 30 -O "$dest" "$url"; then
        echo "ОШИБКА: не удалось скачать $url"
        exit 1
    fi

    if [ ! -s "$dest" ]; then
        echo "ОШИБКА: скачанный файл пустой: $dest"
        exit 1
    fi

    chmod +x "$dest"
}

echo "========================================"
echo "        ROUTER SETUP"
echo "========================================"

if [ ! -f "$STAGE1_FLAG" ]; then
    echo
    echo "Этап 1 ещё не выполнялся."
    echo "Запускаю первоначальную настройку роутера."
    echo

    download "$SETUP_URL" "$SETUP_FILE"

    if "$SETUP_FILE"; then
        touch "$STAGE1_FLAG"
        sync

        echo
        echo "========================================"
        echo "ЭТАП 1 ЗАВЕРШЁН"
        echo "========================================"
        echo "Маркер создан:"
        echo "  $STAGE1_FLAG"
        echo
        echo "Теперь вручную настрой и проверь SSClash/WARP/VLESS."
        echo "После этого снова запусти ЭТУ ЖЕ команду."
        echo
        echo "После смены LAN подключайся к 192.168.31.1."
        exit 0
    else
        echo
        echo "ОШИБКА: первоначальная настройка завершилась с ошибкой."
        echo "Маркер этапа 1 НЕ создан."
        exit 1
    fi
fi

echo
echo "Этап 1 уже выполнен."
echo "Маркер найден:"
echo "  $STAGE1_FLAG"
echo
echo "Перехожу к подготовке роутера к выдаче клиенту."
echo

download "$PREPARE_URL" "$PREPARE_FILE"
exec "$PREPARE_FILE"
