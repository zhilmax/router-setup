#!/bin/sh
#
# setup-router.sh — первичная подготовка чистого OpenWrt
# TEST v0.3
#
# Что делает:
#  1) спрашивает SSID 2.4 / Wi-Fi пароль / root пароль; SSID 5 = SSID-5G
#  2) ставит русский LuCI
#  3) ставит и настраивает ZeroTier
#  4) создаёт отдельную firewall-зону ZeroTier (zt+ -> ACCEPT)
#     WAN при этом НЕ открывается
#  5) ставит hostname = SSID 2.4 и часовой пояс Europe/Moscow
#  6) добавляет SSH public key
#  7) включает и настраивает Wi-Fi WPA2
#  8) меняет LAN 192.168.1.1 -> 192.168.31.1 В САМОМ КОНЦЕ
#
# SSClash устанавливается и настраивается вручную после этого скрипта.
#

set -u

TARGET_LAN_IP="192.168.31.1"
TARGET_LAN_CIDR="192.168.31.1/24"
TIMEZONE="MSK-3"
ZONENAME="Europe/Moscow"

ZEROTIER_NETWORK_ID="885033839050bb6a"

SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOS17ax2MPBzALcOvBzw7ng8RATKOlIMkHpXTbdTclxr luci-key"

LOG="/tmp/setup-router.log"
BACKUP="/tmp/openwrt-before-setup-$(date '+%Y%m%d-%H%M%S').tar.gz"


# =========================================================
# ОБЩИЕ ФУНКЦИИ
# =========================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

die() {
    log "ОШИБКА: $*"
    exit 1
}

ask_secret() {
    prompt="$1"
    varname="$2"

    printf "%s" "$prompt" >/dev/tty
    stty -echo </dev/tty
    IFS= read -r value </dev/tty
    stty echo </dev/tty
    printf "\n" >/dev/tty

    eval "$varname=\$value"
}

ask_nonempty() {
    prompt="$1"
    varname="$2"

    while :; do
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r value </dev/tty

        [ -n "$value" ] && break

        echo "Значение не может быть пустым." >/dev/tty
    done

    eval "$varname=\$value"
}


# =========================================================
# ПАКЕТНЫЙ МЕНЕДЖЕР
# =========================================================

pkg_update() {
    if command -v apk >/dev/null 2>&1; then
        log "Обновляю индекс APK..."
        apk update || die "apk update завершился ошибкой"

    elif command -v opkg >/dev/null 2>&1; then
        log "Обновляю индекс OPKG..."
        opkg update || die "opkg update завершился ошибкой"

    else
        die "Не найден ни apk, ни opkg"
    fi
}

pkg_add() {
    if command -v apk >/dev/null 2>&1; then
        apk add "$@" || die "Не удалось установить: $*"
    else
        opkg install "$@" || die "Не удалось установить: $*"
    fi
}


# =========================================================
# UCI
# =========================================================

uci_get() {
    uci -q get "$1" 2>/dev/null || true
}


# =========================================================
# ПОИСК WI-FI ИНТЕРФЕЙСОВ
# =========================================================

find_ap_by_band() {
    wanted="$1"

    for sec in $(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do

        mode="$(uci_get wireless.$sec.mode)"
        [ "$mode" = "ap" ] || continue

        dev="$(uci_get wireless.$sec.device)"
        band="$(uci_get wireless.$dev.band)"
        hwmode="$(uci_get wireless.$dev.hwmode)"
        channel="$(uci_get wireless.$dev.channel)"

        case "$wanted" in

            24)
                if [ "$band" = "2g" ] || [ "$hwmode" = "11g" ]; then
                    echo "$sec"
                    return 0
                fi

                case "$channel" in
                    ''|auto|*[!0-9]*) ;;
                    *)
                        [ "$channel" -le 14 ] && {
                            echo "$sec"
                            return 0
                        }
                        ;;
                esac
                ;;

            5)
                if [ "$band" = "5g" ] || [ "$hwmode" = "11a" ]; then
                    echo "$sec"
                    return 0
                fi

                case "$channel" in
                    ''|auto|*[!0-9]*) ;;
                    *)
                        [ "$channel" -gt 14 ] && {
                            echo "$sec"
                            return 0
                        }
                        ;;
                esac
                ;;
        esac
    done

    return 1
}


# =========================================================
# ROOT PASSWORD
# =========================================================

set_root_password() {
    log "Устанавливаю пароль root..."

    if printf '%s\n%s\n' \
        "$ROOT_PASSWORD" \
        "$ROOT_PASSWORD" \
        | passwd root >/tmp/passwd-setup.out 2>&1
    then
        log "Пароль root установлен."
    else
        cat /tmp/passwd-setup.out 2>/dev/null | tee -a "$LOG"
        die "Не удалось установить пароль root"
    fi

    rm -f /tmp/passwd-setup.out
}


# =========================================================
# ATTENDED SYSUPGRADE
# =========================================================

configure_attendedsysupgrade() {
    log "Отключаю login_check_for_upgrades в attendedsysupgrade..."

    if uci -q get attendedsysupgrade.client >/dev/null 2>&1; then

        uci set attendedsysupgrade.client.login_check_for_upgrades='0'
        uci commit attendedsysupgrade

        log "attendedsysupgrade.client.login_check_for_upgrades=0"

    else
        log "ПРЕДУПРЕЖДЕНИЕ: секция attendedsysupgrade.client не найдена — настройка пропущена."
    fi
}


# =========================================================
# HOSTNAME / TIMEZONE
# =========================================================

configure_system_identity() {
    log "Настраиваю hostname и часовой пояс..."

    uci set system.@system[0].hostname="$HOSTNAME"
    uci set system.@system[0].timezone="$TIMEZONE"
    uci set system.@system[0].zonename="$ZONENAME"

    uci commit system

    service system reload 2>/dev/null || true

    log "Hostname: $HOSTNAME"
    log "Часовой пояс: $ZONENAME"
}


# =========================================================
# SSH KEY
# =========================================================

install_ssh_key() {
    log "Добавляю SSH public key..."

    mkdir -p /etc/dropbear
    touch /etc/dropbear/authorized_keys

    chmod 700 /etc/dropbear
    chmod 600 /etc/dropbear/authorized_keys

    if grep -Fqx "$SSH_PUBLIC_KEY" /etc/dropbear/authorized_keys; then
        log "SSH-ключ уже присутствует."
    else
        echo "$SSH_PUBLIC_KEY" >> /etc/dropbear/authorized_keys
        log "SSH-ключ добавлен."
    fi
}


# =========================================================
# RUSSIAN LUCI
# =========================================================

install_russian_luci() {
    log "Устанавливаю русскую локализацию LuCI..."

    RU_PACKAGES="
luci-i18n-attendedsysupgrade-ru
luci-i18n-firewall-ru
luci-i18n-package-manager-ru
luci-i18n-base-ru
"

    if command -v apk >/dev/null 2>&1; then

        apk add $RU_PACKAGES \
            || die "Не удалось установить русские пакеты LuCI"

    elif command -v opkg >/dev/null 2>&1; then

        opkg install $RU_PACKAGES \
            || die "Не удалось установить русские пакеты LuCI"

    else
        die "Не найден ни apk, ни opkg"
    fi

    # Явно выбираем русский язык LuCI.
    if uci -q get luci.main >/dev/null 2>&1; then
        uci set luci.main.lang='ru'
        uci commit luci
    fi

    rm -rf /tmp/luci-* 2>/dev/null || true

    service uhttpd restart 2>/dev/null || true

    log "Русская локализация LuCI установлена."
}


# =========================================================
# ZEROTIER
# =========================================================

configure_zerotier() {
    log "Настраиваю ZeroTier..."

    uci set zerotier.global.enabled='1'

    # Удаляем стандартную earth-сеть, если она существует.
    uci -q delete zerotier.earth || true

    # Наша ZeroTier-сеть.
    uci set zerotier.mynet='network'
    uci set zerotier.mynet.id="$ZEROTIER_NETWORK_ID"

    uci commit zerotier

    # ZeroTier должен автоматически запускаться после reboot.
    service zerotier enable

    service zerotier restart \
        || die "Не удалось перезапустить ZeroTier"

    log "ZeroTier настроен."
    log "Network ID: $ZEROTIER_NETWORK_ID"
}


# =========================================================
# FIREWALL — ZEROTIER
# =========================================================

configure_firewall() {
    log "Настраиваю отдельную firewall-зону ZeroTier..."

    # При повторном запуске не создаём дубликаты.
    uci -q delete firewall.zerotier || true

    uci set firewall.zerotier='zone'
    uci set firewall.zerotier.name='zerotier'

    uci set firewall.zerotier.input='ACCEPT'
    uci set firewall.zerotier.output='ACCEPT'
    uci set firewall.zerotier.forward='ACCEPT'

    # ZeroTier создаёт интерфейс с уникальным именем,
    # поэтому используем wildcard zt+.
    uci add_list firewall.zerotier.device='zt+'

    uci commit firewall

    service firewall restart \
        || die "Не удалось перезапустить firewall"

    log "Firewall ZeroTier настроен."
    log "Устройства zt+ -> INPUT/OUTPUT/FORWARD ACCEPT."
    log "Глобальный INPUT firewall не изменяем."
    log "WAN остаётся закрытым штатными правилами OpenWrt."
}


# =========================================================
# WIFI
# =========================================================

configure_wifi() {
    log "Определяю Wi-Fi секции..."

    WIFI24_SEC="$(find_ap_by_band 24 || true)"
    WIFI5_SEC="$(find_ap_by_band 5 || true)"

    [ -n "$WIFI24_SEC" ] || {
        uci show wireless | tee -a "$LOG"
        die "Не удалось определить AP-секцию 2.4 ГГц"
    }

    [ -n "$WIFI5_SEC" ] || {
        uci show wireless | tee -a "$LOG"
        die "Не удалось определить AP-секцию 5 ГГц"
    }

    log "2.4 ГГц: $WIFI24_SEC"
    log "5 ГГц:   $WIFI5_SEC"

    uci set "wireless.$WIFI24_SEC.ssid=$SSID24"
    uci set "wireless.$WIFI24_SEC.encryption=psk2"
    uci set "wireless.$WIFI24_SEC.key=$WIFI_PASSWORD"
    uci set "wireless.$WIFI24_SEC.disabled=0"

    uci set "wireless.$WIFI5_SEC.ssid=$SSID5"
    uci set "wireless.$WIFI5_SEC.encryption=psk2"
    uci set "wireless.$WIFI5_SEC.key=$WIFI_PASSWORD"
    uci set "wireless.$WIFI5_SEC.disabled=0"

    uci commit wireless

    wifi reload \
        || die "Не удалось перезагрузить Wi-Fi"

    log "Wi-Fi включён и настроен."
}


# =========================================================
# LAN IP — В САМОМ КОНЦЕ
# =========================================================

change_lan_ip_last() {

    current="$(uci_get network.lan.ipaddr)"

    log "ВАЖНО: заменяю все IPv4-адреса LAN на $TARGET_LAN_CIDR"
    log "Текущий LAN: $current"
    log "Старый адрес 192.168.1.1/24 будет удалён."
    log "SSH-соединение может оборваться. Это НОРМАЛЬНО."
    log "После этого подключайся к: $TARGET_LAN_IP"

    # В этой прошивке ipaddr может храниться как список CIDR.
    # Полностью удаляем старое значение.
    uci -q delete network.lan.ipaddr || true

    # Добавляем только новый адрес.
    uci add_list network.lan.ipaddr="$TARGET_LAN_CIDR"

    # Отдельный netmask больше не нужен,
    # поскольку /24 уже указан в CIDR.
    uci -q delete network.lan.netmask || true

    uci commit network

    # Даём текущему SSH-выводу успеть уйти,
    # затем перезапускаем сеть.
    (
        sleep 3
        service network restart
    ) >/dev/null 2>&1 &
}


# =========================================================
# ПОДТВЕРЖДЕНИЕ
# =========================================================

confirm() {

    echo
    echo "================ ПЛАН ================="
    echo "Wi-Fi 2.4:      $SSID24"
    echo "Wi-Fi 5:        $SSID5"
    echo "Wi-Fi пароль:   ********"
    echo "Root пароль:    ********"
    echo "Hostname:       $HOSTNAME"
    echo "Часовой пояс:   $ZONENAME"
    echo "LAN:            $TARGET_LAN_CIDR"
    echo "ZeroTier:       $ZEROTIER_NETWORK_ID"
    echo "ZT firewall:    zt+ -> ACCEPT"
    echo "WAN firewall:   не открываем"
    echo "Upgrade check:  OFF"
    echo "SSH key:        luci-key"
    echo "SSClash-Go:     устанавливается вручную"
    echo "======================================="
    echo

    printf "Продолжить? [y/N]: " >/dev/tty
    IFS= read -r answer </dev/tty

    case "$answer" in
        y|Y|yes|YES|да|Да|ДА)
            ;;
        *)
            echo "Отменено."
            exit 0
            ;;
    esac
}


# =========================================================
# START
# =========================================================

: > "$LOG"

echo "======================================"
echo "  OpenWrt Router Setup — TEST v0.3"
echo "======================================"
echo


# =========================================================
# USER INPUT
# =========================================================

ask_nonempty "Название Wi-Fi 2.4 ГГц: " SSID24

SSID5="${SSID24}-5G"
HOSTNAME="$SSID24"


while :; do

    ask_secret \
        "Пароль Wi-Fi (минимум 8 символов): " \
        WIFI_PASSWORD

    [ "${#WIFI_PASSWORD}" -ge 8 ] && break

    echo "Пароль Wi-Fi должен содержать минимум 8 символов."

done


while :; do

    ask_secret \
        "Пароль администратора root: " \
        ROOT_PASSWORD

    ask_secret \
        "Повторите пароль root:      " \
        ROOT_PASSWORD_2

    [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_2" ] || {
        echo "Пароли root не совпадают. Повторите."
        continue
    }

    [ -n "$ROOT_PASSWORD" ] || {
        echo "Пароль root не может быть пустым."
        continue
    }

    break

done


confirm


# =========================================================
# BACKUP
# =========================================================

log "Начинаю подготовку роутера..."

if command -v sysupgrade >/dev/null 2>&1; then

    log "Создаю резервную копию текущей конфигурации: $BACKUP"

    sysupgrade -b "$BACKUP" \
        || log "ПРЕДУПРЕЖДЕНИЕ: backup создать не удалось."

fi


# =========================================================
# PACKAGE INDEX
# =========================================================

pkg_update


# =========================================================
# RUSSIAN LUCI
# =========================================================

install_russian_luci


# =========================================================
# ZEROTIER
# =========================================================

log "Устанавливаю ZeroTier..."

pkg_add zerotier

configure_zerotier

configure_firewall


# =========================================================
# OTHER SETTINGS
# =========================================================

configure_attendedsysupgrade

configure_system_identity

install_ssh_key

configure_wifi

set_root_password


# =========================================================
# FINISH
# =========================================================

log "Базовая подготовка завершена."
log "Теперь вручную установи и настрой SSClash."
log "После установки и проверки SSClash запусти второй скрипт prepare-for-client.sh."


# =========================================================
# LAN IP CHANGE — ALWAYS LAST
# =========================================================

change_lan_ip_last


echo
echo "======================================"
echo "БАЗОВАЯ НАСТРОЙКА ЗАВЕРШЕНА"
echo "Новый адрес роутера: http://$TARGET_LAN_IP"
echo
echo "ZeroTier подключается к:"
echo "  $ZEROTIER_NETWORK_ID"
echo
echo "После авторизации роутера в ZeroTier Central"
echo "можно подключаться к его ZeroTier IP."
echo
echo "SSClash устанавливается вручную."
echo
echo "Если SSH сейчас оборвётся — это ожидаемо."
echo "======================================"
