#!/usr/bin/env bash

set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly PACMAN_MANIFEST="$REPO_DIR/packages/arch/pacman.txt"
readonly AUR_MANIFEST="$REPO_DIR/packages/arch/aur.txt"
readonly FLATPAK_MANIFEST="$REPO_DIR/packages/flatpak.txt"
readonly SYSTEMD_UNIT_DIR="$REPO_DIR/systemd/system"
readonly STOW_DIR="$REPO_DIR/stow"
readonly HYDRO_PLUGIN="jorgebucaran/hydro"
readonly -a STOW_PACKAGES=(MangoHud brave cliamp environment.d fastfetch fish ghostty git jamesdsp ssh zed)
readonly -a KDE_BASELINE=(cachyos-kde-settings plasma-desktop plasma-workspace plasma-login-manager xdg-desktop-portal xdg-desktop-portal-kde kwallet-pam)

readonly -a DESKTOP_SERVICES=(
    avahi-daemon.service
    cups.socket
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
  --skip-system-config  Skip printer discovery and shared service setup
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
    stow_packages_ref=("${STOW_PACKAGES[@]}")
    local package
    for package in "${stow_packages_ref[@]}"; do
        [[ -d $STOW_DIR/$package ]] || die "Active Stow package missing: $package"
    done
}

check_kde_baseline() {
    require_command pacman
    require_command systemctl
    local package
    for package in "${KDE_BASELINE[@]}"; do
        pacman -Q "$package" >/dev/null 2>&1 || die "CachyOS KDE baseline package missing: $package"
    done
    require_file /usr/share/wayland-sessions/plasma.desktop
    require_file /usr/share/xdg-desktop-portal/portals/kde.portal
    require_file /usr/lib/systemd/system/plasmalogin.service
    require_file /usr/lib/pam.d/plasmalogin
    check_display_manager_conflict
}

preflight() {
    local -a aur_packages=()
    local -a synology_unit_paths=()
    local unit
    local validation_output

    [[ $EUID -ne 0 ]] || die "Run this script as your normal user, not as root."
    require_file /etc/os-release

    # shellcheck source=/etc/os-release disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == cachyos ]] || die \
        "This package manifest targets CachyOS; detected '${PRETTY_NAME:-unknown}'."
    check_kde_baseline

    if ! $skip_packages || ! $skip_system_config || ! $skip_mounts; then
        require_command sudo
    fi

    if ! $skip_packages; then
        require_command awk
        require_command chsh
        require_command getent
        require_command xdg-mime
        require_command xdg-user-dirs-update
        require_file "$PACMAN_MANIFEST"
        require_file "$AUR_MANIFEST"
        require_file "$FLATPAK_MANIFEST"
        load_manifest "$AUR_MANIFEST" aur_packages
        if ((${#aur_packages[@]} > 0)); then
            require_command paru
            require_command git
        fi
    fi

    if ! $skip_dotfiles; then
        local -a stow_packages=()
        load_stow_packages stow_packages
        if $skip_packages; then
            require_command stow
        fi
    fi

    if ! $skip_system_config; then
        if $skip_packages; then
            require_command lpinfo
        fi
    fi

    if ! $skip_mounts; then
        require_command cmp
        require_command mount.nfs
        require_command systemd-analyze
        for unit in "${SYNOLOGY_UNITS[@]}"; do
            require_file "$SYSTEMD_UNIT_DIR/$unit"
            synology_unit_paths+=("$SYSTEMD_UNIT_DIR/$unit")
        done
        if ! validation_output=$(systemd-analyze verify "${synology_unit_paths[@]}" 2>&1); then
            die "Synology unit validation failed: $validation_output"
        fi
    fi
}

install_bootstrap_dependencies() {
    if $skip_dotfiles; then
        log "Updating CachyOS"
        sudo pacman -Syu
    else
        log "Updating CachyOS and installing Stow"
        sudo pacman -Syu --needed stow
        require_command stow
    fi
}

install_packages() {
    local -a pacman_packages=()
    local -a aur_packages=()
    local -a flatpak_apps=()

    load_manifest "$PACMAN_MANIFEST" pacman_packages
    load_manifest "$AUR_MANIFEST" aur_packages
    load_manifest "$FLATPAK_MANIFEST" flatpak_apps

    log "Installing Fish, Flatpak, and ${#pacman_packages[@]} repository packages"
    sudo pacman -S --needed fish flatpak "${pacman_packages[@]}"
    require_command fish
    require_command flatpak
    if ! $skip_system_config; then
        require_command lpinfo
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
    xdg-mime default org.kde.dolphin.desktop inode/directory
    xdg-mime default brave-origin.desktop x-scheme-handler/http
    xdg-mime default brave-origin.desktop x-scheme-handler/https
    xdg-mime default brave-origin.desktop text/html
    xdg-mime default org.kde.okular.desktop application/pdf

    local mime_type
    for mime_type in \
        image/bmp \
        image/gif \
        image/jpeg \
        image/png \
        image/svg+xml \
        image/tiff \
        image/webp; do
        xdg-mime default org.kde.gwenview.desktop "$mime_type"
    done

    if ! $skip_dotfiles; then
        for mime_type in \
            audio/flac \
            audio/mp4 \
            audio/mpeg \
            audio/ogg \
            audio/x-vorbis+ogg \
            audio/x-wav; do
            xdg-mime default cliamp.desktop "$mime_type"
        done
    else
        warn "Audio MIME defaults need the Stow-managed cliamp launcher; skipping them."
    fi

    for mime_type in \
        video/mp4 \
        video/quicktime \
        video/webm \
        video/x-matroska \
        video/x-msvideo; do
        xdg-mime default org.kde.haruna.desktop \
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
        xdg-mime default org.kde.ark.desktop "$mime_type"
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

check_stow_conflicts() {
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
        "$HOME/.ssh" \
        "$HOME/.local/share/applications" \
        "$HOME/Pictures/Screenshots" \
        "$HOME/Pictures/Wallpapers"

    log "Checking dotfiles for Stow conflicts"
    stow --simulate --verbose=1 "${stow_options[@]}" \
        --restow "${stow_packages[@]}"
}

deploy_dotfiles() {
    local -a stow_packages=()
    load_stow_packages stow_packages

    log "Deploying ${#stow_packages[@]} dotfile packages"
    stow --dir="$STOW_DIR" --target="$HOME" --restow "${stow_packages[@]}"
}

check_display_manager_conflict() {
    local manager
    manager=$(systemctl show -P FragmentPath display-manager.service 2>/dev/null) || \
        die "Could not inspect display-manager.service."
    [[ -n $manager ]] || die "No display manager owns display-manager.service."
    [[ ${manager##*/} == plasmalogin.service ]] || die \
        "Another login manager owns display-manager.service ($manager); expected plasmalogin.service."
}

install_system_config() {
    require_command lpinfo

    log "Enabling shared desktop services"
    for unit in "${DESKTOP_SERVICES[@]}"; do
        sudo systemctl enable "$unit"
    done
    sudo systemctl start avahi-daemon.service cups.socket
}

install_synology_mounts() {
    local automount
    local mount_unit
    local -a changed_automounts=()

    require_command mount.nfs
    require_command cmp

    for automount in "${SYNOLOGY_AUTOMOUNTS[@]}"; do
        mount_unit=${automount%.automount}.mount
        if ! cmp -s "$SYSTEMD_UNIT_DIR/$automount" "/etc/systemd/system/$automount" ||
            ! cmp -s "$SYSTEMD_UNIT_DIR/$mount_unit" "/etc/systemd/system/$mount_unit"; then
            if systemctl is-active --quiet "$mount_unit"; then
                die "${mount_unit} is mounted while its unit has changed. Close files on the share, unmount it, and rerun the bootstrap."
            fi
            if systemctl is-active --quiet "$automount"; then
                changed_automounts+=("$automount")
            fi
        fi
    done

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
    if ((${#changed_automounts[@]} > 0)); then
        log "Restarting changed Synology automounts"
        sudo systemctl restart "${changed_automounts[@]}"
    fi
}

post_install_health_check() {
    local warning_count=0
    local required_failure_count=0
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
            printf '  [fail] Missing packages: %s\n' "${missing_packages[*]}"
            ((warning_count += 1))
            ((required_failure_count += 1))
        fi

        if ((${#missing_flatpaks[@]} == 0)); then
            printf '  [ok] All manifest Flatpaks are installed.\n'
        else
            printf '  [fail] Missing Flatpaks: %s\n' "${missing_flatpaks[*]}"
            ((warning_count += 1))
            ((required_failure_count += 1))
        fi

        # The single-quoted variable is expanded by Fish, not Bash.
        # shellcheck disable=SC2016
        if fish -c \
            'type -q fisher; and fisher list | string match --quiet -- "$argv[1]"' \
            "$HYDRO_PLUGIN"; then
            printf '  [ok] Fisher and the Hydro prompt are installed.\n'
        else
            printf '  [fail] Fisher or the Hydro prompt is unavailable.\n'
            ((warning_count += 1))
            ((required_failure_count += 1))
        fi
    else
        printf '  [skip] Package and Flatpak checks were not requested.\n'
    fi

    if ! $skip_packages || ! $skip_system_config; then
        for path in \
            /usr/share/wayland-sessions/plasma.desktop \
            /usr/share/xdg-desktop-portal/portals/kde.portal \
            /usr/lib/pam.d/plasmalogin \
            /usr/lib/systemd/system/plasmalogin.service; do
            [[ -f $path ]] || missing_desktop_commands+=("$path")
        done
        if [[ $(systemctl show -P FragmentPath display-manager.service 2>/dev/null) != */plasmalogin.service ]] ||
            ! systemctl is-enabled --quiet plasmalogin.service 2>/dev/null; then
            missing_desktop_commands+=("display-manager.service:plasmalogin")
        fi
        if ((${#missing_desktop_commands[@]} == 0)); then
            printf '  [ok] Plasma session, KDE portal, and login PAM are installed.\n'
        else
            printf '  [fail] Missing KDE integration: %s\n' "${missing_desktop_commands[*]}"
            ((warning_count += 1))
            ((required_failure_count += 1))
        fi
    fi

    if [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]]; then
        printf '  [ok] Current session reports KDE.\n'
        if command -v busctl >/dev/null 2>&1 &&
            busctl --user --no-pager status org.freedesktop.impl.portal.desktop.kde >/dev/null 2>&1; then
            printf '  [ok] KDE portal is available on the user bus.\n'
        else
            printf '  [warn] KDE portal is unavailable on the user bus.\n'
            ((warning_count += 1))
        fi
        if command -v busctl >/dev/null 2>&1 &&
            busctl --user --no-pager status org.freedesktop.secrets 2>/dev/null |
                grep -qi ksecretd; then
            printf '  [ok] KWallet Secret Service is available on the user bus.\n'
        else
            printf '  [warn] KWallet Secret Service is unavailable on the user bus.\n'
            ((warning_count += 1))
        fi
    else
        printf '  [note] Log into Plasma to check the session and KWallet Secret Service.\n'
    fi

    if ! $skip_packages; then
        local mime desktop
        for mime in inode/directory application/pdf image/png audio/mpeg video/mp4 application/zip x-scheme-handler/https text/plain; do
            if $skip_dotfiles && [[ $mime == audio/mpeg ]]; then
                continue
            fi
            case $mime in
                inode/directory) desktop=org.kde.dolphin.desktop ;;
                application/pdf) desktop=org.kde.okular.desktop ;;
                image/png) desktop=org.kde.gwenview.desktop ;;
                audio/mpeg) desktop=cliamp.desktop ;;
                video/mp4) desktop=org.kde.haruna.desktop ;;
                application/zip) desktop=org.kde.ark.desktop ;;
                x-scheme-handler/https) desktop=brave-origin.desktop ;;
                text/plain) desktop=dev.zed.Zed.desktop ;;
            esac
            [[ $(xdg-mime query default "$mime") == "$desktop" ]] || \
                desktop_service_issues+=("MIME:$mime")
        done
    fi

    if ! $skip_system_config; then
        for unit in "${DESKTOP_SERVICES[@]}"; do
            systemctl is-enabled --quiet "$unit" 2>/dev/null || \
                desktop_service_issues+=("$unit")
        done

    fi

    if ! $skip_packages || ! $skip_system_config; then
        if ((${#desktop_service_issues[@]} == 0)); then
            printf '  [ok] Shared desktop services and KDE MIME defaults are configured.\n'
        else
            printf '  [fail] Desktop service or MIME issues: %s\n' \
                "${desktop_service_issues[*]}"
            ((warning_count += 1))
            ((required_failure_count += 1))
        fi
    fi

    if ! $skip_system_config; then
        if printer_discovery_output=$(lpinfo \
            --include-schemes dnssd --timeout 15 -v 2>/dev/null) &&
            grep -Eq 'dnssd://.*\._ipps?\._tcp' <<< "$printer_discovery_output"; then
            printf '  [ok] A driverless network printer was discovered.\n'
        else
            printf '  [note] No DNS-SD printer is currently visible; it may be offline.\n'
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
            printf '  [fail] Inactive Synology automounts: %s\n' "${mount_issues[*]}"
            ((warning_count += 1))
            ((required_failure_count += 1))
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
            printf '  [fail] Dotfiles not linked to the repository: %s\n' "${stow_issues[*]}"
            ((warning_count += 1))
            ((required_failure_count += 1))
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
    elif $logout_recommended; then
        printf '  [note] Log out and back in to use Fish as the login shell.\n'
    else
        printf '  [ok] No logout or kernel reboot requirement detected.\n'
    fi

    if ((warning_count == 0)); then
        printf '  Health check completed without warnings.\n'
    else
        printf '  Health check completed with %s warning or failure group(s).\n' "$warning_count"
    fi

    if ((required_failure_count > 0)); then
        die "Bootstrap left $required_failure_count required health check group(s) unresolved."
    fi
}

main() {
    preflight

    if ! $skip_packages || ! $skip_system_config || ! $skip_mounts; then
        log "Refreshing sudo credentials"
        sudo -v
    fi

    if ! $skip_packages; then
        install_bootstrap_dependencies
    fi

    if ! $skip_dotfiles; then
        check_stow_conflicts
    fi

    if $skip_packages; then
        log "Skipping packages, Flatpaks, and user environment setup"
    else
        install_packages
    fi

    if $skip_dotfiles; then
        log "Skipping dotfile deployment"
    else
        deploy_dotfiles
    fi

    if ! $skip_packages; then
        configure_user_environment
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
        printf '  Desktop session:       Installer Plasma session\n'
        printf '  Display manager:       Plasma Login Manager\n'
    fi
    if $skip_mounts; then
        printf '  Synology mounts:       skipped\n'
    else
        printf '  Synology mounts:       installed and enabled\n'
    fi
}

main
