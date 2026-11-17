[ -f /etc/bashrc ] && . /etc/bashrc

if command -v micro >/dev/null 2>&1; then
    export EDITOR=micro
else
    export EDITOR=nano
fi
export VISUAL="$EDITOR"

if command -v podman >/dev/null 2>&1 && [ -n "$XDG_RUNTIME_DIR" ]; then
    export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
fi
export OLLAMA_API_BASE='http://127.0.0.1:11434'

[[ $- != *i* ]] && return

command -v sudo >/dev/null 2>&1 && alias sudo='sudo '

if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -l --icons=auto --git --group-directories-first'
    alias la='eza -la --icons=auto --git --group-directories-first'
    alias lt='eza --tree --level=2 --icons=auto'
    alias l1='eza -1'

    l.() {
        local -a entries
        shopt -s nullglob
        entries=( .[!.]* ..?* )
        shopt -u nullglob
        (( ${#entries[@]} )) || return 0
        eza -d -- "${entries[@]}"
    }
fi

if command -v bat >/dev/null 2>&1; then
    alias c='bat --style=plain --paging=never'
    alias cata='bat'
fi

if command -v ug >/dev/null 2>&1; then
    alias uge='ug -E'
    alias ugf='ug -F'
    alias ugz='ug -z'
    alias ugze='ug -zE'
    alias ugzf='ug -zF'
fi

if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

command -v rg >/dev/null 2>&1 && alias rgh='rg --smart-case --hidden --glob "!.git"'
command -v xdg-open >/dev/null 2>&1 && alias open='xdg-open >/dev/null'

if command -v dircolors >/dev/null 2>&1 && [ -r "$HOME/.dircolors" ]; then
    eval "$(dircolors -b "$HOME/.dircolors")"
fi

if command -v zoxide >/dev/null 2>&1; then eval "$(zoxide init bash)"; fi
if command -v fzf >/dev/null 2>&1; then eval "$(fzf --bash)"; fi
if command -v mise >/dev/null 2>&1; then eval "$(mise activate bash)"; fi

if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
else
    PS1='\[\e[32m\]\u@\h\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] \$ '
fi
