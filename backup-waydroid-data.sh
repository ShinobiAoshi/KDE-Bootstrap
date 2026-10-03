#!/usr/bin/env bash

set -Eeuo pipefail

backup=${1:-$HOME/Downloads/waydroid-data.tar.zst}
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}/waydroid/data

[[ $EUID -ne 0 ]] || { printf 'Run as your normal user.\n' >&2; exit 1; }
[[ -d $data_dir && ! -L $data_dir ]] || { printf 'Waydroid data directory is missing or is a symlink: %s\n' "$data_dir" >&2; exit 1; }
[[ ! -e $backup && ! -L $backup ]] || { printf 'Backup already exists: %s\n' "$backup" >&2; exit 1; }
for command in sudo waydroid systemctl tar zstd mktemp mountpoint; do
    command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 1; }
done
sudo -v

if waydroid status | grep -Eq 'Session:[[:space:]]*RUNNING'; then
    waydroid session stop
fi
if systemctl is-active --quiet waydroid-container.service; then
    sudo systemctl stop waydroid-container.service
fi
if mountpoint -q "$data_dir"; then
    printf 'Waydroid data is still mounted: %s\n' "$data_dir" >&2
    exit 1
fi

backup_dir=$(dirname -- "$backup")
[[ -d $backup_dir ]] || { printf 'Backup destination directory does not exist: %s\n' "$backup_dir" >&2; exit 1; }
umask 077
temporary=$(mktemp "$backup_dir/.waydroid-data.XXXXXXXX.tar.zst")
trap 'rm -f -- "$temporary"' EXIT

printf 'Backing up %s to %s\n' "$data_dir" "$backup"
sudo tar --acls --xattrs --numeric-owner -cf - -C "$(dirname -- "$data_dir")" data |
    zstd -T0 -q > "$temporary"
zstd -t -q -- "$temporary"
[[ ! -e $backup && ! -L $backup ]] || { printf 'Backup appeared while writing: %s\n' "$backup" >&2; exit 1; }
mv -- "$temporary" "$backup"
trap - EXIT
printf 'Backup complete: %s\n' "$backup"
printf 'Copy this file beside bootstrap.sh on the new machine. Keep it private: it contains Android app and account data.\n'
