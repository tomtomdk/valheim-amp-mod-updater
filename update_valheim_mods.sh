#!/usr/bin/env bash
set -Eeuo pipefail

# Valheim Thunderstore mod updater for CubeCoders AMP.
# Server paths/settings live in updater.settings.json.
# Mod package selections live in mods.json.

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="${SETTINGS_FILE:-${SCRIPT_DIR}/updater.settings.json}"

json_setting() {
    local key="$1"
    local default_value="${2:-}"

    if [[ ! -f "${SETTINGS_FILE}" ]]; then
        printf '%s' "${default_value}"
        return 0
    fi

    python3 -c '
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
default = sys.argv[3]

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except FileNotFoundError:
    print(default, end="")
    raise SystemExit(0)

value = data
for part in key.split("."):
    if not isinstance(value, dict) or part not in value:
        print(default, end="")
        raise SystemExit(0)
    value = value[part]

if value is None:
    print(default, end="")
elif isinstance(value, bool):
    print("true" if value else "false", end="")
else:
    print(str(value), end="")
' "${SETTINGS_FILE}" "${key}" "${default_value}"
}

setting() {
    local env_name="$1"
    local json_key="$2"
    local default_value="${3:-}"
    local env_value="${!env_name-}"

    if [[ -n "${env_value}" ]]; then
        printf '%s' "${env_value}"
    else
        json_setting "${json_key}" "${default_value}"
    fi
}

INSTANCE_NAME="$(setting INSTANCE_NAME amp.instance_name "")"
TARGET_ROOT="$(setting TARGET_ROOT valheim.target_root "")"
UPDATER_DIR="$(setting UPDATER_DIR updater.dir "${SCRIPT_DIR}")"
CONFIG="$(setting CONFIG updater.mods_config "${UPDATER_DIR}/mods.json")"
STATE_FILE="$(setting STATE_FILE updater.state_file "${UPDATER_DIR}/state.json")"
PY="$(setting PY updater.sync_script "${UPDATER_DIR}/thunderstore_sync.py")"
AMPINST="$(setting AMPINST amp.ampinstmgr "/opt/cubecoders/amp/ampinstmgr")"
AMP_USER="$(setting AMP_USER amp.user "amp")"
BACKUP_DIR="$(setting BACKUP_DIR backups.dir "${UPDATER_DIR}/backups/config-only")"
MAX_BACKUPS="$(setting MAX_BACKUPS backups.max_count "5")"
WAIT_SECONDS="${WAIT_SECONDS_OVERRIDE:-$(setting WAIT_SECONDS restart.wait_seconds "900")}"
STOP_TIMEOUT="$(setting STOP_TIMEOUT restart.stop_timeout_seconds "120")"
START_TIMEOUT="$(setting START_TIMEOUT restart.start_timeout_seconds "180")"
LOCK_FILE="$(setting LOCK_FILE updater.lock_file "/run/lock/valheim-modupdater.lock")"
RCON_ENABLED="$(setting RCON_ENABLED rcon.enabled "false")"
RCON_HOST="$(setting RCON_HOST rcon.host "127.0.0.1")"
RCON_PORT="$(setting RCON_PORT rcon.port "2458")"
RCON_PASSWORD_FILE="$(setting RCON_PASSWORD_FILE rcon.password_file "${UPDATER_DIR}/rcon_password")"
RCON_WARN_SECONDS="$(setting RCON_WARN_SECONDS rcon.warning_seconds "900 600 300 60 30 10")"
read -r -a RCON_WARNING_MARKS <<<"${RCON_WARN_SECONDS}"

BEPINEX_DIR="${TARGET_ROOT}/BepInEx"
CONFIG_DIR="${BEPINEX_DIR}/config"

if [[ ${EUID} -ne 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
        exec sudo env SETTINGS_FILE="${SETTINGS_FILE}" WAIT_SECONDS_OVERRIDE="${WAIT_SECONDS}" "$0" "$@"
    fi

    echo "[ERROR] This script needs root privileges for AMP administration." >&2
    echo "[ERROR] Run with sudo, or run it as root from cron/systemd." >&2
    exit 1
fi

require_value() {
    local name="$1"
    local value="$2"

    if [[ -z "${value}" ]]; then
        echo "[ERROR] Missing required setting: ${name}" >&2
        echo "[ERROR] Copy updater.settings.example.json to updater.settings.json and fill it in." >&2
        exit 2
    fi
}

as_amp() {
    sudo -u "${AMP_USER}" -H -- "$@"
}

human_time() {
    local seconds="$1"

    if (( seconds <= 0 )); then
        printf 'immediately'
    elif (( seconds < 60 )); then
        printf '%s seconds' "${seconds}"
    elif (( seconds % 60 == 0 )); then
        printf '%s minutes' "$((seconds / 60))"
    else
        printf '%sm %ss' "$((seconds / 60))" "$((seconds % 60))"
    fi
}

rcon_is_enabled() {
    case "${RCON_ENABLED,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

rcon_command() {
    local command="$1"
    local output

    if ! rcon_is_enabled; then
        return 0
    fi

    if [[ ! -r "${RCON_PASSWORD_FILE}" ]]; then
        echo "[WARN] RCON password file is not readable; skipping in-game notice."
        return 0
    fi

    set +e
    output="$(
        python3 - "${RCON_HOST}" "${RCON_PORT}" "${RCON_PASSWORD_FILE}" "${command}" <<'PY' 2>&1
import socket
import struct
import sys


def packet(request_id, packet_type, payload):
    body = payload.encode("ascii", errors="replace") + b"\x00\x00"
    return struct.pack("<iii", len(body) + 8, request_id, packet_type) + body


def receive(sock):
    header = sock.recv(4)
    if len(header) != 4:
        raise RuntimeError("No RCON response header")
    size = struct.unpack("<i", header)[0]
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            break
        data += chunk
    if len(data) < 8:
        raise RuntimeError("Short RCON response")
    request_id, packet_type = struct.unpack("<ii", data[:8])
    payload = data[8:].rstrip(b"\x00").decode("ascii", errors="replace")
    return request_id, packet_type, payload


host = sys.argv[1]
port = int(sys.argv[2])
password_file = sys.argv[3]
command = sys.argv[4]

with open(password_file, "r", encoding="utf-8") as handle:
    password = handle.read().strip()

with socket.create_connection((host, port), timeout=8) as sock:
    sock.settimeout(8)
    sock.sendall(packet(1, 3, password))
    login_id, _, _ = receive(sock)
    if login_id == -1:
        raise SystemExit("RCON login failed")
    sock.sendall(packet(2, 2, command))
    _, packet_type, response = receive(sock)
    if packet_type == -1:
        raise SystemExit(response or "RCON command failed")
PY
    )"
    local rc=$?
    set -e

    if (( rc != 0 )); then
        echo "[WARN] RCON command failed; continuing without blocking updater."
        if [[ -n "${output}" ]]; then
            echo "[WARN] ${output}"
        fi
    fi
}

send_restart_warning() {
    local seconds="$1"
    local remaining
    local message

    remaining="$(human_time "${seconds}")"
    message="Server restart for mod updates in ${remaining}. Please get to a safe place."

    echo "[INFO] Sending in-game restart warning: ${remaining}"
    rcon_command "broadcast center <color=orange><size=20>${message}</size></color>"
    rcon_command "broadcast side ${message}"
}

wait_with_restart_warnings() {
    local total="$1"
    local remaining="${total}"
    local mark
    local sleep_for

    for mark in "${RCON_WARNING_MARKS[@]}"; do
        if ! [[ "${mark}" =~ ^[0-9]+$ ]]; then
            echo "[WARN] Ignoring invalid RCON warning mark: ${mark}"
            continue
        fi

        if (( mark > total )); then
            continue
        fi

        sleep_for=$((remaining - mark))
        if (( sleep_for > 0 )); then
            sleep "${sleep_for}"
        fi

        remaining="${mark}"
        send_restart_warning "${mark}"
    done

    if (( remaining > 0 )); then
        sleep "${remaining}"
    fi
}

notify_pre_stop() {
    echo "[INFO] Sending final in-game save/restart notice."
    rcon_command "broadcast center <color=orange><size=20>Saving world now. Restart incoming.</size></color>"
    rcon_command "broadcast side Saving world now. Restart incoming."
    rcon_command "save"
    sleep 3
}

is_up() {
    local output
    output="$(as_amp "${AMPINST}" status "${INSTANCE_NAME}" 2>/dev/null || true)"

    if ! grep -Fq "${INSTANCE_NAME}" <<<"${output}"; then
        return 2
    fi

    if grep -F "${INSTANCE_NAME}" <<<"${output}" | grep -Fq "✓"; then
        return 0
    fi

    if grep -F "${INSTANCE_NAME}" <<<"${output}" | grep -Eiq '\b(running|online|started)\b'; then
        return 0
    fi

    return 1
}

wait_for_down() {
    local elapsed=0

    while (( elapsed < STOP_TIMEOUT )); do
        if ! is_up; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

wait_for_up() {
    local elapsed=0

    while (( elapsed < START_TIMEOUT )); do
        if is_up; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

ensure_permissions() {
    install -d -o "${AMP_USER}" -g "${AMP_USER}" -m 0775 "${UPDATER_DIR}"
    install -d -o "${AMP_USER}" -g "${AMP_USER}" -m 0775 "${BACKUP_DIR}"

    if [[ -e "${STATE_FILE}" ]]; then
        chown "${AMP_USER}:${AMP_USER}" "${STATE_FILE}"
        chmod 0664 "${STATE_FILE}"
    fi
}

prune_backups() {
    local keep="${1:-${MAX_BACKUPS}}"
    local -a backups=()
    local count i

    mapfile -t backups < <(
        find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'bepinex-config-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        cut -d' ' -f2-
    )

    count=${#backups[@]}
    if (( count <= keep )); then
        return 0
    fi

    for ((i = keep; i < count; i++)); do
        echo "[INFO] Removing old config backup: ${backups[$i]}"
        rm -f -- "${backups[$i]}"
    done
}

make_config_backup() {
    local ts backup_file

    if ! as_amp test -d "${CONFIG_DIR}"; then
        echo "[WARN] BepInEx config directory not found. Backup skipped."
        return 0
    fi

    if (( MAX_BACKUPS > 1 )); then
        prune_backups "$((MAX_BACKUPS - 1))"
    else
        prune_backups 0
    fi

    ts="$(date +%Y%m%d-%H%M%S)"
    backup_file="${BACKUP_DIR}/bepinex-config-${ts}.tar.gz"

    echo "[INFO] Backing up BepInEx/config to ${backup_file}"
    as_amp tar -czf "${backup_file}" -C "${BEPINEX_DIR}" config
    echo "[INFO] Backup size: $(du -h "${backup_file}" | awk '{print $1}')"

    prune_backups "${MAX_BACKUPS}"
}

start_instance() {
    echo "[INFO] Starting AMP instance: ${INSTANCE_NAME}"
    as_amp "${AMPINST}" start "${INSTANCE_NAME}"

    if ! wait_for_up; then
        echo "[ERROR] Instance did not start within ${START_TIMEOUT} seconds." >&2
        return 1
    fi

    echo "[OK] AMP instance is running."
}

require_value INSTANCE_NAME "${INSTANCE_NAME}"
require_value TARGET_ROOT "${TARGET_ROOT}"

if ! [[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] restart.wait_seconds/WAIT_SECONDS must be a non-negative integer." >&2
    exit 2
fi

if ! [[ "${MAX_BACKUPS}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] backups.max_count/MAX_BACKUPS must be a non-negative integer." >&2
    exit 2
fi

if [[ ! -x "${AMPINST}" ]]; then
    echo "[ERROR] AMP Instance Manager not found: ${AMPINST}" >&2
    exit 2
fi

if [[ ! -f "${CONFIG}" ]]; then
    echo "[ERROR] Missing mod config: ${CONFIG}" >&2
    exit 2
fi

if [[ ! -f "${PY}" ]]; then
    echo "[ERROR] Missing updater: ${PY}" >&2
    exit 2
fi

if ! as_amp test -d "${TARGET_ROOT}"; then
    echo "[ERROR] Valheim target directory is missing or inaccessible to ${AMP_USER}: ${TARGET_ROOT}" >&2
    exit 2
fi

if ! as_amp test -d "${BEPINEX_DIR}"; then
    echo "[ERROR] BepInEx directory does not exist: ${BEPINEX_DIR}" >&2
    exit 2
fi

ensure_permissions
mkdir -p "$(dirname "${LOCK_FILE}")"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "[INFO] Another Valheim mod updater is already running."
    exit 0
fi

WAS_RUNNING=0
SERVER_STOPPED_BY_US=0

cleanup_on_exit() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 && WAS_RUNNING == 1 && SERVER_STOPPED_BY_US == 1 )); then
        echo "[WARN] Updater failed after stopping Valheim. Attempting restart..."
        as_amp "${AMPINST}" start "${INSTANCE_NAME}" || true
    fi

    exit "${rc}"
}

trap cleanup_on_exit EXIT

echo
echo "============================================================"
echo " Valheim Thunderstore Mod Updater"
echo "============================================================"
echo "[INFO] Instance: ${INSTANCE_NAME}"
echo "[INFO] Target:   ${TARGET_ROOT}"
echo "[INFO] Settings: ${SETTINGS_FILE}"
echo "[INFO] Config:   ${CONFIG}"
echo "[INFO] Backups:  ${BACKUP_DIR}"
echo

if is_up; then
    WAS_RUNNING=1
    echo "[INFO] AMP instance is currently running."
else
    WAS_RUNNING=0
    echo "[WARN] AMP instance is currently not running."
fi

echo "[INFO] Checking Thunderstore for mod updates..."
restart_unix=$(( $(date +%s) + WAIT_SECONDS ))

set +e
as_amp "${PY}" --config "${CONFIG}" --target "${TARGET_ROOT}" --state "${STATE_FILE}" --check --notify-scheduled "${restart_unix}"
rc=$?
set -e

if [[ ${rc} -eq 0 ]]; then
    echo "[OK] No mod updates available. Nothing needs to be restarted."
    exit 0
fi

if [[ ${rc} -ne 10 ]]; then
    echo "[ERROR] Update check failed with exit code ${rc}. Valheim was not touched." >&2
    exit "${rc}"
fi

echo "[INFO] Mod updates are available."

if (( WAS_RUNNING == 1 && WAIT_SECONDS > 0 )); then
    echo "[INFO] Waiting $(human_time "${WAIT_SECONDS}") before restart."
    echo "[INFO] Restart time: $(date -d "@${restart_unix}")"
    wait_with_restart_warnings "${WAIT_SECONDS}"
elif (( WAS_RUNNING == 1 )); then
    echo "[INFO] Restart delay disabled."
else
    echo "[INFO] Server is already stopped. No restart delay is required."
fi

echo "[INFO] Re-checking updates before making changes..."
set +e
as_amp "${PY}" --config "${CONFIG}" --target "${TARGET_ROOT}" --state "${STATE_FILE}" --check
rc=$?
set -e

if [[ ${rc} -eq 0 ]]; then
    echo "[OK] Updates are no longer required. Restart cancelled."
    exit 0
fi

if [[ ${rc} -ne 10 ]]; then
    echo "[ERROR] Second update check failed with exit code ${rc}. Valheim was not stopped." >&2
    exit "${rc}"
fi

if (( WAS_RUNNING == 1 )); then
    echo "[INFO] Stopping AMP instance: ${INSTANCE_NAME}"
    notify_pre_stop
    as_amp "${AMPINST}" stop "${INSTANCE_NAME}"

    if ! wait_for_down; then
        echo "[ERROR] Instance did not stop within ${STOP_TIMEOUT} seconds." >&2
        exit 3
    fi

    SERVER_STOPPED_BY_US=1
    echo "[OK] AMP instance stopped."
fi

make_config_backup

echo "[INFO] Applying Thunderstore updates..."
as_amp "${PY}" --config "${CONFIG}" --target "${TARGET_ROOT}" --state "${STATE_FILE}" --notify
echo "[OK] Mod updates applied."

if (( WAS_RUNNING == 1 )); then
    start_instance
    SERVER_STOPPED_BY_US=0
else
    echo "[INFO] Instance was stopped before the updater ran. Leaving it stopped."
fi

echo
echo "============================================================"
echo "[OK] Valheim mod update completed successfully."
echo "============================================================"
