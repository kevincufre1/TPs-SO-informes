#!/usr/bin/env bash
#
# system-inventory.sh — Inventario del sistema (TP1, NEXUS-9)
# system-inventory.sh
# NEXUS-9 - Script de inventario del sistema
#
# Implementación a cargo de cada grupo. El contrato que verifica CI está en
# docs/contrato-system-inventory.md.
# Agnóstico de distribución: funciona tanto en Ubuntu Server (Debian-based)
# como en Rocky Linux (RHEL-based), sin valores codificados para una
# distribución específica.

set -euo pipefail

# ── Códigos de salida ────────────────────────────────────────────────────
readonly EXIT_OK=0
readonly EXIT_ARGS=1

# ── Utilidades ────────────────────────────────────────────────────────────

log_section() {
    printf '\n=== %s ===\n' "$1"
}

# Verifica si un comando existe en el sistema
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

usage() {
    cat <<EOF
Uso: $(basename "$0") [-h]

Genera un inventario del sistema local: sistema operativo, CPU, memoria,
almacenamiento, red y servicios systemd.

Opciones:
  -h    Muestra esta ayuda y termina.
EOF
}

# ── Parseo de argumentos ────────────────────────────────────────────────
while getopts ":h" opt; do
    case "$opt" in
        h)
            usage
            exit "$EXIT_OK"
            ;;
        \?)
            printf 'Opción inválida: -%s\n' "$OPTARG" >&2
            usage >&2
            exit "$EXIT_ARGS"
            ;;
    esac
done

# ── Sistema operativo ─────────────────────────────────────────────────────
section_os() {
    log_section "Sistema operativo"

    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        printf 'Distribución : %s\n' "${PRETTY_NAME:-desconocida}"
        printf 'Versión      : %s\n' "${VERSION_ID:-desconocida}"
    else
        printf '[ERROR] No se pudo leer /etc/os-release\n' >&2
    fi

    printf 'Kernel       : %s\n' "$(uname -r)"
    printf 'Arquitectura : %s\n' "$(uname -m)"
}

# ── CPU ────────────────────────────────────────────────────────────────────
section_cpu() {
    log_section "CPU"

    if command_exists lscpu; then
        local modelo frecuencia cpus_logicas nucleos

        modelo=$(lscpu | grep -i '^Model name:' | sed 's/^Model name:\s*//')
        frecuencia=$(lscpu | grep -i '^CPU MHz:' | sed 's/^CPU MHz:\s*//')
        cpus_logicas=$(lscpu | grep -i '^CPU(s):' | head -1 | sed 's/^CPU(s):\s*//')
        nucleos=$(lscpu | grep -i '^Core(s) per socket:' | sed 's/^Core(s) per socket:\s*//')

        printf 'Modelo           : %s\n' "${modelo:-desconocido}"
        printf 'Frecuencia (MHz) : %s\n' "${frecuencia:-no disponible}"
        printf 'CPUs lógicas     : %s\n' "${cpus_logicas:-desconocido}"
        printf 'Cores por socket : %s\n' "${nucleos:-desconocido}"

        printf '\nCaché:\n'
        lscpu | grep -i 'cache' || printf '  No se encontró información de caché\n'
    else
        printf '[ERROR] lscpu no está disponible en este sistema\n' >&2
        return 1
    fi
}

# ── Memoria ────────────────────────────────────────────────────────────────
section_memory() {
    log_section "Memoria"

    if command_exists free; then
        free -h
    else
        printf '[ERROR] free no está disponible en este sistema\n' >&2
        return 1
    fi
}

# ── Almacenamiento ───────────────────────────────────────────────────────
section_storage() {
    log_section "Almacenamiento"

    printf -- '--- Dispositivos de bloque ---\n'
    if command_exists lsblk; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT || \
            printf '[ERROR] Falló la consulta de dispositivos con lsblk\n' >&2
    else
        printf '[ERROR] lsblk no está disponible en este sistema\n' >&2
    fi

    printf '\n--- Filesystems montados y uso ---\n'
    if command_exists df; then
        df -hT --exclude-type=tmpfs --exclude-type=devtmpfs || \
            printf '[ERROR] Falló la consulta de espacio con df\n' >&2
    else
        printf '[ERROR] df no está disponible en este sistema\n' >&2
    fi

    printf '\n--- Punto de montaje /mnt ---\n'
    if mountpoint -q /mnt 2>/dev/null; then
        printf '/mnt tiene un filesystem montado:\n'
        df -h /mnt
    else
        printf '/mnt no tiene ningún filesystem montado actualmente.\n'
    fi
}

# ── Red ────────────────────────────────────────────────────────────────────
# El comando 'ip' es información esencial de esta sección: si no está
# disponible, la sección se considera fallida (código de salida distinto
# de 0), no solo un aviso por stderr.
section_network() {
    log_section "Red"

    if ! command_exists ip; then
        printf '[ERROR] El comando ip no está disponible: no se puede obtener información de red\n' >&2
        return 1
    fi

    local rc=0

    printf -- '--- Interfaces y estado ---\n'
    ip -brief addr show || {
        printf '[ERROR] Falló la consulta de interfaces con ip addr\n' >&2
        rc=1
    }

    printf '\n--- Tabla de vecinos (ARP / NDP) ---\n'
    ip neigh show || printf 'No hay entradas en la tabla de vecinos actualmente.\n'

    return "$rc"
}

# ── Servicios (systemd) ──────────────────────────────────────────────────
# Consulta el estado de una lista de servicios de interés y distingue
# activo / inactivo / inexistente / error de consulta. Es best-effort:
# si systemd no está disponible (p. ej. dentro de un contenedor), se
# informa pero no cambia el código de salida general del script.
section_services() {
    log_section "Servicios (systemd)"

    if ! command_exists systemctl; then
        printf '[AVISO] systemctl no está disponible en este sistema (¿contenedor sin systemd?)\n' >&2
        return 0
    fi

    local services=("sshd" "ssh" "NetworkManager" "networking" "firewalld" "ufw")
    local svc status

    for svc in "${services[@]}"; do
        if ! systemctl list-unit-files "${svc}.service" \
                --no-legend 2>/dev/null | grep -q "${svc}.service"; then
            printf '%-15s : no existe en este sistema\n' "$svc"
            continue
        fi

        status=$(systemctl is-active "${svc}.service" 2>/dev/null || true)
        if [[ -z "$status" ]]; then
            printf '[ERROR] %-15s : no se pudo consultar el estado\n' "$svc" >&2
        else
            printf '%-15s : %s\n' "$svc" "$status"
        fi
    done
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    local exit_code="$EXIT_OK"

    printf 'NEXUS-9 :: Inventario del sistema\n'
    printf 'Generado el: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Host: %s\n' "$(hostname)"

    section_os          || exit_code=1
    section_cpu          || exit_code=1
    section_memory        || exit_code=1
    section_storage        || exit_code=1
    section_network        || exit_code=1
    section_services        || true

    printf '\n=== Fin del inventario ===\n'

    exit "$exit_code"
}

main "$@"