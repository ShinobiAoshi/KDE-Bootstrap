# Linux interactive zsh configuration

export PATH="$HOME/.local/bin:$PATH"

# Zinit installation
#
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

if [[ ! -d "${ZINIT_HOME}" ]]; then
  mkdir -p "$(dirname "${ZINIT_HOME}")"
  git clone "https://github.com/zdharma-continuum/zinit.git" "${ZINIT_HOME}"
elif [[ ! -d "${ZINIT_HOME}/.git" ]]; then
  git clone "https://github.com/zdharma-continuum/zinit.git" "${ZINIT_HOME}"
fi

source "${ZINIT_HOME}/zinit.zsh"

# Fastfetch - show system info on interactive shell start
if [[ -o interactive ]] && command -v fastfetch &>/dev/null; then
  fastfetch
fi

# Load OMZ libs we need (not the whole thing)
zinit snippet OMZL::git.zsh
zinit snippet OMZL::directories.zsh
zinit snippet OMZL::theme-and-appearance.zsh
zinit snippet OMZL::async_prompt.zsh

# eza config - must be set BEFORE loading the plugin
zstyle ':omz:plugins:eza' 'dirs-first' yes
zstyle ':omz:plugins:eza' 'git-status' yes
zstyle ':omz:plugins:eza' 'header' yes
zstyle ':omz:plugins:eza' 'icons' yes

# Load OMZ plugins
zinit snippet OMZP::git
zinit snippet OMZP::direnv
zinit snippet OMZP::eza

# Zsh plugins
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-autosuggestions
zinit light Aloxaf/fzf-tab

# Load completions efficiently (after prompt is ready)
autoload -Uz compinit
compinit

# Initialize tools
command -v starship &>/dev/null && eval "$(starship init zsh)"
command -v zoxide  &>/dev/null && eval "$(zoxide init zsh)"

# History setup
HISTFILE=$ZDOTDIR/.zhistory
SAVEHIST=10000
HISTSIZE=10000
setopt share_history
setopt hist_expire_dups_first
setopt hist_ignore_dups
setopt hist_verify

# Aliases
alias zed="zeditor"
alias zshconfig="zeditor ~/.zshrc"

# Atuin - synced shell history (load last)
if command -v atuin &>/dev/null; then
  eval "$(atuin init zsh)"
fi
