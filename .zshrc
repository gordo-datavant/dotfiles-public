WORKON_HOME=~/.virtualenvs/
ZSH=$HOME/.oh-my-zsh
ZSH_THEME="af-magic"
DISABLE_LS_COLORS="true"
COMPLETION_WAITING_DOTS="true"

export PYTHONDONTWRITEBYTECODE=1
export VIRTUALENVWRAPPER_PYTHON=/opt/homebrew/bin/python3

plugins=(git virtualenvwrapper autojump battery)

export LC_CTYPE=en_US.UTF-8
export EDITOR="vim"
setopt AUTO_CD


export ZSH_DISABLE_COMPFIX="true"
source $ZSH/oh-my-zsh.sh

export HOMEBREW_CASK_OPTS="--appdir=~/Applications"
export PATH="/opt/homebrew/sbin:$PATH"
export PATH=$HOME/.local/bin:$HOME/Bin:$PATH
export PATH="/opt/homebrew/opt/python@3.13/bin:$PATH"

[[ -s $HOME/.tmuxinator/scripts/tmuxinator ]] && source $HOME/.tmuxinator/scripts/tmuxinator
export TERM=xterm-256color
[ -n "$TMUX" ] && export TERM=screen-256color

source $(which uv-virtualenvwrapper.sh)

alias x='exit'
alias tkill='tmux kill-session -t '
alias tlist='tmux ls'

alias ssh='TERM=xterm ssh'

alias t='task'

alias payload='dump_payload(){echo -e "import base64,json,sys,zlib\ntry:\n  print(json.dumps(json.loads(zlib.decompress(base64.b64decode(\"$1\"))), indent=4, sort_keys=True))\nexcept zlib.error:\n  print(json.dumps(json.loads(zlib.decompress(base64.b64decode(\"$1\"), 16|zlib.MAX_WBITS)), indent=4, sort_keys=True))" | python3};dump_payload'


FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
autoload -Uz compinit
compinit -i

zstyle ':completion:*' verbose yes
zstyle ':completion:*:descriptions' format '%U%B%d%b%u'
zstyle ':completion:*' group-name ''
autoload colors && colors

KEYTIMEOUT=1

alias tasks='git grep -EIn "todo|fixme"'
alias releases='git branch -a --sort=-committerdate| grep "remotes/origin/release-" | head'
alias changes='git log --format="%C(auto) %h %s" $(releases|head -n 2|tr -d " "|tail -n 1)..$(releases|head -n 1|tr -d " ")'

export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

alias pp='python -m json.tool'

alias pip_upgrade_all="(echo pip; pip freeze --local | awk 'BEGIN{FS=\"==\"}{print $1}') | xargs pip install -U"
export PATH="~/.pyenv/shims:${PATH}"
export PYENV_SHELL=zsh
source /opt/homebrew/Cellar/pyenv/2.6.26/completions/pyenv.zsh

command pyenv rehash 2>/dev/null
pyenv() {
  local command
  command="${1:-}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command" in
  rehash|shell|virtualenvwrapper|virtualenvwrapper_lazy)
    eval "$(pyenv "sh-$command" "$@")";;
  *)
    command pyenv "$command" "$@";;
  esac
}

ulimit -S -n 1024

# scala / sbt / openjdk 8 things
#export PATH="/usr/local/opt/openjdk@8/bin:$PATH"
#export PATH="/usr/local/opt/sbt@0.13/bin:$PATH"
#export CPPFLAGS="-I/usr/local/opt/openjdk@8/include"

alias glg='git log --graph --stat'

alias vd="vd --motd-url=None"

export CONFLUENCE_BASE_URL="https://datavant.atlassian.net"
export GDRIVE_ACCOUNT="thomas.lowrey@datavant.com"
export JIRA_BASE_URL="https://datavant.atlassian.net"
export JIRA_EMAIL="thomas.lowrey@datavant.com"
[[ -z "$JIRA_API_TOKEN" ]] && export JIRA_API_TOKEN=$(pass show jira 2>/dev/null)
export SLACK_WORKSPACE="datavant"
[[ -z "$SLACK_TOKEN" ]]    && export SLACK_TOKEN=$(pass show slack/token 2>/dev/null)
[[ -z "$SLACK_COOKIE" ]]   && export SLACK_COOKIE=$(pass show slack/cookie 2>/dev/null)

# GPG + YubiKey
export GPG_TTY=$(tty)
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
