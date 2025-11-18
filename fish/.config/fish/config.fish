if status is-interactive
  eval "$(zoxide init fish)"
  alias cloudflared='~/.cloudflared/cloudflared'

  set -gx BUN_INSTALL "$HOME/.bun"
  set -gx JAVA_HOME "/usr/lib/jvm/java-17-openjdk"
  set -x SSH_AUTH_SOCK $XDG_RUNTIME_DIR/ssh-agent.socket

  set -gx PATH \
  $HOME/flutter/bin \
  $PATH \
  $HOME/.config/composer/vendor/bin \
  $HOME/.local/bin \
  $HOME/go/bin \
  $BUN_INSTALL/bin \
  $JAVA_HOME/bin \
  $HOME/.ghcup/bin \
  $HOME/.pub-cache/bin \
  $HOME/.cargo/bin

  # Aliases
  alias v='nvim'

  alias t='tmux'
  alias tma='tmux attach -t'
  alias tmk='tmux kill-session -t'
  alias tml='tmux ls'

  alias g='git'
  alias gs='git status'
  alias gd='git diff'
  alias ga='git add'
  alias gaa='git add .'
  alias gc='git commit -m'
  alias gpl='git pull'
  alias gps='git push'

  alias del='rm -rf'

  alias task go-task
end

if test -z "$WAYLAND_DISPLAY"; and test "$XDG_VTNR" = "1"
    exec Hyprland
end

fish_add_path /home/toast/.spicetify
