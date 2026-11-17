# ~/.zshrc

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt AUTO_CD
setopt INTERACTIVE_COMMENTS

autoload -Uz compinit

if (( EUID == 0 )); then
    compinit -u
else
    compinit
fi

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

if (( $+commands[dircolors] )) && [[ -r "$HOME/.dircolors" ]]; then
    eval "$(dircolors -b "$HOME/.dircolors")"
    zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
fi

if (( $+commands[eza] )); then
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -l --icons=auto --git --group-directories-first'
    alias la='eza -la --icons=auto --git --group-directories-first'
    alias lt='eza --tree --level=2 --icons=auto'
    alias l1='eza -1'

    function l.() {
        local -a entries=( .*(N) )
        (( ${#entries} )) || return 0
        eza -d -- "${entries[@]}"
    }
fi

if (( $+commands[bat] )); then
    alias c='bat --style=plain --paging=never'
    alias cata='bat'
fi

if (( $+commands[ug] )); then
    alias ug='ug'
    alias uge='ug -E'
    alias ugf='ug -F'
    alias ugz='ug -z'
    alias ugze='ug -zE'
    alias ugzf='ug -zF'
fi

if (( ! $+commands[fd] && $+commands[fdfind] )); then
    alias fd='fdfind'
fi

if (( $+commands[rg] )); then
    alias rgh='rg --smart-case --hidden --glob "!.git"'
fi

if (( $+commands[xdg-open] )); then
    alias open='xdg-open >/dev/null'
fi

if (( $+commands[zoxide] )); then
    eval "$(zoxide init zsh)"
fi

if (( $+commands[fzf] )); then
    source <(fzf --zsh)
fi

_zsh_load_plugin() {
    local plugin="$1"
    local dir

    for dir in /usr/share /run/host/usr/share; do
        if [[ -r "$dir/$plugin/$plugin.zsh" ]]; then
            source "$dir/$plugin/$plugin.zsh"
            return 0
        fi
    done

    return 1
}

_zsh_load_plugin zsh-autosuggestions
_zsh_load_plugin zsh-syntax-highlighting
unset -f _zsh_load_plugin

apue() {
    if (( $# != 1 )); then
        print -u2 'uso: apue <file.c>'
        return 2
    fi

    local src="$1"
    local out="${src%.c}"

    gcc -ansi \
        -I"$HOME/Progetti/apue.3e/include" \
        -Wall \
        -DLINUX \
        -D_GNU_SOURCE \
        "$src" \
        -o "$out" \
        -L"$HOME/Progetti/apue.3e/lib" \
        -lapue \
        -pthread
}

if (( $+commands[mise] )); then
    if [[ "$MISE_ZSH_AUTO_ACTIVATE" != '0' ]]; then
        eval "$(mise activate zsh)"
    fi
fi

if (( $+commands[starship] )); then
    eval "$(starship init zsh)"
else
    if [[ -f /run/.containerenv && -f /etc/os-release ]]; then
        . /etc/os-release
        PS1="%F{green}%n@$ID%f %B%F{blue}%~%f%b %# "
    else
        PS1="%F{green}%n@fedora%f %B%F{blue}%~%f%b %# "
    fi
fi
