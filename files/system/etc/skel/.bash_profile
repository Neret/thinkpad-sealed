if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash --shims)"
fi

if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
