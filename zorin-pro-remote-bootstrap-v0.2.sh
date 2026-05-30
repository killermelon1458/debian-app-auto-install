#!/usr/bin/env bash
# zorin-pro-remote-bootstrap.sh
# Zorin OS 18.1 Pro/Core post-install bootstrap for remote support.
#
# Installs:
#   - OpenSSH server
#   - Tailscale
#   - NoMachine from a .deb placed next to this script
#   - Google Chrome
#   - Steam launcher + controller udev support
#   - micro editor
#   - troubleshooting + Bluetooth/controller helper tools
#
# Design:
#   - Fault tolerant: one failed install should not stop the rest.
#   - Logs to ~/zorin-bootstrap-YYYYmmdd-HHMMSS.log
#   - Tailscale login is attempted last.

set -u
set -o pipefail

VERSION="0.2"

INSTALL_NOMACHINE=true
INSTALL_CHROME=true
INSTALL_STEAM=true
INSTALL_MICRO=true
INSTALL_EXTRAS=true
INSTALL_CONTROLLER_TOOLS=true

# Runs "sudo tailscale up" as the final step.
# This is intentionally last because it may pause for browser/login authentication.
RUN_TAILSCALE_UP_AT_END=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$HOME/zorin-bootstrap-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

OK_ITEMS=()
WARN_ITEMS=()
FAIL_ITEMS=()

section() {
    echo
    echo "================================================================"
    echo "$*"
    echo "================================================================"
}

ok() {
    OK_ITEMS+=("$*")
    echo "[OK] $*"
}

warn() {
    WARN_ITEMS+=("$*")
    echo "[WARN] $*"
}

fail() {
    FAIL_ITEMS+=("$*")
    echo "[FAIL] $*"
}

run_cmd() {
    local label="$1"
    shift

    echo
    echo "--- $label"
    echo "+ $*"

    "$@"
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        ok "$label"
    else
        fail "$label (exit code $rc)"
    fi

    # Never stop the full script because one step failed.
    return 0
}

run_bash() {
    local label="$1"
    local command_string="$2"

    echo
    echo "--- $label"
    echo "+ $command_string"

    bash -c "$command_string"
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        ok "$label"
    else
        fail "$label (exit code $rc)"
    fi

    return 0
}

need_sudo() {
    section "Checking sudo access"
    if sudo -v; then
        ok "sudo access confirmed"
    else
        echo "This script needs sudo/admin permission."
        echo "Run it from the installed Zorin admin user account."
        exit 1
    fi

    # Keep sudo alive while the script runs.
    while true; do
        sudo -n true 2>/dev/null || true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done &
    SUDO_KEEPALIVE_PID="$!"
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

apt_update() {
    section "Updating package lists"

    for attempt in 1 2 3; do
        echo "apt update attempt $attempt/3"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3
        local rc=$?

        if [ "$rc" -eq 0 ]; then
            ok "apt package lists updated"
            return 0
        fi

        echo "apt update failed with exit code $rc"
        sleep 5
    done

    fail "apt package lists could not be updated"
    return 1
}

apt_fix() {
    section "Repairing any interrupted package operations"

    run_cmd "dpkg configure pending packages" \
        sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a

    run_cmd "apt fix broken dependencies" \
        sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold
}

apt_install_one() {
    local pkg="$1"

    echo
    echo "--- Installing package: $pkg"

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$pkg"

    local rc=$?

    if [ "$rc" -eq 0 ]; then
        ok "package installed: $pkg"
    else
        fail "package failed: $pkg (exit code $rc)"
    fi

    return 0
}

apt_install_list() {
    local group="$1"
    shift

    section "Installing package group: $group"

    local pkg
    for pkg in "$@"; do
        apt_install_one "$pkg"
    done
}

install_local_deb() {
    local label="$1"
    local deb="$2"

    section "Installing local .deb: $label"
    echo "File: $deb"

    if [ ! -f "$deb" ]; then
        fail "$label .deb not found: $deb"
        return 0
    fi

    # apt can install local .debs, but dpkg + apt -f is predictable for recovery
    # if dependencies are missing.
    sudo DEBIAN_FRONTEND=noninteractive dpkg -i "$deb"
    local dpkg_rc=$?

    if [ "$dpkg_rc" -ne 0 ]; then
        warn "$label dpkg step returned $dpkg_rc; trying dependency repair"
    fi

    sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y \
        -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold

    local fix_rc=$?

    if [ "$fix_rc" -eq 0 ]; then
        ok "$label local .deb install/repair completed"
    else
        fail "$label local .deb install/repair failed (exit code $fix_rc)"
    fi

    return 0
}

system_report() {
    section "System report"

    echo "Bootstrap version: $VERSION"
    echo "Date: $(date)"
    echo "User: $(whoami)"
    echo "Script dir: $SCRIPT_DIR"
    echo "Log file: $LOGFILE"
    echo

    hostnamectl 2>/dev/null || true
    echo
    echo "Architecture: $(uname -m)"
    echo "Kernel: $(uname -r)"

    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -a 2>/dev/null || true
    fi
}

install_base_tools() {
    apt_install_list "base tools" \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common
}

install_ssh() {
    section "OpenSSH server"

    apt_install_one openssh-server

    run_cmd "enable and start ssh service" \
        sudo systemctl enable --now ssh

    if command -v ufw >/dev/null 2>&1; then
        if sudo ufw status | grep -q "Status: active"; then
            run_cmd "allow OpenSSH through active UFW firewall" \
                sudo ufw allow OpenSSH
        else
            warn "UFW is installed but inactive; firewall not changed"
        fi
    else
        warn "UFW is not installed; firewall not changed"
    fi

    run_cmd "show ssh service status" \
        systemctl --no-pager --full status ssh
}

install_tailscale() {
    section "Tailscale"

    if command -v tailscale >/dev/null 2>&1; then
        ok "Tailscale already installed"
        tailscale version || true
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        apt_install_one curl
    fi

    echo "Downloading Tailscale installer..."
    curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh
    local curl_rc=$?

    if [ "$curl_rc" -ne 0 ]; then
        fail "download Tailscale installer (exit code $curl_rc)"
        return 0
    fi

    ok "download Tailscale installer"

    sudo sh /tmp/tailscale-install.sh
    local install_rc=$?

    if [ "$install_rc" -eq 0 ]; then
        ok "Tailscale installed"
    else
        fail "Tailscale install failed (exit code $install_rc)"
    fi

    return 0
}

install_nomachine() {
    section "NoMachine"

    if [ "$INSTALL_NOMACHINE" != true ]; then
        warn "NoMachine install disabled by config"
        return 0
    fi

    if [ -x /usr/NX/bin/nxserver ]; then
        ok "NoMachine already installed"
        sudo /usr/NX/bin/nxserver --status || true
        return 0
    fi

    shopt -s nullglob nocaseglob
    local debs=("$SCRIPT_DIR"/nomachine*.deb)
    shopt -u nullglob nocaseglob

    if [ "${#debs[@]}" -eq 0 ]; then
        warn "NoMachine .deb not found next to script; skipping NoMachine"
        echo "Expected a file like:"
        echo "  nomachine_*.deb"
        echo "Place the official amd64 NoMachine .deb beside this script on the USB."
        return 0
    fi

    install_local_deb "NoMachine" "${debs[0]}"

    if [ -x /usr/NX/bin/nxserver ]; then
        ok "NoMachine nxserver found"
        sudo /usr/NX/bin/nxserver --status || true
    else
        fail "NoMachine nxserver not found after install"
    fi
}

install_chrome() {
    section "Google Chrome"

    if [ "$INSTALL_CHROME" != true ]; then
        warn "Chrome install disabled by config"
        return 0
    fi

    if command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
        ok "Google Chrome already installed"
        google-chrome --version 2>/dev/null || google-chrome-stable --version 2>/dev/null || true
        return 0
    fi

    local chrome_deb="/tmp/google-chrome-stable_current_amd64.deb"

    run_cmd "download Google Chrome .deb" \
        wget -O "$chrome_deb" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

    install_local_deb "Google Chrome" "$chrome_deb"
}

install_steam() {
    section "Steam"

    if [ "$INSTALL_STEAM" != true ]; then
        warn "Steam install disabled by config"
        return 0
    fi

    if command -v steam >/dev/null 2>&1; then
        ok "Steam already installed"
        return 0
    fi

    if dpkg --print-foreign-architectures | grep -qx "i386"; then
        ok "i386 architecture already enabled"
    else
        run_cmd "enable i386 architecture for Steam dependencies" \
            sudo dpkg --add-architecture i386
        apt_update
    fi

    local steam_deb="/tmp/steam_latest.deb"

    run_cmd "download Steam launcher .deb" \
        wget -O "$steam_deb" "https://repo.steampowered.com/steam/archive/precise/steam_latest.deb"

    install_local_deb "Steam launcher" "$steam_deb"

    # Valve's steam_latest.deb includes steam-devices, but try this too if available.
    apt_install_one steam-devices

    run_cmd "reload udev rules for game controllers" \
        sudo udevadm control --reload-rules

    run_cmd "trigger udev rules" \
        sudo udevadm trigger

    warn "Steam's first launch still needs user login and client self-update"
}

install_micro() {
    section "micro editor"

    if [ "$INSTALL_MICRO" != true ]; then
        warn "micro install disabled by config"
        return 0
    fi

    if command -v micro >/dev/null 2>&1; then
        ok "micro already installed"
        micro -version || true
        return 0
    fi

    apt_install_one micro
}

install_extras() {
    if [ "$INSTALL_EXTRAS" = true ]; then
        apt_install_list "troubleshooting tools" \
            htop \
            inxi \
            pciutils \
            usbutils \
            pavucontrol \
            flatpak
    else
        warn "extras install disabled by config"
    fi

    if [ "$INSTALL_CONTROLLER_TOOLS" = true ]; then
        apt_install_list "Bluetooth and controller tools" \
            bluetooth \
            bluez \
            blueman \
            joystick \
            jstest-gtk \
            game-devices-udev
    else
        warn "controller tools install disabled by config"
    fi
}

final_status() {
    section "Final status"

    echo "Hostname:"
    hostname || true

    echo
    echo "Local IP addresses:"
    hostname -I || true

    echo
    echo "SSH status:"
    systemctl is-active ssh 2>/dev/null || true

    echo
    echo "Tailscale status:"
    if command -v tailscale >/dev/null 2>&1; then
        tailscale status || true
        echo
        echo "Tailscale IPv4:"
        tailscale ip -4 2>/dev/null || true
    else
        echo "tailscale command not found"
    fi

    echo
    echo "NoMachine status:"
    if [ -x /usr/NX/bin/nxserver ]; then
        sudo /usr/NX/bin/nxserver --status || true
    else
        echo "NoMachine not installed or nxserver not found"
    fi

    echo
    echo "Installed versions:"
    command -v ssh >/dev/null 2>&1 && ssh -V 2>&1 || true
    command -v tailscale >/dev/null 2>&1 && tailscale version || true
    command -v google-chrome >/dev/null 2>&1 && google-chrome --version || true
    command -v steam >/dev/null 2>&1 && echo "steam command found: $(command -v steam)" || true
    command -v micro >/dev/null 2>&1 && micro -version || true
}

tailscale_login_last() {
    section "Tailscale login/authentication"

    if [ "$RUN_TAILSCALE_UP_AT_END" != true ]; then
        warn "Automatic final 'sudo tailscale up' disabled by config"
        echo "Run this manually when ready:"
        echo "  sudo tailscale up"
        return 0
    fi

    if ! command -v tailscale >/dev/null 2>&1; then
        fail "Cannot run tailscale up because Tailscale is not installed"
        return 0
    fi

    echo "This is the final interactive step."
    echo "A browser may open, or Tailscale may print a login URL."
    echo "Complete the login in the browser."
    echo
    echo "+ sudo tailscale up"
    sudo tailscale up
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        ok "Tailscale authenticated"
        tailscale ip -4 2>/dev/null || true
    else
        fail "tailscale up failed or was cancelled (exit code $rc)"
        echo "You can retry later with:"
        echo "  sudo tailscale up"
    fi

    return 0
}

summary() {
    section "Bootstrap summary"

    echo "Log file:"
    echo "  $LOGFILE"
    echo

    echo "Successful steps (${#OK_ITEMS[@]}):"
    for item in "${OK_ITEMS[@]}"; do
        echo "  [OK] $item"
    done

    echo
    echo "Warnings (${#WARN_ITEMS[@]}):"
    for item in "${WARN_ITEMS[@]}"; do
        echo "  [WARN] $item"
    done

    echo
    echo "Failures (${#FAIL_ITEMS[@]}):"
    for item in "${FAIL_ITEMS[@]}"; do
        echo "  [FAIL] $item"
    done

    echo
    echo "Next steps:"
    echo "  1. If Tailscale is not authenticated, run: sudo tailscale up"
    echo "  2. Get the Tailscale IP with: tailscale ip -4"
    echo "  3. SSH from your machine: ssh <zorin_username>@<tailscale_ip>"
    echo "  4. NoMachine: connect to the same Tailscale IP."
    echo "  5. Steam: launch once and let it self-update/login."
    echo "  6. PS5 controller: pair in Bluetooth settings or plug in by USB."
    echo
    echo "Security note:"
    echo "  Do not open SSH, NoMachine, or RDP ports to the public internet."
    echo "  Use them over Tailscale."
}

main() {
    section "Zorin remote-support bootstrap v$VERSION"

    need_sudo
    system_report
    apt_fix
    apt_update
    install_base_tools
    install_ssh
    install_tailscale
    install_nomachine
    install_chrome
    install_steam
    install_micro
    install_extras
    final_status
    tailscale_login_last
    final_status
    summary
}

main "$@"
