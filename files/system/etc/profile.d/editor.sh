if command -v micro >/dev/null 2>&1; then
    EDITOR=micro
else
    EDITOR=nano
fi
VISUAL="$EDITOR"
export EDITOR VISUAL
