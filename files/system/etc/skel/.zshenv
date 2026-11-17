typeset -U path PATH

if (( $+commands[micro] )); then
    export EDITOR=micro
else
    export EDITOR=nano
fi
export VISUAL="$EDITOR"

if (( $+commands[podman] )) && [[ -n "$XDG_RUNTIME_DIR" ]]; then
    export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
fi
export OLLAMA_API_BASE='http://127.0.0.1:11434'
