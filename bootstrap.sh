#!/usr/bin/env bash

set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly PACMAN_MANIFEST="$REPO_DIR/packages/arch/pacman.txt"
readonly AUR_MANIFEST="$REPO_DIR/packages/arch/aur.txt"
readonly FLATPAK_MANIFEST="$REPO_DIR/packages/flatpak.txt"
readonly SYSTEMD_UNIT_DIR="$REPO_DIR/systemd/system"
readonly STOW_DIR="$REPO_DIR/stow"
readonly GREETD_CONFIG_SOURCE="$REPO_DIR/system/etc/greetd/config.toml"
readonly GREETD_CONFIG_TARGET="/etc/greetd/config.toml"
readonly GREETD_PAM_SOURCE="$REPO_DIR/system/etc/pam.d/greetd"
readonly GREETD_PAM_TARGET="/etc/pam.d/greetd"
readonly GREETER_CONFIG_SOURCE="$REPO_DIR/system/var/lib/noctalia-greeter/greeter.toml"
readonly GREETER_CONFIG_TARGET="/var/lib/noctalia-greeter/greeter.toml"
readonly NSSWITCH_CONFIG="/etc/nsswitch.conf"
readonly HYDRO_PLUGIN="jorgebucaran/hydro"

readonly -a DESKTOP_SERVICES=(
    avahi-daemon.service
    bluetooth.service
    cups.socket
    ufw.service
)

readonly -a DESKTOP_USER_SERVICES=(
    psd.service
)

readonly -a SYNOLOGY_UNITS=(
    mnt-synology-data.mount
    mnt-synology-data.automount
    mnt-synology-home.mount
    mnt-synology-home.automount
)

readonly -a SYNOLOGY_AUTOMOUNTS=(
    mnt-synology-data.automount
    mnt-synology-home.automount
)

skip_packages=false
skip_dotfiles=false
skip_system_config=false
skip_mounts=false
logout_recommended=false
reboot_recommended=false

log() {
    printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [OPTIONS]

Restore packages, Flatpaks, dotfiles, system configuration, and Synology automounts on CachyOS.

Options:
  --skip-packages       Skip packages, Flatpaks, and user environment setup
  --skip-dotfiles       Skip GNU Stow dotfile deployment
  --skip-system-config  Skip greetd, greeter, and desktop service setup
  --skip-mounts         Skip Synology systemd unit installation
  -h, --help            Show this help
EOF
}

on_error() {
    local exit_code=$?
    printf '\n\033[1;31mBootstrap failed at line %s (exit %s).\033[0m\n' \
        "${BASH_LINENO[0]}" "$exit_code" >&2
    exit "$exit_code"
}

trap on_error ERR

while (($# > 0)); do
    case "$1" in
        --skip-packages)
            skip_packages=true
            ;;
        --skip-dotfiles)
            skip_dotfiles=true
            ;;
        --skip-system-config)
            skip_system_config=true
            ;;
        --skip-mounts)
            skip_mounts=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac
    shift
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}

load_manifest() {
    local manifest=$1
    local -n destination=$2

    require_file "$manifest"
    # ShellCheck cannot follow this write through a nameref to its caller.
    # shellcheck disable=SC2034
    mapfile -t destination < <(
        awk 'NF && $1 !~ /^#/ { print $1 }' "$manifest"
    )
}

load_stow_packages() {
    local -n stow_packages_ref=$1

    [[ -d $STOW_DIR ]] || die "Stow directory not found: $STOW_DIR"
    mapfile -t stow_packages_ref < <(
        find "$STOW_DIR" -mindepth 1 -maxdepth 1 -type d \
            ! -name vicinae \
            ! -name zsh \
            -printf '%f\n' |
            LC_ALL=C sort
    )
    ((${#stow_packages_ref[@]} > 0)) || die "No Stow packages found in $STOW_DIR."
}

preflight() {
    [[ $EUID -ne 0 ]] || die "Run this script as your normal user, not as root."
    require_file /etc/os-release

    # shellcheck source=/etc/os-release disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == cachyos ]] || die \
        "This package manifest targets CachyOS; detected '${PRETTY_NAME:-unknown}'."

    if ! $skip_packages; then
        require_command sudo
        require_command pacman
        require_file "$PACMAN_MANIFEST"
        require_file "$AUR_MANIFEST"
        require_file "$FLATPAK_MANIFEST"
    fi

    if ! $skip_dotfiles; then
        local -a stow_packages=()
        load_stow_packages stow_packages
    fi

    if ! $skip_system_config; then
        require_command sudo
        require_command readlink
        require_file "$GREETD_CONFIG_SOURCE"
        require_file "$GREETD_PAM_SOURCE"
        require_file "$GREETER_CONFIG_SOURCE"
        check_display_manager_conflict
    fi

    if ! $skip_mounts; then
        require_command sudo
        for unit in "${SYNOLOGY_UNITS[@]}"; do
            require_file "$SYSTEMD_UNIT_DIR/$unit"
        done
    fi
}

install_packages() {
    local -a bootstrap_packages=(base-devel fish git stow flatpak networkmanager paru tealdeer)
    local -a pacman_packages=()
    local -a aur_packages=()
    local -a flatpak_apps=()

    if ! $skip_mounts; then
        bootstrap_packages+=(nfs-utils)
    fi

    load_manifest "$PACMAN_MANIFEST" pacman_packages
    load_manifest "$AUR_MANIFEST" aur_packages
    load_manifest "$FLATPAK_MANIFEST" flatpak_apps

    log "Updating CachyOS and installing bootstrap dependencies"
    sudo pacman -Syu --needed "${bootstrap_packages[@]}"

    if ((${#pacman_packages[@]} > 0)); then
        log "Installing ${#pacman_packages[@]} repository packages"
        sudo pacman -S --needed "${pacman_packages[@]}"
    fi

    if ((${#aur_packages[@]} > 0)); then
        log "Installing ${#aur_packages[@]} AUR/foreign packages"
        paru -S --needed "${aur_packages[@]}"
    fi

    log "Configuring the system-wide Flathub remote"
    sudo flatpak remote-add --system --if-not-exists \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    if ((${#flatpak_apps[@]} > 0)); then
        log "Installing or updating ${#flatpak_apps[@]} Flatpak applications"
        sudo flatpak install --system --or-update flathub "${flatpak_apps[@]}"
    fi
}

configure_user_environment() {
    require_command chsh
    require_command fish
    require_command getent
    require_command xdg-mime
    require_command xdg-user-dirs-update

    local target_user
    local current_shell
    local fish_path

    target_user=$(id -un)
    fish_path=$(command -v fish)
    current_shell=$(getent passwd "$target_user" | awk -F: '{ print $7 }')
    [[ -n $current_shell ]] || die "Could not determine the login shell for $target_user."

    if [[ $current_shell == "$fish_path" ]]; then
        log "Fish is already the login shell for $target_user"
    else
        log "Changing the login shell for $target_user to $fish_path"
        sudo chsh -s "$fish_path" "$target_user"
        logout_recommended=true
    fi

    log "Creating the standard XDG user directories"
    xdg-user-dirs-update

    log "Setting desktop application defaults"
    xdg-mime default org.gnome.Nautilus.desktop inode/directory
    xdg-mime default brave-origin.desktop x-scheme-handler/http
    xdg-mime default brave-origin.desktop x-scheme-handler/https
    xdg-mime default brave-origin.desktop text/html
    xdg-mime default org.gnome.Papers.desktop application/pdf

    local mime_type
    for mime_type in \
        image/bmp \
        image/gif \
        image/jpeg \
        image/png \
        image/svg+xml \
        image/tiff \
        image/webp; do
        xdg-mime default org.gnome.Loupe.desktop "$mime_type"
    done

    for mime_type in \
        audio/flac \
        audio/mp4 \
        audio/mpeg \
        audio/ogg \
        audio/x-vorbis+ogg \
        audio/x-wav; do
        xdg-mime default io.bassi.Amberol.desktop "$mime_type"
    done

    for mime_type in \
        video/mp4 \
        video/quicktime \
        video/webm \
        video/x-matroska \
        video/x-msvideo; do
        xdg-mime default io.github.celluloid_player.Celluloid.desktop \
            "$mime_type"
    done

    xdg-mime default org.qbittorrent.qBittorrent.desktop \
        application/x-bittorrent
    xdg-mime default org.qbittorrent.qBittorrent.desktop \
        x-scheme-handler/magnet

    for mime_type in \
        application/gzip \
        application/vnd.rar \
        application/x-7z-compressed \
        application/x-bzip2 \
        application/x-bzip-compressed-tar \
        application/x-compressed-tar \
        application/x-tar \
        application/x-xz \
        application/x-xz-compressed-tar \
        application/zip; do
        xdg-mime default org.gnome.FileRoller.desktop "$mime_type"
    done

    xdg-mime default dev.zed.Zed.desktop application/x-zerosize
    xdg-mime default dev.zed.Zed.desktop text/plain
}

configure_fish_plugins() {
    require_command fish

    fish -c 'type -q fisher' || die \
        "Fisher is unavailable after package installation."

    # The single-quoted variable is expanded by Fish, not Bash.
    # shellcheck disable=SC2016
    if fish -c \
        'fisher list | string match --quiet -- "$argv[1]"' "$HYDRO_PLUGIN"; then
        log "Hydro is already installed with Fisher"
    else
        log "Installing the Hydro prompt with Fisher"
        # The single-quoted variable is expanded by Fish, not Bash.
        # shellcheck disable=SC2016
        fish -c 'fisher install "$argv[1]"' "$HYDRO_PLUGIN"
    fi
}

deploy_dotfiles() {
    require_command stow

    local -a stow_packages=()
    local -a stow_options=(
        --dir="$STOW_DIR"
        --target="$HOME"
    )

    load_stow_packages stow_packages

    # Keep these as real directories so applications can create unmanaged
    # runtime files alongside the individually Stow-managed user files.
    mkdir -p \
        "$HOME/.config/jamesdsp/irs" \
        "$HOME/.config/jamesdsp/presets" \
        "$HOME/.config/gtk-3.0" \
        "$HOME/.config/gtk-4.0" \
        "$HOME/.config/noctalia" \
        "$HOME/.config/umbriel" \
        "$HOME/.ssh" \
        "$HOME/.local/share/applications" \
        "$HOME/Pictures/Screenshots" \
        "$HOME/Pictures/Wallpapers"

    log "Checking dotfiles for Stow conflicts"
    stow --simulate --verbose=1 "${stow_options[@]}" \
        --restow "${stow_packages[@]}"

    log "Deploying ${#stow_packages[@]} dotfile packages"
    stow "${stow_options[@]}" --restow "${stow_packages[@]}"
}

configure_network_printing() {
    require_command awk
    require_command cmp
    require_command grep
    require_command mktemp
    require_file "$NSSWITCH_CONFIG"

    local nsswitch_tmp
    nsswitch_tmp=$(mktemp)

    if ! awk '
        BEGIN { hosts_lines = 0 }

        $1 == "hosts:" {
            hosts_lines += 1
            output = "hosts:"
            inserted = 0

            for (field = 2; field <= NF; field += 1) {
                if ($field == "mdns_minimal") {
                    if ($(field + 1) == "[NOTFOUND=return]") {
                        field += 1
                    }
                    continue
                }

                if (!inserted &&
                    ($field == "resolve" || $field == "dns" ||
                        $field ~ /^#/)) {
                    output = output " mdns_minimal [NOTFOUND=return]"
                    inserted = 1
                }

                output = output " " $field
            }

            if (!inserted) {
                output = output " mdns_minimal [NOTFOUND=return]"
            }

            print output
            next
        }

        { print }

        END {
            if (hosts_lines != 1) {
                exit 1
            }
        }
    ' "$NSSWITCH_CONFIG" > "$nsswitch_tmp"; then
        rm -f "$nsswitch_tmp"
        die "Expected exactly one hosts entry in $NSSWITCH_CONFIG."
    fi

    if ! grep -Eq \
        '^hosts:.*(^|[[:space:]])mdns_minimal[[:space:]]+\[NOTFOUND=return\]' \
        "$nsswitch_tmp"; then
        rm -f "$nsswitch_tmp"
        die "Could not add mDNS hostname resolution to $NSSWITCH_CONFIG."
    fi

    if cmp -s "$NSSWITCH_CONFIG" "$nsswitch_tmp"; then
        log "mDNS hostname resolution is already configured"
    else
        log "Configuring mDNS hostname resolution"
        if ! sudo install -C -m 0644 "$nsswitch_tmp" "$NSSWITCH_CONFIG"; then
            rm -f "$nsswitch_tmp"
            die "Could not install the updated $NSSWITCH_CONFIG."
        fi
    fi
    rm -f "$nsswitch_tmp"

    log "Allowing inbound mDNS discovery through UFW"
    sudo ufw allow in proto udp to any port 5353 \
        comment "mDNS printer discovery"
}

check_display_manager_conflict() {
    local display_manager_link=/etc/systemd/system/display-manager.service
    local display_manager_target
    local display_manager_unit

    [[ -L $display_manager_link ]] || return 0

    display_manager_target=$(readlink -e -- "$display_manager_link") || \
        die "Could not resolve the existing display-manager.service alias."
    display_manager_unit=${display_manager_target##*/}

    [[ $display_manager_unit == greetd.service ]] || die \
        "Another display manager owns display-manager.service ($display_manager_unit). Disable it before configuring greetd."
}

install_system_config() {
    require_command getent
    require_command lpinfo
    require_command noctalia-greeter-session
    require_command start-umbriel
    require_command ufw

    getent passwd greeter >/dev/null || \
        die "The greetd package did not create its greeter account."
    getent group greeter >/dev/null || \
        die "The greetd package did not create its greeter group."

    log "Configuring Noctalia Greeter and greetd"
    sudo install -C -D -m 0644 "$GREETD_CONFIG_SOURCE" "$GREETD_CONFIG_TARGET"
    sudo install -C -D -m 0644 "$GREETD_PAM_SOURCE" "$GREETD_PAM_TARGET"
    sudo install -d -m 0750 -o greeter -g greeter /var/lib/noctalia-greeter
    sudo install -C -m 0640 -o greeter -g greeter \
        "$GREETER_CONFIG_SOURCE" "$GREETER_CONFIG_TARGET"

    configure_network_printing

    log "Enabling UFW"
    sudo ufw --force enable

    log "Enabling desktop services"
    for unit in "${DESKTOP_SERVICES[@]}"; do
        sudo systemctl enable "$unit"
    done

    # Start only the non-graphical printer-discovery services immediately. The
    # greeter still waits until reboot so it cannot take over the active TTY.
    sudo systemctl start avahi-daemon.service cups.socket

    for unit in "${DESKTOP_USER_SERVICES[@]}"; do
        systemctl --user enable "$unit"
    done

    sudo systemctl enable greetd.service
    sudo systemctl set-default graphical.target
    reboot_recommended=true
}

install_synology_mounts() {
    require_command mount.nfs

    log "Installing Synology systemd mount and automount units"
    sudo install -d -m 0755 \
        /etc/systemd/system \
        /mnt/synology/data \
        /mnt/synology/home

    for unit in "${SYNOLOGY_UNITS[@]}"; do
        sudo install -C -m 0644 \
            "$SYSTEMD_UNIT_DIR/$unit" \
            "/etc/systemd/system/$unit"
    done

    sudo systemctl daemon-reload
    sudo systemctl enable --now "${SYNOLOGY_AUTOMOUNTS[@]}"
}

post_install_health_check() {
    local warning_count=0
    local source_path
    local relative_path
    local target_path
    local unit
    local package
    local app
    local -a pacman_packages=()
    local -a aur_packages=()
    local -a flatpak_apps=()
    local -a missing_packages=()
    local -a missing_flatpaks=()
    local -a failed_units=()
    local -a mount_issues=()
    local -a stow_issues=()
    local -a pacnew_files=()
    local -a missing_desktop_commands=()
    local -a desktop_service_issues=()
    local -a stow_packages=()
    local printer_discovery_output
    local validation_output

    log "Running post-install health checks"

    if ! $skip_packages; then
        load_manifest "$PACMAN_MANIFEST" pacman_packages
        load_manifest "$AUR_MANIFEST" aur_packages
        load_manifest "$FLATPAK_MANIFEST" flatpak_apps

        for package in "${pacman_packages[@]}" "${aur_packages[@]}"; do
            pacman -Q "$package" >/dev/null 2>&1 || missing_packages+=("$package")
        done

        for app in "${flatpak_apps[@]}"; do
            flatpak info --system "$app" >/dev/null 2>&1 || missing_flatpaks+=("$app")
        done

        if ((${#missing_packages[@]} == 0)); then
            printf '  [ok] All manifest packages are installed.\n'
        else
            printf '  [warn] Missing packages: %s\n' "${missing_packages[*]}"
            ((warning_count += 1))
        fi

        if ((${#missing_flatpaks[@]} == 0)); then
            printf '  [ok] All manifest Flatpaks are installed.\n'
        else
            printf '  [warn] Missing Flatpaks: %s\n' "${missing_flatpaks[*]}"
            ((warning_count += 1))
        fi

        # The single-quoted variable is expanded by Fish, not Bash.
        # shellcheck disable=SC2016
        if fish -c \
            'type -q fisher; and fisher list | string match --quiet -- "$argv[1]"' \
            "$HYDRO_PLUGIN"; then
            printf '  [ok] Fisher and the Hydro prompt are installed.\n'
        else
            printf '  [warn] Fisher or the Hydro prompt is unavailable.\n'
            ((warning_count += 1))
        fi
    else
        printf '  [skip] Package and Flatpak checks were not requested.\n'
    fi

    if ! $skip_packages || ! $skip_system_config; then
        for command in \
            noctalia \
            noctalia-greeter-session \
            start-umbriel \
            umbriel \
            xwayland-satellite; do
            command -v "$command" >/dev/null 2>&1 || \
                missing_desktop_commands+=("$command")
        done

        for path in \
            /usr/share/wayland-sessions/umbriel.desktop \
            /usr/share/xdg-desktop-portal/portals/umbriel.portal \
            /usr/share/xdg-desktop-portal/umbriel-portals.conf; do
            [[ -f $path ]] || missing_desktop_commands+=("$path")
        done

        if ((${#missing_desktop_commands[@]} == 0)); then
            printf '  [ok] Umbriel, Noctalia, Xwayland, and portal integration are installed.\n'
        else
            printf '  [warn] Missing desktop integration: %s\n' \
                "${missing_desktop_commands[*]}"
            ((warning_count += 1))
        fi
    fi

    if ! $skip_system_config; then
        for unit in "${DESKTOP_SERVICES[@]}" greetd.service; do
            systemctl is-enabled --quiet "$unit" 2>/dev/null || \
                desktop_service_issues+=("$unit")
        done

        for unit in "${DESKTOP_USER_SERVICES[@]}"; do
            systemctl --user is-enabled --quiet "$unit" 2>/dev/null || \
                desktop_service_issues+=("user:$unit")
        done

        if [[ $(systemctl get-default 2>/dev/null) != graphical.target ]]; then
            desktop_service_issues+=("default-target:graphical.target")
        fi

        if ((${#desktop_service_issues[@]} == 0)); then
            printf '  [ok] Noctalia Greeter and desktop services are enabled.\n'
        else
            printf '  [warn] Desktop services not enabled: %s\n' \
                "${desktop_service_issues[*]}"
            ((warning_count += 1))
        fi

        if grep -Eq \
            '^hosts:.*(^|[[:space:]])mdns_minimal[[:space:]]+\[NOTFOUND=return\]' \
            "$NSSWITCH_CONFIG"; then
            printf '  [ok] mDNS hostname resolution is configured.\n'
        else
            printf '  [warn] mDNS hostname resolution is not configured.\n'
            ((warning_count += 1))
        fi

        if printer_discovery_output=$(lpinfo \
            --include-schemes dnssd --timeout 15 -v 2>/dev/null) &&
            grep -Eq 'dnssd://.*\._ipps?\._tcp' <<< "$printer_discovery_output"; then
            printf '  [ok] A driverless network printer was discovered.\n'
        else
            printf '  [note] No DNS-SD printer is currently visible; it may be offline.\n'
        fi
    fi

    if ! $skip_dotfiles; then
        if ! command -v umbriel >/dev/null 2>&1; then
            printf '  [note] Umbriel is unavailable; configuration validation was skipped.\n'
        elif validation_output=$(umbriel validate -c \
            "$STOW_DIR/umbriel/.config/umbriel/config.toml" 2>&1); then
            printf '  [ok] Checked-in Umbriel configuration is valid.\n'
        else
            printf '  [warn] Umbriel configuration validation failed:\n'
            printf '         %s\n' "$validation_output"
            ((warning_count += 1))
        fi

        if ! command -v noctalia >/dev/null 2>&1; then
            printf '  [note] Noctalia is unavailable; configuration validation was skipped.\n'
        elif validation_output=$(noctalia config validate \
            "$STOW_DIR/noctalia/.config/noctalia/config.toml" 2>&1); then
            printf '  [ok] Checked-in Noctalia configuration is valid.\n'
        else
            printf '  [warn] Noctalia configuration validation failed:\n'
            printf '         %s\n' "$validation_output"
            ((warning_count += 1))
        fi
    fi

    mapfile -t failed_units < <(
        systemctl --failed --no-legend --plain 2>/dev/null |
            awk 'NF { print $1 }' || true
    )
    if ((${#failed_units[@]} == 0)); then
        printf '  [ok] No failed systemd system units.\n'
    else
        printf '  [warn] Failed systemd units: %s\n' "${failed_units[*]}"
        ((warning_count += 1))
    fi

    if ! $skip_mounts; then
        for unit in "${SYNOLOGY_AUTOMOUNTS[@]}"; do
            systemctl is-active --quiet "$unit" || mount_issues+=("$unit")
        done

        if ((${#mount_issues[@]} == 0)); then
            printf '  [ok] Synology automount units are active.\n'
        else
            printf '  [warn] Inactive Synology automounts: %s\n' "${mount_issues[*]}"
            ((warning_count += 1))
        fi
    else
        printf '  [skip] Synology automount checks were not requested.\n'
    fi

    if ! $skip_dotfiles; then
        load_stow_packages stow_packages

        for package in "${stow_packages[@]}"; do
            while IFS= read -r -d '' source_path; do
                relative_path=${source_path#"$STOW_DIR/$package"/}
                target_path=$HOME/$relative_path

                if [[ ! -e $target_path && ! -L $target_path ]] ||
                    [[ $(realpath -e -- "$source_path" 2>/dev/null || true) != \
                        $(realpath -e -- "$target_path" 2>/dev/null || true) ]]; then
                    stow_issues+=("$relative_path")
                fi
            done < <(
                find "$STOW_DIR/$package" -mindepth 1 \
                    \( -type f -o -type l \) -print0
            )
        done

        if ((${#stow_issues[@]} == 0)); then
            printf '  [ok] All managed dotfiles resolve to the repository.\n'
        else
            printf '  [warn] Dotfiles not linked to the repository: %s\n' "${stow_issues[*]}"
            ((warning_count += 1))
        fi
    else
        printf '  [skip] Dotfile link checks were not requested.\n'
    fi

    mapfile -t pacnew_files < <(
        find /etc -xdev -type f -name '*.pacnew' -print 2>/dev/null |
            LC_ALL=C sort || true
    )
    if ((${#pacnew_files[@]} == 0)); then
        printf '  [ok] No outstanding .pacnew files.\n'
    else
        printf '  [warn] Review %s outstanding .pacnew file(s):\n' "${#pacnew_files[@]}"
        printf '         %s\n' "${pacnew_files[@]}"
        ((warning_count += 1))
    fi

    if [[ ! -d /usr/lib/modules/$(uname -r) ]]; then
        printf '  [warn] The running kernel no longer has installed modules; reboot recommended.\n'
        ((warning_count += 1))
    elif $reboot_recommended; then
        printf '  [note] Reboot to start Noctalia Greeter and the Umbriel session.\n'
    elif $logout_recommended; then
        printf '  [note] Log out and back in to use Fish as the login shell.\n'
    else
        printf '  [ok] No logout or kernel reboot requirement detected.\n'
    fi

    if ((warning_count == 0)); then
        printf '  Health check completed without warnings.\n'
    else
        printf '  Health check completed with %s warning group(s).\n' "$warning_count"
    fi
}

main() {
    preflight

    if ! $skip_packages || ! $skip_system_config || ! $skip_mounts; then
        log "Refreshing sudo credentials"
        sudo -v
    fi

    if $skip_packages; then
        log "Skipping packages, Flatpaks, and user environment setup"
    else
        install_packages
        configure_user_environment
    fi

    if $skip_dotfiles; then
        log "Skipping dotfile deployment"
    else
        deploy_dotfiles
    fi

    if ! $skip_packages; then
        configure_fish_plugins
    fi

    if $skip_system_config; then
        log "Skipping system-wide configuration installation"
    else
        install_system_config
    fi

    if $skip_mounts; then
        log "Skipping Synology mount installation"
    else
        install_synology_mounts
    fi

    post_install_health_check

    log "Bootstrap completed"
    printf '  Packages and Flatpaks: %s\n' "$($skip_packages && printf skipped || printf processed)"
    printf '  User environment:      %s\n' "$($skip_packages && printf skipped || printf configured)"
    printf '  Dotfiles:              %s\n' "$($skip_dotfiles && printf skipped || printf deployed)"
    printf '  System configuration:  %s\n' "$($skip_system_config && printf skipped || printf installed)"
    if ! $skip_system_config; then
        printf '  Desktop session:       Umbriel + Noctalia (starts after reboot)\n'
        printf '  Display manager:       Noctalia Greeter via greetd\n'
    fi
    if $skip_mounts; then
        printf '  Synology mounts:       skipped\n'
    else
        printf '  Synology mounts:       installed and enabled\n'
    fi
}

main
