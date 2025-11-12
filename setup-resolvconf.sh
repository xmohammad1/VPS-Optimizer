#!/usr/bin/env bash
# setup-resolvconf.sh
#
# Install and configure resolvconf on Ubuntu 22.04 (Jammy),
# setting DNS to 1.1.1.1 (primary) and 8.8.8.8 (secondary).
#
# Modes:
#   (default)  Install/configure resolvconf and apply DNS
#   --status   Show current DNS/resolv.conf ownership
#   --revert   Re-enable systemd-resolved and remove resolvconf
#
# Safe to re-run (idempotent).

set -Eeuo pipefail

DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
NM_DROPIN="/etc/NetworkManager/conf.d/90-dns-default.conf"
HEAD_DIR="/etc/resolvconf/resolv.conf.d"
HEAD_FILE="${HEAD_DIR}/head"
BACKUP_DIR="/root/resolvconf-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
      die "This script targets Ubuntu 22.04 (Jammy). Detected: ${PRETTY_NAME:-unknown}"
    fi
  else
    die "Cannot detect OS (/etc/os-release missing)."
  fi
}

wsl_notice() {
  if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
    warn "WSL detected. Windows often auto-generates /etc/resolv.conf."
    warn "If DNS doesn't stick, set in /etc/wsl.conf: [network] generateResolvConf=false, then recreate /etc/resolv.conf."
  fi
}

backup_file() {
  local f="$1"
  [[ -e "$f" || -L "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$f" "${BACKUP_DIR}/$(basename "$f").${TIMESTAMP}.bak" || true
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Refreshing APT metadata…"
  apt-get update -y
  log "Installing resolvconf…"
  apt-get install -y resolvconf
}

disable_systemd_resolved() {
  if systemctl is-enabled systemd-resolved >/dev/null 2>&1 || systemctl is-active systemd-resolved >/dev/null 2>&1; then
    log "Disabling and stopping systemd-resolved…"
    systemctl disable --now systemd-resolved
  else
    log "systemd-resolved already disabled."
  fi
}

configure_networkmanager_for_resolvconf() {
  if systemctl list-unit-files | grep -q '^NetworkManager.service'; then
    log "Configuring NetworkManager to use resolvconf (dns=default)…"
    mkdir -p "$(dirname "$NM_DROPIN")"
    cat > "$NM_DROPIN" <<'EOF'
[main]
# Use resolvconf to manage /etc/resolv.conf (not systemd-resolved)
dns=default
EOF
    log "Restarting NetworkManager…"
    systemctl restart NetworkManager || warn "NetworkManager restart returned non-zero; continue."
  else
    log "NetworkManager not installed; skipping NM configuration."
  fi
}

point_etc_resolv_conf_to_resolvconf() {
  # resolvconf uses /run/resolvconf/resolv.conf
  local target="/run/resolvconf/resolv.conf"
  if [[ ! -e "$target" ]]; then
    # Ensure directory exists; resolvconf will populate after -u
    mkdir -p /run/resolvconf
    : > "$target"
  fi

  if [[ -L /etc/resolv.conf || -f /etc/resolv.conf ]]; then
    if [[ "$(readlink -f /etc/resolv.conf || true)" != "$target" ]]; then
      log "Repointing /etc/resolv.conf -> $target"
      backup_file /etc/resolv.conf
      rm -f /etc/resolv.conf
      ln -s "$target" /etc/resolv.conf
    else
      log "/etc/resolv.conf already points to $target"
    fi
  else
    log "Creating /etc/resolv.conf symlink to $target"
    ln -s "$target" /etc/resolv.conf
  fi
}

write_resolvconf_head() {
  log "Writing static DNS to ${HEAD_FILE} (will be placed at top of /etc/resolv.conf)…"
  mkdir -p "$HEAD_DIR"
  cat > "$HEAD_FILE" <<EOF
# Added by setup-resolvconf.sh on ${TIMESTAMP}
# Primary and secondary DNS:
nameserver ${DNS1}
nameserver ${DNS2}
EOF
}

apply_resolvconf() {
  log "Regenerating /etc/resolv.conf via resolvconf…"
  resolvconf -u
}

show_status() {
  echo
  echo "=== DNS Status ==="
  echo "Wanted DNS (top of /etc/resolv.conf): ${DNS1}, ${DNS2}"
  echo
  ls -l /etc/resolv.conf || true
  echo
  echo "First few lines of /etc/resolv.conf:"
  head -n 10 /etc/resolv.conf || true
  echo
  echo "Contents of ${HEAD_FILE}:"
  sed -n '1,50p' "${HEAD_FILE}" 2>/dev/null || echo "(no head file)"
  echo
}

revert_to_systemd_resolved() {
  log "Reverting: re-enabling systemd-resolved and removing resolvconf…"
  # Restore systemd-resolved first (so DNS works during removal)
  systemctl enable --now systemd-resolved

  # Re-point /etc/resolv.conf to systemd's stub file
  backup_file /etc/resolv.conf
  rm -f /etc/resolv.conf
  if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  else
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi

  # Remove resolvconf package
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y resolvconf || warn "Could not purge resolvconf (maybe not installed)."

  # Clean up NM override if present
  if [[ -f "$NM_DROPIN" ]]; then
    rm -f "$NM_DROPIN"
    systemctl restart NetworkManager || true
  fi

  log "Revert complete."
}

main() {
  require_root

  # Parse args
  case "${1:-}" in
    --status)
      show_status
      exit 0
      ;;
    --revert)
      revert_to_systemd_resolved
      exit 0
      ;;
    "" )
      ;;
    *)
      die "Unknown option: $1 (use --status or --revert or no args)"
      ;;
  esac

  wsl_notice
  ensure_packages
  disable_systemd_resolved
  configure_networkmanager_for_resolvconf
  point_etc_resolv_conf_to_resolvconf
  write_resolvconf_head
  apply_resolvconf
  show_status

  log "Done. DNS is now managed by resolvconf with ${DNS1} (primary) and ${DNS2} (secondary)."
}

main "$@"
