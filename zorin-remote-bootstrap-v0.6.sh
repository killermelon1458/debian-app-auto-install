#!/usr/bin/env bash
# zorin-remote-bootstrap-v0.6.sh
#
# Zorin OS 18.1 Pro/Core post-install bootstrap for remote support.
#
# v0.6:
#   - Clean deployment version for a fresh Zorin install.
#   - Does not install Steam.
#   - Does not add i386 architecture.
#   - Does not perform cleanup for earlier test runs.
#   - Does not install game-devices-udev because it is not available in the tested Zorin repos.
#   - Keeps the tested NoMachine 9.6.3 download + MD5 + dpkg + apt-fix workflow.
#   - Keeps GNOME/Zorin built-in RDP Desktop Sharing setup.
#   - Keeps SSH + Tailscale + Chrome + micro + neofetch + support tools.
#
# IMPORTANT:
#   Run as the normal logged-in Zorin user, NOT with sudo.
#
# Example:
#   chmod +x zorin-remote-bootstrap-v0.6.sh
#   ./zorin-remote-bootstrap-v0.6.sh

set -u
set -o pipefail

VERSION="0.6"

INSTALL_CHROME=true
INSTALL_MICRO=true
INSTALL_NEOFETCH=true
INSTALL_NOMACHINE=true
INSTALL_EXTRAS=true
INSTALL_CONTROLLER_TOOLS=true
ENABLE_RDP_DESKTOP_SHARING=true

# Temporary RDP credentials. Change after first successful remote connection.
RDP_USERNAME="${RDP_USERNAME:-$USER}"
RDP_PASSWORD="${RDP_PASSWORD:-changeme}"

# NoMachine version tested on Zorin OS 18.1.
NOMACHINE_VERSION="9.6.3_1"
NOMACHINE_DEB="nomachine_${NOMACHINE_VERSION}_amd64.deb"
NOMACHINE_URL="https://web9001.nomachine.com/download/9.6/Linux/${NOMACHINE_DEB}"
NOMACHINE_EXPECTED_MD5="34d5882d1a1d20bbe9d5f7b3e2f35f12"

# Runs "sudo tailscale up" as the final step.
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

    # Fault tolerant: never stop the whole script because one command failed.
    return 0
}

need_normal_user() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        echo "Do NOT run this script with sudo."
        echo "Run it as the normal logged-in Zorin user:"
        echo "  bash ./zorin-remote-bootstrap-v0.6.sh"
        echo
        echo "Reason: GNOME Remote Desktop settings are per-user."
        echo "Running as root would configure root's RDP session, not the desktop user."
        exit 1
    fi
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
    section "Repairing interrupted package operations"

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

cleanup_old_steam_repo() {
    section "Cleaning old Steam repo/key artifacts from previous test runs"

    if [ "$CLEAN_OLD_STEAM_REPO" != true ]; then
        warn "Steam repo cleanup disabled by config"
        return 0
    fi

    # Old script versions could leave a Steam repo without the correct signing key,
    # making apt update fail. Steam is intentionally not part of this bootstrap now.
    local found=0

    if grep -Rqi "repo.steampowered.com\|steampowered" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        found=1
        echo "Existing Steam apt source references:"
        grep -RHi "repo.steampowered.com\|steampowered" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true
    fi

    shopt -s nullglob nocaseglob
    local files=(
        /etc/apt/sources.list.d/steam*.list
        /etc/apt/sources.list.d/steam*.sources
        /etc/apt/trusted.gpg.d/steam*.gpg
        /usr/share/keyrings/steam*.gpg
        /etc/apt/keyrings/steam*.gpg
    )
    shopt -u nullglob nocaseglob

    if [ "${#files[@]}" -gt 0 ]; then
        found=1
        run_cmd "remove Steam apt source/key files" \
            sudo rm -f "${files[@]}"
    else
        warn "no Steam apt source/key files found"
    fi

    if [ "$found" -eq 0 ]; then
        ok "no old Steam apt repo artifacts detected"
    fi

    if [ "$REMOVE_I386_IF_UNUSED" = true ]; then
        if dpkg --print-foreign-architectures | grep -qx "i386"; then
            if dpkg -l | awk '$4=="i386" && $1 ~ /^ii/ {print}' | grep -q .; then
                warn "i386 architecture is enabled and i386 packages are installed; leaving i386 enabled"
                dpkg -l | awk '$4=="i386" && $1 ~ /^ii/ {print}'
            else
                run_cmd "remove unused i386 architecture" \
                    sudo dpkg --remove-architecture i386
            fi
        else
            ok "i386 architecture is not enabled"
        fi
    fi
}

system_report() {
    section "System report"

    echo "Bootstrap version: $VERSION"
    echo "Date: $(date)"
    echo "User: $(whoami)"
    echo "UID: $(id -u)"
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
            run_cmd "allow SSH over Tailscale through UFW" \
                sudo ufw allow in on tailscale0 to any port 22 proto tcp
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

    if [ -f "$chrome_deb" ]; then
        run_cmd "install Google Chrome .deb" \
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$chrome_deb"
    else
        fail "Chrome .deb was not downloaded"
    fi
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

install_neofetch() {
    section "neofetch"

    if [ "$INSTALL_NEOFETCH" != true ]; then
        warn "neofetch install disabled by config"
        return 0
    fi

    if command -v neofetch >/dev/null 2>&1; then
        ok "neofetch already installed"
        neofetch --version || true
        return 0
    fi

    apt_install_one neofetch
}

install_nomachine() {
    section "NoMachine"

    if [ "$INSTALL_NOMACHINE" != true ]; then
        warn "NoMachine install disabled by config"
        return 0
    fi

    if [ -x /usr/NX/bin/nxserver ] && dpkg -l | grep -qi '^ii  nomachine '; then
        ok "NoMachine already installed"
        sudo /usr/NX/bin/nxserver --status || true
        /usr/NX/bin/nxplayer --version || true
        return 0
    fi

    # Prefer a known local copy beside the script or in Downloads. If missing, download it.
    local deb_path=""
    local candidate

    for candidate in \
        "$SCRIPT_DIR/$NOMACHINE_DEB" \
        "$HOME/Downloads/$NOMACHINE_DEB" \
        "$PWD/$NOMACHINE_DEB"; do
        if [ -f "$candidate" ]; then
            deb_path="$candidate"
            break
        fi
    done

    if [ -z "$deb_path" ]; then
        mkdir -p "$HOME/Downloads"
        deb_path="$HOME/Downloads/$NOMACHINE_DEB"

        echo "Downloading NoMachine:"
        echo "  $NOMACHINE_URL"
        run_cmd "download NoMachine .deb" \
            wget -O "$deb_path" "$NOMACHINE_URL"
    else
        ok "found local NoMachine .deb: $deb_path"
    fi

    if [ ! -f "$deb_path" ]; then
        fail "NoMachine .deb not found/downloaded"
        return 0
    fi

    local got_md5
    got_md5="$(md5sum "$deb_path" | awk '{print $1}')"
    echo "NoMachine MD5:"
    echo "  expected: $NOMACHINE_EXPECTED_MD5"
    echo "  actual:   $got_md5"

    if [ "$got_md5" != "$NOMACHINE_EXPECTED_MD5" ]; then
        fail "NoMachine MD5 mismatch; refusing to install"
        return 0
    fi

    ok "NoMachine MD5 verified"

    run_cmd "install NoMachine with dpkg" \
        sudo dpkg -i "$deb_path"

    run_cmd "repair/install NoMachine dependencies if needed" \
        sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y

    if [ -x /usr/NX/bin/nxserver ]; then
        ok "NoMachine nxserver installed"
        sudo /usr/NX/bin/nxserver --status || true
    else
        fail "NoMachine nxserver not found after install"
    fi

    if [ -x /usr/NX/bin/nxplayer ]; then
        ok "NoMachine nxplayer installed"
        /usr/NX/bin/nxplayer --version || true
    else
        fail "NoMachine nxplayer not found after install"
    fi

    if command -v ufw >/dev/null 2>&1; then
        if sudo ufw status | grep -q "Status: active"; then
            run_cmd "allow NoMachine over Tailscale through UFW" \
                sudo ufw allow in on tailscale0 to any port 4000 proto tcp
        else
            warn "UFW is installed but inactive; NoMachine firewall not changed"
        fi
    fi
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
            jstest-gtk
    else
        warn "controller tools install disabled by config"
    fi
}

configure_rdp_desktop_sharing() {
    section "GNOME/Zorin RDP Desktop Sharing"

    if [ "$ENABLE_RDP_DESKTOP_SHARING" != true ]; then
        warn "RDP Desktop Sharing disabled by config"
        return 0
    fi

    # This part is per-user. Do not use sudo for grdctl or systemctl --user.
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

    apt_install_one gnome-remote-desktop

    if ! command -v grdctl >/dev/null 2>&1; then
        fail "grdctl not found; cannot configure GNOME Remote Desktop from CLI"
        return 0
    fi

    run_cmd "reload user systemd units" \
        systemctl --user daemon-reload

    run_cmd "enable GNOME Remote Desktop user service" \
        systemctl --user enable --now gnome-remote-desktop.service

    run_cmd "set RDP credentials for Desktop Sharing" \
        grdctl rdp set-credentials "$RDP_USERNAME" "$RDP_PASSWORD"

    run_cmd "enable keyboard/mouse remote control for RDP" \
        grdctl rdp disable-view-only

    run_cmd "enable RDP backend" \
        grdctl rdp enable

    run_cmd "restart GNOME Remote Desktop user service" \
        systemctl --user restart gnome-remote-desktop.service

    run_cmd "show GNOME Remote Desktop status" \
        grdctl status

    if command -v ufw >/dev/null 2>&1; then
        if sudo ufw status | grep -q "Status: active"; then
            run_cmd "allow RDP over Tailscale through UFW" \
                sudo ufw allow in on tailscale0 to any port 3389 proto tcp
        else
            warn "UFW is installed but inactive; RDP firewall not changed"
        fi
    fi

    warn "RDP password is temporary and weak: $RDP_PASSWORD"
    warn "After first successful connection, change it in Settings > System > Remote Desktop"
    warn "Desktop Sharing generally requires the user to be logged into the Zorin desktop"
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
    echo "GNOME Remote Desktop status:"
    if command -v grdctl >/dev/null 2>&1; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        grdctl status || true
    else
        echo "grdctl not found"
    fi

    echo
    echo "NoMachine status:"
    if [ -x /usr/NX/bin/nxserver ]; then
        sudo /usr/NX/bin/nxserver --status || true
    else
        echo "NoMachine nxserver not found"
    fi

    echo
    echo "Listening remote-access ports:"
    ss -ltnp 2>/dev/null | grep -E ':(22|3389|4000)\b' || sudo ss -ltnp | grep -E ':(22|3389|4000)\b' || true

    echo
    echo "Installed versions:"
    command -v ssh >/dev/null 2>&1 && ssh -V 2>&1 || true
    command -v tailscale >/dev/null 2>&1 && tailscale version || true
    command -v google-chrome >/dev/null 2>&1 && google-chrome --version || true
    command -v micro >/dev/null 2>&1 && micro -version || true
    command -v neofetch >/dev/null 2>&1 && neofetch --version || true
    if [ -x /usr/NX/bin/nxplayer ]; then
        /usr/NX/bin/nxplayer --version || true
    fi
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
    echo "Connection info:"
    echo "  Get Tailscale IP:"
    echo "    tailscale ip -4"
    echo
    echo "  SSH:"
    echo "    ssh $(whoami)@<tailscale_ip>"
    echo
    echo "  RDP Desktop Sharing:"
    echo "    Server: <tailscale_ip>:3389"
    echo "    Username: $RDP_USERNAME"
    echo "    Password: $RDP_PASSWORD"
    echo
    echo "  NoMachine:"
    echo "    Server: <tailscale_ip>"
    echo "    Port: 4000"
    echo "    Username: $(whoami)"
    echo "    Password: the Zorin/Linux account password"
    echo
    echo "Next steps:"
    echo "  1. If Tailscale is not authenticated, run: sudo tailscale up"
    echo "  2. Get the Tailscale IP with: tailscale ip -4"
    echo "  3. Test SSH first."
    echo "  4. Test RDP second."
    echo "  5. Test NoMachine third."
    echo "  6. Change the temporary RDP password after first successful connection."
    echo "  7. PS5 controller: pair in Bluetooth settings or plug in by USB."
    echo
    echo "Security note:"
    echo "  Do not open SSH, RDP, or NoMachine ports to the public internet."
    echo "  Use them over Tailscale."
}

main() {
    section "Zorin remote-support bootstrap v$VERSION"

    need_normal_user
    need_sudo
    system_report
    apt_fix
    apt_update
    install_base_tools
    install_ssh
    install_tailscale
    install_chrome
    install_micro
    install_neofetch
    install_nomachine
    install_extras
    configure_rdp_desktop_sharing
    final_status
    tailscale_login_last
    final_status
    summary
}

main "$@"
