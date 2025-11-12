#!/usr/bin/env bash
#
# setup-resolvconf.sh
#
# Install and configure resolvconf on Ubuntu 22.04 (Jammy)
# Primary DNS: 1.1.1.1 (Cloudflare)
# Secondary DNS: 8.8.8.8 (Google)
#
# This script:
#   - Verifies you’re running as root
#   - Backs up /etc/resolv.conf
#   - Disables/masks systemd-resolved (the default DNS stub) to avoid conflicts
#   - Installs resolvconf
#   - Configures resolvconf to publish 1.1.1.1 then 8.8.8.8
#   - Applies and verifies the configuration
#
# Safe to re-run (idempotent).
set -euo pipefail

PRIMARY_DNS="${PRIMARY_DNS:-1.1.1.1}"
SECONDARY_DNS="${SECONDARY_DNS:-8.8.8.8}"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (use sudo)." >&2
    exit 1
  fi
}


backup_resolv_conf() {
  if [[ -e /etc/resolv.conf ]]; then
    local ts="/etc/resolv.conf.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/resolv.conf "$ts"
    echo "Backed up current /etc/resolv.conf to $ts"
  fi
}

disable_systemd_resolved() {
  # If systemd-resolved is running, stop and disable it to avoid conflicts with resolvconf.
  if systemctl list-unit-files | grep -q '^systemd-resolved\.service'; then
    if systemctl is-active --quiet systemd-resolved; then
      echo "Stopping systemd-resolved..."
      systemctl stop systemd-resolved
    fi
    if systemctl is-enabled --quiet systemd-resolved; then
      echo "Disabling systemd-resolved..."
      systemctl disable systemd-resolved
    fi
    echo "Masking systemd-resolved to prevent it from being started by other services..."
    systemctl mask systemd-resolved || true
  fi

  # If /etc/resolv.conf points at systemd stub, replace it with a regular file.
  if [[ -L /etc/resolv.conf ]]; then
    local target
    target="$(readlink -f /etc/resolv.conf || true)"
    if [[ "$target" =~ /run/systemd/resolve ]]; then
      echo "Removing systemd-resolved stub symlink at /etc/resolv.conf..."
      rm -f /etc/resolv.conf
      # Create a minimal valid file; resolvconf will later manage/overwrite it.
      printf "nameserver 127.0.0.1\n" >/etc/resolv.conf
    fi
  fi
}

install_resolvconf() {
  echo "Installing resolvconf..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y resolvconf

  # Ensure the resolvconf service is enabled and started.
  systemctl enable resolvconf >/dev/null 2>&1 || true
  systemctl restart resolvconf || true
}

configure_resolvconf() {
  # resolvconf builds /etc/resolv.conf from files in /etc/resolvconf/resolv.conf.d/
  # We'll own the full list via 'base' so order is deterministic.
  mkdir -p /etc/resolvconf/resolv.conf.d

  # Clear out head/tail to avoid surprises.
  : > /etc/resolvconf/resolv.conf.d/head
  : > /etc/resolvconf/resolv.conf.d/tail

  # Set the nameservers in the base file IN ORDER.
  cat >/etc/resolvconf/resolv.conf.d/base <<EOF
nameserver ${PRIMARY_DNS}
nameserver ${SECONDARY_DNS}
options edns0
EOF

  echo "Applying resolvconf configuration..."
  resolvconf -u
}

verify_configuration() {
  echo
  echo "Current /etc/resolv.conf:"
  echo "------------------------------------------------------------"
  cat /etc/resolv.conf || true
  echo "------------------------------------------------------------"

  # Basic verification: ensure both nameservers exist and in the right order.
  local order ok1 ok2
  ok1="$(grep -nE "^nameserver[[:space:]]+${PRIMARY_DNS}$" /etc/resolv.conf | cut -d: -f1 || true)"
  ok2="$(grep -nE "^nameserver[[:space:]]+${SECONDARY_DNS}$" /etc/resolv.conf | cut -d: -f1 || true)"

  if [[ -z "$ok1" || -z "$ok2" ]]; then
    echo "ERROR: One or both DNS servers are missing from /etc/resolv.conf." >&2
    exit 1
  fi
  if (( ok1 < ok2 )); then
    echo "Verification OK: ${PRIMARY_DNS} is listed before ${SECONDARY_DNS}."
  else
    echo "ERROR: DNS order is incorrect. Expected ${PRIMARY_DNS} before ${SECONDARY_DNS}." >&2
    exit 1
  fi

  echo
  echo "Done. resolvconf is installed and managing DNS with:"
  echo "  Primary  : ${PRIMARY_DNS}"
  echo "  Secondary: ${SECONDARY_DNS}"
}

main() {
  require_root
  backup_resolv_conf
  install_resolvconf
  disable_systemd_resolved
  configure_resolvconf
  verify_configuration
}

main "$@"
