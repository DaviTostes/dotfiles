if status is-interactive
  eval "$(zoxide init fish)"
  alias cloudflared='~/.cloudflared/cloudflared'

  set -gx BUN_INSTALL "$HOME/.bun"
  set -gx JAVA_HOME "/usr/lib/jvm/java-17-openjdk"
  set -x SSH_AUTH_SOCK $XDG_RUNTIME_DIR/ssh-agent.socket
  set -gx DOTNET_ROOT /usr/share/dotnet

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

  alias omm='omm --editor nvim'

  alias t='tmux'
  alias tn='tmux new'
  alias ta='tmux attach -t'
  alias tk='tmux kill-session -t'
  alias tl='tmux ls'

  alias g='git'
  alias gch='git checkout'
  alias gs='git status'
  alias gd='git diff'
  alias gb='git branch'
  alias ga='git add'
  alias gaa='git add .'
  alias gap='git add -p .'
  alias gc='git commit -m'
  alias gpl='git pull'
  alias gps='git push'
  alias grs='git restore --staged -p .'

  alias del='rm -rf'
  alias clear='wipe --char-pattern circle --color-pattern circle --colors dark-blue --char-segments 1 --color-segments 1 --char-invert false --color-invert false --duration 1200'
  alias ll='ls -lah'
  alias d='dcrun'
  alias task go-task
  alias rg='ripgrep'

  fastfetch

  keychain --quiet --nogui ~/.ssh/moussa
  keychain --quiet --nogui ~/.ssh/scalefy
  source ~/.keychain/(cat /etc/hostname)-fish
end


if test -z "$WAYLAND_DISPLAY"; and test "$XDG_VTNR" = "1"
    exec start-hyprland
end
