# CachyOS bootstrap

This repository turns a current CachyOS **No Desktop** installation into an
Umbriel + Noctalia desktop. It installs the desktop stack and personal
applications, deploys their configuration, configures Noctalia Greeter through
greetd, and restores the Synology automounts.

The desktop deliberately contains neither Niri nor SDDM.

Fish is retained as the login shell. The bootstrap installs `fish`, selects it
if necessary, and deploys the Fish configuration from `stow/fish`. That
configuration includes the settings and `done` notification hook previously
provided by `cachyos-fish-config`, so the package is no longer required. The
bootstrap installs Fisher and uses it to add Hydro as the user prompt. The
legacy `stow/zsh` package is kept for the existing machine but is excluded
from new Stow deployments.

## Fresh-install recovery

1. Install CachyOS with **No Desktop** selected and establish a network
   connection. Let the installer configure the correct kernel, firmware, GPU
   driver, bootloader, NetworkManager, and other base-system components.
2. Install Git if it is not already available:

   ```bash
   sudo pacman -S --needed git
   ```

3. Clone this repository:

   ```bash
   git clone git@github.com:ShinobiAoshi/dotfiles-linux.git ~/.dotfiles
   cd ~/.dotfiles
   ```

   A fresh installation may need its GitHub SSH credentials restored before an
   SSH clone will work. An HTTPS clone can be used until those credentials are
   available. The deployed SSH configuration uses Bitwarden's agent for GitHub
   through `~/.bitwarden-ssh-agent.sock` without changing the agent for other
   hosts.

4. Restore credentials and other secrets from encrypted storage. Do not add SSH
   private keys, application tokens, browser profiles, or password-vault data to
   this repository.
5. Review the package manifests and system files for hardware- or network-specific
   values, then run:

   ```bash
   ./bootstrap.sh
   ```

6. Review the post-install health report and resolve any failed units, missing
   packages, Stow conflicts, or `.pacnew` files it reports.
7. Restore application-native backups that are intentionally not kept in Git,
   such as OpenDeck settings containing credentials.
8. Reboot. greetd starts Noctalia Greeter, with Umbriel selected as the default
   Wayland session. Noctalia starts automatically inside Umbriel.
9. Verify the Synology mounts and hardware-specific settings. Configure monitor
   layout in `~/.config/umbriel/config.toml` after checking connector names with
   `umbriel outputs`.

## Desktop stack

The manifests explicitly provide the pieces that the CachyOS No Desktop profile
does not install:

- `umbriel-git` and `xdg-desktop-portal-umbriel-git` from the AUR
- Noctalia v5, Noctalia Greeter, greetd, and the Umbriel Wayland session
- Xwayland Satellite for X11 applications
- PipeWire, WirePlumber, ALSA/Pulse compatibility, and GStreamer integration
- the GTK portal fallback required for file choosers and non-capture portals
- GNOME Keyring with greetd PAM integration for the Secret Service
- Polkit through Noctalia's built-in authentication agent
- Bluetooth, battery, removable-media, GVfs, and XDG integration
- network-printer discovery, printing, firmware updates, desktop notifications,
  and media thumbnails
- fonts, cursor/theme tools, CachyOS wallpapers, Nautilus, and Ghostty
- Fish with the repository-managed configuration, Fisher, and Hydro

No hardware-specific graphics driver is listed here. CachyOS installs that as
part of the base system and `chwd` hardware detection.

Umbriel is currently installed from its development AUR package because there
is no stable Arch/CachyOS repository package. Its configuration format can
change, so compare `stow/umbriel/.config/umbriel/` with the packaged
`/usr/share/umbriel/config.toml` after major Umbriel updates.

## Desktop configuration

- `stow/fish/.config/fish/` contains the Fish startup settings and the `done`
  notification hook; neither file sources `cachyos-fish-config`.
- `stow/umbriel/.config/umbriel/config.toml` includes focused files under
  `conf.d/`: session and environment, outputs and workspaces, input, appearance,
  layout, keybinds, and window/layer rules. `Super+Return` opens Ghostty and
  `Super+Space` opens the launcher. Steam game windows matching `steam_app_<id>`
  open on the persistent `Games` workspace. Edit the corresponding module for
  each setting.
- `stow/noctalia/.config/noctalia/config.toml` enables Noctalia's Polkit agent,
  top bar, dock, wallpaper-derived dark theme, desktop services, and explicitly
  disables automatic lock, display-off, and suspend behavior. Noctalia's built-in
  Umbriel template renders `~/.config/umbriel/noctalia.toml` locally and adds it
  to Umbriel's include list. The rendered file stays outside Stow and Git.
  The installed Umbriel build rejects generated `scratchpad_focused` and
  `scratchpad_unfocused` border keys; remove them if Noctalia recreates them.
- `system/etc/greetd/config.toml` launches Noctalia Greeter.
- `system/var/lib/noctalia-greeter/greeter.toml` selects Umbriel without pinning
  a machine-specific username or display layout, and selects the Synced color
  scheme for Noctalia appearance sync.

The bootstrap enables greetd and the supporting desktop services but does not
start the greeter immediately, which avoids taking over the active TTY. The
graphical target and greeter take effect on the next reboot.
If `display-manager.service` already points to another display manager, the
bootstrap stops before making changes and asks you to disable that manager.

Network-printer discovery is configured automatically through Avahi, CUPS,
`nss-mdns`, and an inbound UFW rule for mDNS on UDP port 5353. A driverless
AirPrint or IPP Everywhere printer on the local network can appear directly in
print dialogs as a temporary CUPS queue. Configure the printer itself for the
network and enable Bonjour, mDNS, AirPrint, or IPP; use `system-config-printer`
only when a permanent queue or custom defaults are desired.

## Bootstrap options

Run `./bootstrap.sh --help` for the current options. Individual phases can be
skipped when rerunning the script:

```text
--skip-packages
--skip-dotfiles
--skip-system-config
--skip-mounts
```

The script is intended to be run as the normal desktop user, not as root. It is
safe to rerun: package installation uses `--needed`, Stow uses `--restow`, and
system configuration is installed from the copies in this repository.
`--skip-packages` also skips the login-shell, Fish plugin, XDG user-directory,
and MIME default setup that normally follows package installation.
The configured defaults use Nautilus for directories, Brave Origin for web links and
HTML, Papers for PDFs, Loupe for images, Amberol for audio, Celluloid for video,
qBittorrent for torrents and magnet links, File Roller for archives, and Zed for
plain text.

Brave Origin is installed from CachyOS as `brave-origin-bin`, alongside
`libva-nvidia-driver` for the RTX 4090. Its
`~/.config/brave-origin-flags.conf` requests NVIDIA VA-API video decoding. A
Stow-managed Brave Origin launcher sets `LIBVA_DRIVER_NAME=nvidia` only for the
browser and replaces the packaged launcher for desktop and web-link launches.
For terminal launches, use `LIBVA_DRIVER_NAME=nvidia brave-origin`. Verify actual
decoding while playing video in Brave Origin's DevTools Media panel
(`VaapiVideoDecoder`) and with the NVIDIA decoder engine; flags alone cannot
confirm acceleration.

## Repository layout

- `packages/` contains Pacman, AUR/foreign, and Flatpak manifests.
- `stow/` contains GNU Stow packages discovered by directory; `vicinae` is kept
  in the tree but intentionally excluded from deployment, as is the retired
  `zsh` package.
- `system/` contains files installed outside the home directory.
- `systemd/system/` contains the Synology mount and automount units.
- `bootstrap.sh` performs installation, deployment, and final health checks.

Generated caches, histories, runtime databases, credentials, and machine-specific
display state should remain outside this repository.
