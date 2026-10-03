# Repository guidance for agents

This is a personal disaster-recovery repository for a fresh **CachyOS KDE** installation. The installer owns Plasma settings, the KDE portal, KWallet PAM, and Plasma Login Manager. This repository supplies personal applications, Fish, gaming tools, printer discovery, Flatpaks, user configuration, and Synology automounts. Umbriel and Noctalia belong to the separate `.dotfiles` repository.

## Map and behavior

- `bootstrap.sh` is a Bash script with strict mode and four skip flags. Before mutation it checks the CachyOS KDE baseline, display-manager owner, commands needed by selected phases, and Synology units with `systemd-analyze verify` when mounts are selected. It checks tools supplied by its package phase immediately after installation, then deploys explicit Stow packages, configures the user, enables shared services and printer discovery, installs Synology units, and runs health checks.
- `packages/arch/pacman.txt` contains official-repository additions beyond the CachyOS KDE installer profile; `aur.txt` contains AUR/foreign packages, including cliamp; `packages/flatpak.txt` contains system-wide Flatpaks. Manifest parsing uses the first field of non-comment lines.
- `stow/` mirrors paths below `$HOME`. The `STOW_PACKAGES` array in `bootstrap.sh` is the sole active list. Keep `.ssh` and `.local/share/applications` as real directories for managed files alongside local files. The cliamp desktop file is the audio MIME handler.
- `stow/codex/.codex/` manages Codex's `AGENTS.md` and `config.toml`. Keep `~/.codex` as a real directory for local credentials, history, caches, and runtime data.
- `systemd/system/` has personal Synology NFS mount and automount units. Keep their network details unless the owner asks to change them.

## Change rules

- Do not run `./bootstrap.sh` to test a repository change. It upgrades packages, changes the login shell and MIME defaults, enables services, writes `/etc` units, and deploys home links. Skip flags are not a dry-run mode.
- Do not install another login manager, recopy `/etc/skel`, replace the KDE portal, or add a full Plasma package group. Preserve installer Plasma appearance and account defaults.
- Do not add secrets, SSH keys, browser profiles, password vault data, caches, or mutable application backups.
- Keep operations rerunnable: `pacman --needed`, Stow `--restow`, deterministic system file installation, and tolerant service configuration.
- Use `log`, `warn`, `die`, `require_command`, and `require_file` helpers. Quote paths and arrays. Add preflight checks for new required files and commands.
- Review any changed AUR PKGBUILD and source before installation, especially cliamp. Keep the configured Git remote in recovery instructions.

## Static verification

Run `bash -n bootstrap.sh`, `shellcheck bootstrap.sh`, `git diff --check`, and `desktop-file-validate` for managed desktop files. Compare manifests with the current [CachyOS KDE installer profile](https://github.com/CachyOS/New-Cli-Installer/blob/master/net-profiles.toml). Run Stow `--simulate` against an isolated temporary home and inspect links, then search active files for retired desktop integration. Test all skip flags through mocks or in a disposable KDE installation; never run the live bootstrap for that purpose. Only a disposable fresh install can verify full idempotence, KWallet secrets, portal dialogs, printer discovery, audio playback, and Synology mounts.
