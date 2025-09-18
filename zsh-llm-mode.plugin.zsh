# zsh-llm-mode.plugin.zsh
# Interactive LLM scratchpad for Zsh
# Toggle with Ctrl-Q, multiline with Ctrl-J, cancel with Esc/Ctrl-C

# Require ZSH_LLM_MODE_CMD
if [[ -z ${ZSH_LLM_MODE_CMD:-} ]]; then
  print -P "%F{red}[zsh-llm-mode]%f ERROR: ZSH_LLM_MODE_CMD is not set."
  print "Example:"
  print "  export ZSH_LLM_MODE_CMD='ollama run qwen3:8b --think=false --hidethinking'"
  return 1
fi

# --- Globals ---
typeset -g LLM_MODE=0
typeset -g LLM_SPINNER_PID=0
typeset -g llm_BUFFER=""
typeset -g shell_BUFFER=""
typeset -g DEFAULT_PROMPT=${PROMPT:-'➜ '}

# --- Buffering detection ---
if command -v stdbuf >/dev/null; then
  _ZSH_LLM_STDBUF=(stdbuf -oL -eL)
elif command -v gstdbuf >/dev/null; then
  _ZSH_LLM_STDBUF=(gstdbuf -oL -eL)
else
  _ZSH_LLM_STDBUF=()  # fallback: no streaming, full output at once
fi

# --- Helpers ---
function llm-update-prompt {
  if (( LLM_MODE )); then
    PROMPT=$'%F{cyan}LLM>%f (Enter=send, ^Q=switch, ^J=new line, Esc=cancel)\n➜ '
  else
    PROMPT=$DEFAULT_PROMPT
  fi
}

# --- Widgets ---
# Insert newline in LLM mode (Ctrl-J)
function llm-newline {
  if (( LLM_MODE )); then
    LBUFFER+=$'\n'
    zle -R
  else
    zle self-insert-unmeta
  fi
}
zle -N llm-newline
bindkey '^J' llm-newline

# Toggle between shell <-> LLM buffer (Ctrl-Q)
function llm-toggle {
  if (( LLM_MODE )); then
    llm_BUFFER=$BUFFER
    BUFFER=$shell_BUFFER
    LLM_MODE=0
  else
    shell_BUFFER=$BUFFER
    BUFFER=${shell_BUFFER:-$llm_BUFFER}
    LLM_MODE=1
  fi
  llm-update-prompt
  zle reset-prompt
  zle redisplay
}
zle -N llm-toggle
bindkey '^Q' llm-toggle

# Cancel LLM input (Esc)
function llm-cancel {
  if (( LLM_MODE )); then
    llm_BUFFER=$BUFFER
    BUFFER=$shell_BUFFER
    LLM_MODE=0
    llm-update-prompt
    zle reset-prompt
    zle redisplay
  else
    zle send-break
  fi
}
zle -N llm-cancel
bindkey '^[' llm-cancel

# Accept line → send to LLM
function llm-accept-line {
  setopt localoptions localtraps no_notify no_monitor
  if (( LLM_MODE )); then
    local input=$BUFFER
    BUFFER=""
    llm_BUFFER=""

    # Temporarily tweak prompt to be empty
    PROMPT=""
    zle reset-prompt
    zle redisplay
    print -P "%F{cyan}LLM>%f $input"

    # Spinner
    local spin_chars='|/-\'
    local i=0
    {
      while true; do
        i=$(( (i + 1) % 4 ))
        printf "\r%s" "${spin_chars:$i:1}"
        sleep 0.1
      done
    } >/dev/tty 2>/dev/null &
    LLM_SPINNER_PID=$!

    # Run backend
    local -a backend_cmd
    backend_cmd=(${=ZSH_LLM_MODE_CMD})
    local first=1

    if [[ -n $_ZSH_LLM_STDBUF ]]; then
      # Stream mode
      exec 3< <(echo "$input" | "${_ZSH_LLM_STDBUF[@]}" "${backend_cmd[@]}" 2>&1)
      local first=1
      while IFS= read -r line <&3; do
        if (( first )); then
          [[ $LLM_SPINNER_PID -gt 0 ]] && kill $LLM_SPINNER_PID 2>/dev/null
          wait $LLM_SPINNER_PID 2>/dev/null
          LLM_SPINNER_PID=0
          printf "\r"
          print -P "%F{green}LLM:%f"
          first=0
        fi
        print -- "$line"
      done
      exec 3<&-
    else
      # Fallback: capture all output, print once
      local output
      output=$(echo "$input" | "${backend_cmd[@]}" 2>&1)
      [[ $LLM_SPINNER_PID -gt 0 ]] && kill $LLM_SPINNER_PID 2>/dev/null
      wait $LLM_SPINNER_PID 2>/dev/null
      LLM_SPINNER_PID=0
      printf "\r"
      print -P "%F{green}LLM:%f"
      print -- "$output"
    fi

    [[ $LLM_SPINNER_PID -gt 0 ]] && kill $LLM_SPINNER_PID 2>/dev/null
    wait $LLM_SPINNER_PID 2>/dev/null
    LLM_SPINNER_PID=0

    LLM_MODE=0
    llm-update-prompt
    BUFFER=$shell_BUFFER
    zle reset-prompt
    zle redisplay
  else
    zle .accept-line
  fi
}
zle -N accept-line llm-accept-line

# --- Traps ---
TRAPINT() {
  if (( LLM_MODE )); then
    setopt localoptions no_notify
    LLM_MODE=0
    [[ $LLM_SPINNER_PID -gt 0 ]] && kill $LLM_SPINNER_PID 1>/dev/null 2>/dev/null
    wait $LLM_SPINNER_PID 2>/dev/null
    LLM_SPINNER_PID=0
    print -P "%F{red}[LLM cancelled by Ctrl+C]%f"
    llm-update-prompt
    zle && { zle reset-prompt; zle redisplay; }
    return 0
  else
    return 1
  fi
}

