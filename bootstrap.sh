#!/usr/bin/env bash

set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly PACMAN_MANIFEST="$REPO_DIR/packages/arch/pacman.txt"
readonly AUR_MANIFEST="$REPO_DIR/packages/arch/aur.txt"
readonly FLATPAK_MANIFEST="$REPO_DIR/packages/flatpak.txt"
readonly HOUDINI_REQUIREMENTS="$REPO_DIR/packages/waydroid-script-requirements.lock.txt"
readonly SYSTEMD_UNIT_DIR="$REPO_DIR/systemd/system"
readonly STOW_DIR="$REPO_DIR/stow"
readonly HYDRO_PLUGIN="jorgebucaran/hydro"
readonly WAYDROID_IMAGE_DIR=/etc/waydroid-extra/images
readonly WAYDROID_DATA_BACKUP="$REPO_DIR/waydroid-data.tar.zst"
readonly WAYDROID_SYSTEM_URL=https://sourceforge.net/projects/waydroid/files/images/system/lineage/waydroid_x86_64/lineage-20.0-20260312-GAPPS-waydroid_x86_64-system.zip/download
readonly WAYDROID_VENDOR_URL=https://sourceforge.net/projects/waydroid/files/images/vendor/waydroid_x86_64/lineage-20.0-20260312-MAINLINE-waydroid_x86_64-vendor.zip/download
readonly WAYDROID_SYSTEM_SHA256=fe3387008d939b8a68e7cbe2c5c8f2b3237f1b075a44ad54ac3f2e2c4a3f6abb
readonly WAYDROID_VENDOR_SHA256=1158bbb5244072ce8741757494e3ac5f3177d5dfbbdc132e5e2cf1e616d10bd5
readonly WAYDROID_SCRIPT_COMMIT=48dbfaf34a6ddbe78688c530f9ba1c26522aafb2
readonly HOUDINI_URL=https://github.com/supremegamers/vendor_intel_proprietary_houdini/archive/2f8f088671182e17e67321e098e8411a3972a628.zip
readonly HOUDINI_SHA256=2e82cdc88ddc4d418f7fb861aeebb7c49c83a91b97f57da10510b5e1146a4ed5
readonly -a STOW_PACKAGES=(MangoHud brave cliamp codex environment.d fastfetch fish ghostty git jamesdsp ssh waydroid zed)
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

Restore packages, Flatpaks, dotfiles, Waydroid, system configuration, and Synology automounts on CachyOS.

Options:
  --skip-packages       Skip packages, Flatpaks, Waydroid, and user environment setup
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
        require_command mktemp
        require_command readlink
        require_command sha256sum
        require_command stat
        require_command tar
        require_command zstd
        require_command mountpoint
        require_command unzip
        require_command xdg-mime
        require_command xdg-user-dirs-update
        require_file "$PACMAN_MANIFEST"
        require_file "$AUR_MANIFEST"
        require_file "$FLATPAK_MANIFEST"
        require_file "$HOUDINI_REQUIREMENTS"
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

    require_command curl
    log "Configuring the system-wide Flathub remote"
    sudo flatpak remote-add --system --if-not-exists \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    if ((${#flatpak_apps[@]} > 0)); then
        log "Installing or updating ${#flatpak_apps[@]} Flatpak applications"
        sudo flatpak install --system --or-update flathub "${flatpak_apps[@]}"
    fi
}

sha256_matches() {
    local file=$1
    local expected=$2
    [[ -f $file ]] && [[ $(sha256sum "$file" | awk '{ print $1 }') == "$expected" ]]
}

houdini_installed() {
    local overlay=/var/lib/waydroid/overlay/system
    sha256_matches "$overlay/bin/houdini" 5545833168adcf5e0a79d92cabc21bb1774845d8a2c9cd089641b3adcc317a72 &&
        sha256_matches "$overlay/bin/houdini64" f815ccee39d410c8b334dc1d2239508ff488141968c9f82f4764e7d83322fb0f &&
        sha256_matches "$overlay/lib/libhoudini.so" bfdad39a4b658fdd7e03f2638d6ec314a8983ec7ec2cd55def510d31958d8489 &&
        sha256_matches "$overlay/lib64/libhoudini.so" 5ef64035ec89bca3d5e33b9f3b6556f98f6c11d11957387d403ae4a4d7cc40ec &&
        [[ -d $overlay/lib/arm && -d $overlay/lib64/arm64 ]] &&
        [[ -f $overlay/etc/init/houdini.rc ]] &&
        grep -Fxq 'ro.dalvik.vm.native.bridge = libhoudini.so' /var/lib/waydroid/waydroid.cfg
}

install_libhoudini() {
    require_command git
    require_command uv
    require_command curl
    require_command sha256sum
    require_command stat
    [[ $(uname -m) == x86_64 ]] || die "libhoudini requires an x86_64 host."
    grep -Fxq 'mount_overlays = True' /var/lib/waydroid/waydroid.cfg || die \
        "libhoudini setup requires Waydroid overlay mounts."

    if houdini_installed; then
        log "The pinned libhoudini installation is already present"
        return
    fi

    if systemctl is-active --quiet waydroid-container.service; then
        log "Stopping Waydroid before installing libhoudini"
        if waydroid status | grep -Eq 'Session:[[:space:]]*RUNNING'; then
            waydroid session stop
        fi
        sudo systemctl stop waydroid-container.service
    fi

    local houdini_cache=$HOME/.cache/waydroid-script/downloads/libhoudini.zip
    local download_file
    if ! sha256_matches "$houdini_cache" "$HOUDINI_SHA256"; then
        download_file=$(mktemp)
        log "Downloading the pinned Android 13 libhoudini archive"
        curl -fL --retry 3 -o "$download_file" "$HOUDINI_URL"
        sha256_matches "$download_file" "$HOUDINI_SHA256" || die \
            "Downloaded libhoudini archive does not match the pinned SHA-256."
        install -d -m 0755 "${houdini_cache%/*}"
        install -m 0644 "$download_file" "$houdini_cache"
        rm -- "$download_file"
    fi

    # Upstream extracts to this fixed path. Keep it inaccessible to other users
    # while its root-run installer writes the Android libraries there.
    if [[ -e /tmp/houdiniunpack || -L /tmp/houdiniunpack ]]; then
        [[ ! -L /tmp/houdiniunpack && -d /tmp/houdiniunpack ]] &&
            [[ $(stat -c '%u:%a' /tmp/houdiniunpack) == 0:700 ]] || die \
            "Existing /tmp/houdiniunpack is not a private root-owned directory."
    else
        sudo install -d -m 0700 /tmp/houdiniunpack
    fi

    (
        local checkout_dir
        checkout_dir=$(mktemp -d)
        trap 'rm -rf -- "$checkout_dir"' EXIT
        log "Checking out the pinned Waydroid extras script"
        git clone --quiet --filter=blob:none \
            https://github.com/casualsnek/waydroid_script.git \
            "$checkout_dir/waydroid_script"
        git -C "$checkout_dir/waydroid_script" checkout --quiet --detach \
            "$WAYDROID_SCRIPT_COMMIT"
        [[ $(git -C "$checkout_dir/waydroid_script" rev-parse HEAD) == \
            "$WAYDROID_SCRIPT_COMMIT" ]] || die "Waydroid extras checkout does not match the pinned commit."
        cd "$checkout_dir/waydroid_script"
        log "Installing libhoudini with the pinned script and uv"
        sudo install -d -m 0755 /var/cache/kde-bootstrap-uv
        sudo env XDG_CACHE_HOME="$HOME/.cache" \
            UV_CACHE_DIR=/var/cache/kde-bootstrap-uv \
            PYTHONDONTWRITEBYTECODE=1 \
            uv run --no-project --no-managed-python --no-build \
            --python /usr/bin/python3 \
            --with-requirements "$HOUDINI_REQUIREMENTS" -- \
            python3 main.py install libhoudini
    )
    sudo rm -r -- /tmp/houdiniunpack
    houdini_installed || die "libhoudini installation did not produce the expected files and Waydroid setting."
}

restore_waydroid_data() {
    [[ -f $WAYDROID_DATA_BACKUP ]] || {
        log "No Waydroid data backup found beside bootstrap.sh"
        return
    }

    local state_dir=${XDG_DATA_HOME:-$HOME/.local/share}/waydroid
    local data_dir=$state_dir/data
    local restore_marker=$state_dir/.kde-bootstrap-restored.sha256
    local archive_hash
    archive_hash=$(sha256sum "$WAYDROID_DATA_BACKUP" | awk '{print $1}')

    if [[ -d $data_dir && -f $restore_marker ]] &&
        [[ -n $(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] &&
        [[ $(< "$restore_marker") == "$archive_hash" ]]; then
        log "This Waydroid data backup has already been restored"
        return
    fi

    [[ ! -L $data_dir ]] || die "Waydroid data path is a symlink: $data_dir"
    [[ ! -e $data_dir || -d $data_dir ]] || die "Waydroid data path is not a directory: $data_dir"

    if [[ -d $data_dir ]] &&
        [[ -n $(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        local answer
        if ! ( : < /dev/tty ) 2>/dev/null; then
            warn "Waydroid already has data; no terminal is available to approve restoring the backup."
            return
        fi
        printf 'Waydroid already has user data at %s. Restore the backup and replace it? [y/N] ' "$data_dir" > /dev/tty
        IFS= read -r answer < /dev/tty || answer=
        if [[ ! $answer =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log "Keeping the existing Waydroid data"
            return
        fi
    fi

    log "Checking the Waydroid data backup"
    zstd -t -- "$WAYDROID_DATA_BACKUP"
    # The backup command creates one top-level data directory. Reject any
    # unexpected paths before extracting an archive with elevated privileges.
    local member manifest invalid_member=
    manifest=$(mktemp)
    if ! tar --zstd -tf "$WAYDROID_DATA_BACKUP" > "$manifest"; then
        rm -f -- "$manifest"
        die "Cannot list the Waydroid backup contents."
    fi
    while IFS= read -r member; do
        if [[ $member != data && $member != data/ && $member != data/* ]] ||
            [[ $member == *'/../'* || $member == */.. || $member == */./* ]]; then
            invalid_member=$member
            break
        fi
    done < "$manifest"
    rm -f -- "$manifest"
    [[ -z $invalid_member ]] || die "Unexpected or unsafe path in Waydroid backup: $invalid_member"

    if waydroid status | grep -Eq 'Session:[[:space:]]*RUNNING'; then
        waydroid session stop
    fi
    if systemctl is-active --quiet waydroid-container.service; then
        sudo systemctl stop waydroid-container.service
    fi
    mountpoint -q "$data_dir" && die "Waydroid data is still mounted: $data_dir"

    install -d -m 0700 "$state_dir"
    local staging_dir
    staging_dir=$(mktemp -d "$state_dir/.kde-bootstrap-restore.XXXXXXXX")
    log "Restoring Waydroid data from $WAYDROID_DATA_BACKUP"
    if ! sudo tar --zstd --acls --xattrs --xattrs-include='*' --numeric-owner -xf "$WAYDROID_DATA_BACKUP" -C "$staging_dir"; then
        warn "Restore failed; incomplete files remain at $staging_dir"
        return 1
    fi
    [[ -d $staging_dir/data ]] || die "Waydroid backup has no data directory."
    [[ $(stat -c %u "$staging_dir/data") == "$(id -u)" ]] || die \
        "Waydroid backup belongs to another host UID; data remains at $staging_dir."

    if [[ -d $data_dir ]]; then
        local previous_dir
        previous_dir=$(mktemp -d "$state_dir/.kde-bootstrap-previous.XXXXXXXX")
        rmdir "$previous_dir"
        mv -- "$data_dir" "$previous_dir"
        log "Previous Waydroid data saved at $previous_dir"
    fi
    mv -- "$staging_dir/data" "$data_dir"
    rmdir "$staging_dir"
    printf '%s\n' "$archive_hash" > "$restore_marker"
    log "Waydroid data restored"
}

configure_waydroid() {
    require_command waydroid
    require_command waydroid-nvidia-setup
    require_command curl
    require_command unzip
    require_command sha256sum
    require_command uv
    if [[ ! -r /proc/driver/nvidia/version ]] ||
        ! grep -Fq 'Open Kernel Module' /proc/driver/nvidia/version; then
        die "Waydroid NVIDIA requires the NVIDIA open kernel modules."
    fi
    if [[ ! -r /sys/module/nvidia_drm/parameters/modeset ]] ||
        [[ $(< /sys/module/nvidia_drm/parameters/modeset) != Y ]]; then
        die "Waydroid NVIDIA requires nvidia-drm.modeset=1."
    fi

    local system_image=$WAYDROID_IMAGE_DIR/system.img
    local vendor_image=$WAYDROID_IMAGE_DIR/vendor.img
    local config=/var/lib/waydroid/waydroid.cfg
    local image_cache

    if [[ -f $config ]] &&
        ! grep -Fxq "images_path = $WAYDROID_IMAGE_DIR" "$config"; then
        die "Waydroid already uses another image path. Review $config before changing its images."
    fi

    if ! sha256_matches "$system_image" "$WAYDROID_SYSTEM_SHA256" ||
        ! sha256_matches "$vendor_image" "$WAYDROID_VENDOR_SHA256"; then
        [[ ! -f $config ]] || die \
            "Initialized Waydroid images differ from the pinned March 2026 images; leaving existing installation intact."

        image_cache=$(mktemp -d)
        log "Downloading the pinned Waydroid GAPPS and MAINLINE images"
        curl -fL --retry 3 -o "$image_cache/system.zip" "$WAYDROID_SYSTEM_URL"
        curl -fL --retry 3 -o "$image_cache/vendor.zip" "$WAYDROID_VENDOR_URL"
        unzip -p "$image_cache/system.zip" system.img > "$image_cache/system.img"
        unzip -p "$image_cache/vendor.zip" vendor.img > "$image_cache/vendor.img"
        sha256_matches "$image_cache/system.img" "$WAYDROID_SYSTEM_SHA256" || \
            die "Downloaded Waydroid system image does not match the pinned SHA-256."
        sha256_matches "$image_cache/vendor.img" "$WAYDROID_VENDOR_SHA256" || \
            die "Downloaded Waydroid vendor image does not match the pinned SHA-256."

        sudo install -d -m 0755 "$WAYDROID_IMAGE_DIR"
        sudo install -m 0644 "$image_cache/system.img" "$system_image"
        sudo install -m 0644 "$image_cache/vendor.img" "$vendor_image"
        rm -r -- "$image_cache"
    else
        log "Pinned Waydroid images are already installed"
    fi

    if [[ ! -f $config ]]; then
        log "Initializing Waydroid with the pinned GAPPS image"
        sudo waydroid init -f -s GAPPS
    fi

    # The NVIDIA setup tool checks this default path even when Waydroid uses
    # the documented custom-image directory above.
    if [[ -e /var/lib/waydroid/images/vendor.img ||
          -L /var/lib/waydroid/images/vendor.img ]] &&
        [[ $(readlink -f /var/lib/waydroid/images/vendor.img) != "$vendor_image" ]]; then
        die "Waydroid's default vendor image path already points elsewhere."
    fi
    sudo install -d -m 0755 /var/lib/waydroid/images
    if [[ ! -L /var/lib/waydroid/images/vendor.img ]]; then
        sudo ln -s "$vendor_image" /var/lib/waydroid/images/vendor.img
    fi

    log "Configuring Waydroid NVIDIA acceleration"
    sudo waydroid-nvidia-setup
    install_libhoudini
    restore_waydroid_data
    sudo systemctl enable --now waydroid-container.service
    # It starts at the next login, after the udev rule grants /dev/udmabuf access.
    systemctl --user enable wd-venus.service
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
        "$HOME/.codex" \
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

        if [[ -f /var/lib/waydroid/waydroid.cfg ]] &&
            grep -Fxq "images_path = $WAYDROID_IMAGE_DIR" /var/lib/waydroid/waydroid.cfg &&
            [[ -f $WAYDROID_IMAGE_DIR/system.img ]] &&
            [[ -f $WAYDROID_IMAGE_DIR/vendor.img ]] &&
            houdini_installed &&
            systemctl is-enabled --quiet waydroid-container.service &&
            systemctl --user is-enabled --quiet wd-venus.service; then
            printf '  [ok] Waydroid NVIDIA, libhoudini, and services are configured.\n'
        else
            printf '  [fail] Waydroid NVIDIA, libhoudini, or services are missing.\n'
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
        configure_waydroid
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
