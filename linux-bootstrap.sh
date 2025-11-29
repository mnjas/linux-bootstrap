#!/usr/bin/env bash
# linux-bootstrap.sh
# Skeleton of a modular, idempotent, and logged Linux installation script.
# Content: distribution detection, logging, option parsing, modules (packages, users, hardening, ssh, firewall), and hooks.
# Usage: sudo ./linux-bootstrap.sh --help

set -euo pipefail
IFS=$'\n\t'

# -----------------------------
# Global configuration
# -----------------------------
LOGFILE="./logs/linux-bootstrap.log"
DRY_RUN=false
VERBOSE=false
FORCE=false
MODULES=()
PKG_MANAGER=""
DISTRO=""

# -----------------------------
# Helpers: logging, error exit, trap
# -----------------------------
mkdir -p "$(dirname "$LOGFILE")"

log() {
  local level="$1"; shift
  local ts
  ts=$(date --iso-8601=seconds)
  echo "[$ts] [$level] $*" | tee -a "$LOGFILE" >/dev/null
}

err() {
  log "ERROR" "$*"
  exit 1
}

info() {
  log "INFO" "$*"
  $VERBOSE && echo "$*"
}

trap 'err "Interrupted or failed. Check $LOGFILE"' ERR INT TERM

# -----------------------------
# Check root privileges
# -----------------------------
ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (or via sudo)."
  fi
}

# -----------------------------
# Detect Linux distribution
# -----------------------------
detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
    case "$ID" in
      debian|ubuntu)
        PKG_MANAGER="apt"
        ;;
      rhel|centos|fedora|rocky|almalinux)
        PKG_MANAGER="dnf"
        ;;
      arch)
        PKG_MANAGER="pacman"
        ;;
      * )
        PKG_MANAGER=""
        ;;
    esac
  else
    err "Unable to detect distribution (/etc/os-release not found)."
  fi
  info "Detected distribution: $DISTRO (package manager: $PKG_MANAGER)"
}

# -----------------------------
# Simple option parsing
# -----------------------------
usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  --help             Display this help message
  --dry-run          Simulate actions (do not change anything)
  --verbose          Verbose mode
  --force            Force some actions
  --modules=LIST     List of modules to run (comma-separated). Ex: packages,users,hardening,ssh,firewall
  --all              Run all available modules
Examples:
  sudo $0 --modules=packages,users
  sudo $0 --all --verbose
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage; exit 0
        ;;
      --dry-run)
        DRY_RUN=true; shift
        ;;
      --verbose)
        VERBOSE=true; shift
        ;;
      --force)
        FORCE=true; shift
        ;;
      --modules=*)
        IFS=',' read -r -a MODULES <<< "${1#--modules=}"; shift
        ;;
      --all)
        MODULES=(packages users hardening ssh firewall); shift
        ;;
      *)
        err "Unknown option: $1"
        ;;
    esac
  done
}

# -----------------------------
# Execution helper (dry-run)
# -----------------------------
run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: $*"
  else
    eval "$@" 2>&1 | tee -a "$LOGFILE"
  fi
}

# -----------------------------
# Module: package installation
# -----------------------------
install_packages() {
  info "==> Module: packages"
  case "$PKG_MANAGER" in
    apt)
      run_cmd "apt update -y"
      run_cmd "apt install -y curl git vim ufw"
      ;;
    dnf)
      run_cmd "dnf install -y curl git vim firewalld"
      ;;
    pacman)
      run_cmd "pacman -Sy --noconfirm curl git vim"
      ;;
    *)
      err "Unsupported package manager: $PKG_MANAGER"
      ;;
  esac
}

# -----------------------------
# Module: user management
# -----------------------------
setup_users() {
  info "==> Module: users"
  if id "deploy" &>/dev/null; then
    info "User deploy already exists"
  else
    run_cmd "useradd -m -s /bin/bash deploy"
    run_cmd "mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh"
    info "User 'deploy' created (remember to add public key in /home/deploy/.ssh/authorized_keys)"
  fi
}

# -----------------------------
# Module: basic hardening
# -----------------------------
apply_hardening() {
  info "==> Module: hardening"
  echo 'net.ipv4.ip_forward = 0' >> /etc/sysctl.d/99-custom.conf
  run_cmd "sysctl --system"
  info "Basic hardening applied (sysctl)."
}

# -----------------------------
# Module: SSH configuration
# -----------------------------
configure_ssh() {
  info "==> Module: ssh"
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
  run_cmd "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config"
  run_cmd "systemctl reload sshd || systemctl reload ssh"
  info "SSHD configured and reloaded."
}

# -----------------------------
# Module: firewall
# -----------------------------
setup_firewall() {
  info "==> Module: firewall"
  case "$PKG_MANAGER" in
    apt)
      run_cmd "ufw allow OpenSSH"
      run_cmd "ufw --force enable"
      ;;
    dnf)
      run_cmd "systemctl enable --now firewalld"
      run_cmd "firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload"
      ;;
    pacman)
      run_cmd "pacman -Sy --noconfirm ufw"
      run_cmd "ufw allow OpenSSH && ufw --force enable"
      ;;
  esac
}

# -----------------------------
# Run selected modules
# -----------------------------
run_modules() {
  local m
  for m in "${MODULES[@]}"; do
    case "$m" in
      packages) install_packages ;;
      users) setup_users ;;
      hardening) apply_hardening ;;
      ssh) configure_ssh ;;
      firewall) setup_firewall ;;
      *) info "Unknown module: $m" ;;
    esac
  done
}

# -----------------------------
# Main
# -----------------------------
main() {
  parse_args "$@"
  ensure_root
  detect_distro
  if [ ${#MODULES[@]} -eq 0 ]; then
    usage; exit 1
  fi
  run_modules
  info "Installation completed. See $LOGFILE for details."
}

main "$@"
