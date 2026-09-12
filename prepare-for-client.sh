#!/bin/sh
#
# prepare-for-client.sh
# v0.6
#
# Запускать ПОСЛЕ:
# - ручной настройки SSClash
# - загрузки шаблона
# - настройки WARP / VLESS
# - проверки, что SSClash реально работает
#
# Скрипт сам:
# - при необходимости сбрасывает предыдущую "первую активацию"
# - останавливает SSClash
# - убирает SSClash из автозапуска
# - ставит механизм первой активации
# - ставит watchdog Mihomo
# - после появления реального интернета запускает SSClash
# - включает обычный автозапуск
#
# Проверка интернета:
# - Google connectivity check
# - Cloudflare connectivity check
# - ya.ru
#
# Окно ожидания:
# - первая проверка через 15 секунд
# - затем каждые 5 минут
# - до 60 минут
# - если не получилось, следующий ifup/update или перезагрузка
#   запустит цикл заново
#
set -u

SERVICE="ssclash"
FLAG="/etc/ssclash_first_run_done"
HOTPLUG="/etc/hotplug.d/iface/99-ssclash-first-online"
LOCKDIR="/tmp/ssclash-first-online.lock"
ACTIVATION_LOG="/tmp/ssclash-first-online.log"
PREP_LOG="/tmp/prepare-for-client.log"
ARM_AFTER_REBOOT="/tmp/ssclash-wait-for-next-boot"

WATCHDOG="/usr/bin/ssclash-watchdog"
WATCHDOG_CRON="*/2 * * * * /usr/bin/ssclash-watchdog"
WATCHDOG_FAIL="/tmp/ssclash-watchdog-fails"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$PREP_LOG"
}

die() {
    log "ОШИБКА: $*"
    exit 1
}

confirm() {
    prompt="$1"
    printf "%s [y/N]: " "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty
    case "$answer" in
        y|Y|yes|YES|да|Да|ДА) return 0 ;;
        *) return 1 ;;
    esac
}

: > "$PREP_LOG"

[ -x "/etc/init.d/$SERVICE" ] \
    || die "/etc/init.d/$SERVICE не найден. SSClash не установлен?"

echo "========================================"
echo "        ПОДГОТОВКА К ВЫДАЧЕ"
echo "========================================"
echo

if [ -f "$FLAG" ]; then
    echo "ВНИМАНИЕ: первая активация уже была выполнена."
    echo "Найден флаг:"
    echo "  $FLAG"
    echo

    if ! confirm "Сбросить первую активацию и подготовить роутер заново?"; then
        echo "Отменено. Ничего не изменено."
        exit 0
    fi

    echo
fi

if ! confirm "Ты уже проверила SSClash, WARP и VLESS?"; then
    echo "Отменено. Ничего не изменено."
    exit 0
fi

echo
log "Начинаю подготовку роутера..."

# Блокируем первую активацию до следующей загрузки.
touch "$ARM_AFTER_REBOOT"

# Сначала убираем старый hotplug, чтобы во время подготовки
# не запускались новые циклы первой активации.
if [ -e "$HOTPLUG" ]; then
    chmod 000 "$HOTPLUG" 2>/dev/null || true
fi

log "Останавливаю SSClash..."
/etc/init.d/$SERVICE stop >> "$PREP_LOG" 2>&1 || true

log "Убираю SSClash из автозапуска..."
/etc/init.d/$SERVICE disable >> "$PREP_LOG" 2>&1 || true

log "Сбрасываю состояние предыдущей первой активации..."
rm -f "$FLAG"
rm -rf "$LOCKDIR"
rm -f "$ACTIVATION_LOG"
rm -f "$WATCHDOG_FAIL"

# ============================================================
# WATCHDOG MIHOMO
# ============================================================

log "Устанавливаю watchdog Mihomo..."

cat > "$WATCHDOG" <<'EOF'
#!/bin/sh

SERVICE="ssclash"
FLAG="/etc/ssclash_first_run_done"
FAIL_FILE="/tmp/ssclash-watchdog-fails"

API="http://127.0.0.1:9090/version"

MAX_FAILS=3
TIMEOUT=5

# Пока первая успешная активация SSClash не выполнена,
# watchdog ничего не делает.
[ -f "$FLAG" ] || exit 0

# Проверяем API Mihomo.
if wget -q -T "$TIMEOUT" -O /dev/null "$API" 2>/dev/null; then
    echo 0 > "$FAIL_FILE"
    exit 0
fi

FAILS=0

if [ -f "$FAIL_FILE" ]; then
    FAILS="$(cat "$FAIL_FILE" 2>/dev/null)"
fi

case "$FAILS" in
    ''|*[!0-9]*)
        FAILS=0
        ;;
esac

FAILS=$((FAILS + 1))
echo "$FAILS" > "$FAIL_FILE"

logger -t ssclash-watchdog \
    "Mihomo API unavailable: $FAILS/$MAX_FAILS"

if [ "$FAILS" -lt "$MAX_FAILS" ]; then
    exit 0
fi

logger -t ssclash-watchdog \
    "Mihomo appears stuck; restarting SSClash"

/etc/init.d/"$SERVICE" restart

sleep 10

if wget -q -T "$TIMEOUT" -O /dev/null "$API" 2>/dev/null; then
    logger -t ssclash-watchdog \
        "SSClash recovered after restart"
    echo 0 > "$FAIL_FILE"
else
    logger -t ssclash-watchdog \
        "SSClash still unavailable after restart"
fi

exit 0
EOF

chmod 755 "$WATCHDOG"

# Добавляем watchdog в cron только один раз.
grep -qF "$WATCHDOG" /etc/crontabs/root 2>/dev/null || \
    echo "$WATCHDOG_CRON" >> /etc/crontabs/root

/etc/init.d/cron enable >> "$PREP_LOG" 2>&1 || true
/etc/init.d/cron restart >> "$PREP_LOG" 2>&1 || true

# ============================================================
# FIRST ONLINE ACTIVATION
# ============================================================

mkdir -p /etc/hotplug.d/iface

cat > "$HOTPLUG" <<'EOF'
#!/bin/sh

SERVICE="ssclash"
FLAG="/etc/ssclash_first_run_done"
LOCKDIR="/tmp/ssclash-first-online.lock"
LOG="/tmp/ssclash-first-online.log"
ARM_AFTER_REBOOT="/tmp/ssclash-wait-for-next-boot"

# Если первая успешная активация уже была — больше ничего не делаем.
[ -f "$FLAG" ] && exit 0

# Запрещаем активацию в той же загрузке, когда роутер готовили.
# /tmp очищается после reboot/power cycle.
[ -f "$ARM_AFTER_REBOOT" ] && exit 0

case "${ACTION:-}" in
    ifup|update) ;;
    *) exit 0 ;;
esac

# Защита от нескольких параллельных циклов,
# когда одновременно поднимаются разные интерфейсы.
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

[ -f "$FLAG" ] && exit 0

echo "$(date) event: action=${ACTION:-unknown} interface=${INTERFACE:-unknown}" >> "$LOG"

# Даём WAN, DNS и маршрутам немного времени подняться.
sleep 15

check_internet() {
    # Достаточно успешного HTTP-доступа хотя бы к одному адресу.
    wget -q -T 8 -O /dev/null http://connectivitycheck.gstatic.com/generate_204 2>/dev/null \
        && return 0

    wget -q -T 8 -O /dev/null http://cp.cloudflare.com/generate_204 2>/dev/null \
        && return 0

    wget -q -T 8 -O /dev/null http://ya.ru 2>/dev/null \
        && return 0

    return 1
}

# 13 проверок = первая сразу после 15 сек +
# ещё 12 проверок с интервалом 5 минут = окно примерно 60 минут.
attempt=1
max_attempts=13

while [ "$attempt" -le "$max_attempts" ]; do

    if [ -f "$FLAG" ]; then
        exit 0
    fi

    if check_internet; then
        echo "$(date) internet detected (attempt $attempt/$max_attempts)" >> "$LOG"

        # Сначала включаем автозапуск.
        if ! /etc/init.d/$SERVICE enable >> "$LOG" 2>&1; then
            echo "$(date) ERROR: failed to enable SSClash" >> "$LOG"
        else
            # Флаг создаём ТОЛЬКО если команда запуска завершилась успешно.
            if /etc/init.d/$SERVICE start >> "$LOG" 2>&1; then

                sleep 3

                touch "$FLAG"
                sync

                echo "$(date) SSClash started; first activation completed" >> "$LOG"
                exit 0
            else
                echo "$(date) ERROR: SSClash start failed; will retry" >> "$LOG"
                /etc/init.d/$SERVICE disable >> "$LOG" 2>&1 || true
            fi
        fi
    else
        echo "$(date) internet check $attempt/$max_attempts failed" >> "$LOG"
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
        sleep 300
    fi

    attempt=$((attempt + 1))
done

echo "$(date) internet/SSClash not confirmed within 60 min; waiting for next interface event" >> "$LOG"

exit 0
EOF

chmod 755 "$HOTPLUG"

# На всякий случай ещё раз фиксируем нужное состояние после записи hotplug.
rm -f "$FLAG"
rm -rf "$LOCKDIR"
rm -f "$WATCHDOG_FAIL"

/etc/init.d/$SERVICE stop >> "$PREP_LOG" 2>&1 || true
/etc/init.d/$SERVICE disable >> "$PREP_LOG" 2>&1 || true

log "Проверяю результат..."

[ ! -f "$FLAG" ] || die "Флаг $FLAG неожиданно существует"
[ -x "$HOTPLUG" ] || die "Hotplug-скрипт не создан или не исполняемый"
[ -x "$WATCHDOG" ] || die "Watchdog не создан или не исполняемый"

grep -qF "$WATCHDOG" /etc/crontabs/root \
    || die "Watchdog не добавлен в cron"

sync

echo
echo "========================================"
echo "       РОУТЕР ГОТОВ К ВЫДАЧЕ"
echo "========================================"
echo
echo "SSClash:          ОСТАНОВЛЕН"
echo "Автозапуск:       ВЫКЛЮЧЕН"
echo "Первая активация: СБРОШЕНА"
echo "Активация сейчас: ЗАБЛОКИРОВАНА ДО ПЕРЕЗАГРУЗКИ"
echo
echo "Watchdog Mihomo:  УСТАНОВЛЕН"
echo "Проверка API:     каждые 2 минуты"
echo "Рестарт после:    3 ошибок подряд"
echo
echo "WAN можно оставить подключённым."
echo "В текущей загрузке автоактивации не будет."
echo "После reboot/power cycle временная блокировка исчезнет."
echo
echo "На следующей загрузке после появления реального интернета:"
echo "  - первая проверка через 15 сек;"
echo "  - далее каждые 5 минут;"
echo "  - ожидание до 60 минут;"
echo "  - SSClash запускается;"
echo "  - автозапуск включается;"
echo "  - создаётся флаг успешной активации;"
echo "  - watchdog начинает контролировать Mihomo."
echo
echo "Если за час интернет не появился,"
echo "цикл запустится снова при следующем"
echo "ifup/update или после перезагрузки."
echo
echo "Лог первой активации:"
echo "  $ACTIVATION_LOG"
echo
echo "Флаг успешной активации:"
echo "  $FLAG"
echo
echo "Hotplug:"
echo "  $HOTPLUG"
echo
echo "Watchdog:"
echo "  $WATCHDOG"
echo
echo "Проверить watchdog:"
echo "  logread -e ssclash-watchdog"
echo
echo "Cron:"
echo "  grep ssclash-watchdog /etc/crontabs/root"
echo
echo "========================================"
