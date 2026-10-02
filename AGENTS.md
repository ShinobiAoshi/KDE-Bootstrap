# Repository guidance for agents

## Purpose

This is a personal disaster-recovery and configuration repository for turning a
fresh **CachyOS No Desktop** installation into the owner's Umbriel + Noctalia
desktop. It is meant to be an auditable source of truth for packages, user
configuration, selected system configuration, and Synology automounts.

This is not a portable, distribution-neutral dotfiles collection. Several files
encode the owner's hardware, network, application, and desktop preferences.
Preserve that intent unless a task explicitly asks to generalize it.

The desired desktop deliberately uses:

- Umbriel as the Wayland compositor
- Noctalia as the shell and Polkit agent
- Noctalia Greeter through greetd
- Xwayland Satellite for X11 applications
- PipeWire/WirePlumber for audio
- GNU Stow for user configuration

It deliberately does not install Niri or SDDM.

## Repository map

- `README.md`: user-facing recovery procedure, desktop overview, and operational
  notes. Keep it synchronized with meaningful behavior changes.
- `bootstrap.sh`: idempotent-oriented Bash orchestration for package installation,
  user setup, Stow deployment, system configuration, service enablement,
  Synology automount installation, and post-install health checks.
- `packages/arch/pacman.txt`: one official repository package name per line.
- `packages/arch/aur.txt`: one AUR/foreign package name per line, installed with
  `paru`.
- `packages/flatpak.txt`: one system-wide Flathub application ID per line.
- `stow/<package>/`: GNU Stow packages whose contents mirror paths below `$HOME`.
  Packages are discovered automatically; adding a directory normally makes it
  deployable without editing `bootstrap.sh`.
- `stow/brave/`: Brave Origin flags and a user launcher that selects the NVIDIA
  VA-API driver without changing other applications' GPU settings.
- `stow/fish/`: Fish startup settings and the `done` hook, copied from the
  former CachyOS Fish package and managed without that package.
- `stow/ssh/`: GitHub-only SSH agent selection through Bitwarden's socket;
  Stow places the config in the real `~/.ssh` directory alongside local files.
- `stow/umbriel/.config/umbriel/`: root include file and focused `conf.d/`
  modules. Noctalia's built-in Umbriel template generates `noctalia.toml`
  locally and maintains its include in the root file; do not track or Stow the
  generated file. If Noctalia regenerates unsupported scratchpad border keys,
  remove those keys from the local file before validating Umbriel.
- `system/`: source copies of files installed to matching system locations. The
  bootstrap currently handles greetd configuration, greetd
  PAM policy, and Noctalia Greeter configuration explicitly.
- `systemd/system/`: NFS mount and automount units copied into
  `/etc/systemd/system` by the bootstrap.
- `.stow-local-ignore`: legacy/local Stow ignore configuration; account for its
  location if changing the Stow directory layout or invocation.
- `.gitignore`: excludes legacy/generated Zsh state.

`stow/vicinae` and the retired `stow/zsh` package are intentionally excluded by
`load_stow_packages`; do not assume every directory below `stow/` is active.

## How the bootstrap behaves

Run the script as the normal desktop user, never as root. It requires CachyOS
and obtains elevated privileges with `sudo` for system changes.

In order, the script:

1. validates the host and requested inputs;
2. installs Pacman, AUR, and system-wide Flatpak packages;
3. retains Fish as the login shell, creates XDG user directories, and sets
   MIME defaults;
4. checks for Stow conflicts, restows discovered user configurations, and
   installs Hydro through Fisher;
5. installs greetd/PAM and greeter configuration;
6. configures mDNS printer discovery and UFW, then enables desktop services;
7. installs and enables the Synology automounts; and
8. reports missing packages, invalid desktop configuration, failed units,
   broken Stow links, inactive mounts, and `.pacnew` files.

The greeter is enabled but not immediately started so it cannot take over the
active TTY. It takes effect after reboot.

## Safety and change rules

- Do **not** run `./bootstrap.sh` merely to test a change. It upgrades and
  installs packages, changes the login shell and MIME defaults, writes under
  `/etc` and `/var`, changes firewall rules, enables/starts services, creates
  mount points, and changes links in the user's home directory. Run it only when
  the user explicitly wants the host provisioned or updated.
- The skip flags narrow deployment but do not turn the script into a pure test;
  the remaining phases and health checks still inspect or mutate the live host.
- `--skip-packages` also skips login-shell, Fish plugin, XDG user-directory, and
  MIME-default setup because those steps depend on the installed package set.
- Never add secrets or mutable application data. SSH private keys, tokens,
  browser profiles, password-vault data, histories, caches, runtime databases,
  and application backups containing credentials belong outside Git.
- Treat the Synology server address, export paths, monitor connector/mode, and
  other hardware- or network-specific values as intentional personal settings.
- Preserve ownership and modes when changing installed system files. In
  particular, the greeter state directory and config have restricted
  `greeter:greeter` ownership/modes in `bootstrap.sh`.
- Keep operations rerunnable. Package installs use `--needed`, Stow uses
  `--restow`, firewall/service changes should tolerate an already-configured
  host, and file installs should deterministically replace their managed target.
- Do not start greetd during bootstrap development or validation.
- Check `git status` and existing diffs before editing. This is a live personal
  repository and unrelated working-tree changes may be in progress.

## Editing conventions

- Keep `bootstrap.sh` compatible with Bash and its current strict mode:
  `set -Eeuo pipefail`.
- Quote path and array expansions, prefer arrays for command arguments, and use
  the existing `log`, `warn`, `die`, `require_command`, and `require_file`
  helpers.
- Add a preflight requirement for any new external command or required source
  file used by a phase.
- Make new phases respect the relevant `--skip-*` option and extend the final
  health report when there is a useful non-destructive verification.
- Package manifests are newline-delimited. Blank lines and lines whose first
  field begins with `#` are ignored; only the first field is treated as the
  package/application name.
- Stow package contents must reproduce the exact desired path relative to
  `$HOME`. Account for applications that need real directories containing a
  mixture of managed and unmanaged files; `deploy_dotfiles` pre-creates several
  such directories.
- If adding another system-managed file, add an explicit source/target pair,
  validate it in `preflight`, install it with an intentional owner and mode, and
  document it here and in `README.md` when user-visible.
- After major Umbriel updates, compare its checked-in configuration modules with the
  packaged `/usr/share/umbriel/config.toml`; `umbriel-git` may change format.

## Useful commands

Safe repository inspection and static validation:

```bash
git status --short
git diff --check
bash -n bootstrap.sh
shellcheck bootstrap.sh                 # when ShellCheck is installed
./bootstrap.sh --help
```

Inspect manifests as the bootstrap reads them:

```bash
awk 'NF && $1 !~ /^#/ { print $1 }' packages/arch/pacman.txt
awk 'NF && $1 !~ /^#/ { print $1 }' packages/arch/aur.txt
awk 'NF && $1 !~ /^#/ { print $1 }' packages/flatpak.txt
```

Preview active Stow packages against the live home directory (read-only, but
host-dependent):

```bash
stow --simulate --verbose=1 --dir="$PWD/stow" --target="$HOME" --restow \
  $(find stow -mindepth 1 -maxdepth 1 -type d ! -name vicinae -printf '%f\n' | sort)
```

Desktop-specific validation, when the corresponding programs are installed:

```bash
umbriel validate
noctalia config validate "$HOME/.config/noctalia/config.toml"
```

These validate the deployed/live user configuration. If a checked-in config was
edited but has not been restowed, first determine whether its live target is a
symlink to this repository; do not silently deploy it just to run validation.

Operational commands for an explicitly requested recovery or deployment:

```bash
./bootstrap.sh
./bootstrap.sh --skip-packages
./bootstrap.sh --skip-dotfiles
./bootstrap.sh --skip-system-config
./bootstrap.sh --skip-mounts
```

After a real bootstrap, review its health report, resolve warnings, and reboot
when prompted so greetd and the Umbriel session take effect.

## Completion checklist

Before handing off a change:

1. inspect the final diff and ensure unrelated user changes were preserved;
2. run `git diff --check` and `bash -n bootstrap.sh` for any relevant change;
3. run ShellCheck and format/config validators when available and applicable;
4. confirm package entries are in the correct manifest and Stow files have the
   correct home-relative path;
5. update `README.md` and this file if the workflow, layout, supported desktop,
   or recovery behavior changed; and
6. report any checks that could not be run without altering the live machine.
