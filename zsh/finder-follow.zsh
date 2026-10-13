# finder-follow.zsh — two-way cwd sync between this shell and the Finder window above it.
# Sourced from ~/.zshrc. Does nothing unless FINDER_FOLLOW=1 (set by `finder-terminal`).
#
#   ff        show sync status
#   ff off    pause both directions (prompt shows an indicator)
#   ff on     resume and jump to Finder's current folder
#
# Finder -> shell: TMOUT=1 + TRAPALRM reads ~/.finder-follow while the prompt is idle.
# Shell  -> Finder: a chpwd hook sets the front Finder window's target via osascript.

[[ -o interactive ]] || return 0
[[ ${FINDER_FOLLOW:-0} == 1 ]] || return 0

zmodload zsh/datetime
autoload -Uz add-zsh-hook

typeset -g  FF_FILE=${FINDER_FOLLOW_FILE:-$HOME/.finder-follow}
typeset -gi FF_PAUSED=0
typeset -g  FF_SEEN=""           # last follow-file content we observed
typeset -g  FF_SYNCED=""         # last path synced in either direction (resolved)
typeset -gF FF_PUSH_AT=0         # when we last pushed a path to Finder
typeset -gF FF_COOLDOWN=${FINDER_FOLLOW_COOLDOWN:-1.5}
typeset -g  FF_INDICATOR=${FINDER_FOLLOW_INDICATOR-'%F{yellow}⏸ %f'}
typeset -g  FF_DEBUG=${FINDER_FOLLOW_DEBUG:-}   # set to a file path to log pulls/pushes

ff_log() { [[ -n $FF_DEBUG ]] && print -r -- "$(strftime '%H:%M:%S' $EPOCHSECONDS) $*" >> "$FF_DEBUG" }

# ---- Finder -> shell -------------------------------------------------------

# ff_pull [force]: cd to the folder in $FF_FILE when it changed (or when forced).
ff_pull() {
  local force=${1:-} p
  [[ -r $FF_FILE ]] || return 0
  IFS= read -r p < "$FF_FILE" 2>/dev/null
  [[ -n $p ]] || return 0
  p=${p%%/##}; [[ -z $p ]] && p=/
  if [[ -z $force ]]; then
    [[ $p == "$FF_SEEN" ]] && return 0                       # file unchanged
    (( EPOCHREALTIME - FF_PUSH_AT < FF_COOLDOWN )) && return 0  # we just pushed; let Finder settle
  fi
  FF_SEEN=$p
  [[ -d $p ]] || return 0
  if [[ $p == "$PWD" || ${p:A} == "${PWD:A}" ]]; then FF_SYNCED=${p:A}; return 0; fi
  FF_SYNCED=${p:A}
  builtin cd -- "$p" 2>/dev/null || return 0
  ff_log "pull: cd $p"
  zle && zle reset-prompt
  return 0
}

TMOUT=1
TRAPALRM() {
  (( FF_PAUSED )) && return 0
  ff_pull
}

# ---- shell -> Finder -------------------------------------------------------

ff_push() {
  osascript - "$1" <<'EOF' >/dev/null 2>&1
on run argv
  tell application "Finder"
    if (count of Finder windows) is 0 then return
    set target of front Finder window to (POSIX file (item 1 of argv) as alias)
  end tell
end run
EOF
}

ff_chpwd() {
  (( FF_PAUSED )) && return 0
  [[ -n $FF_SYNCED && ${PWD:A} == "$FF_SYNCED" ]] && return 0   # this cd came from Finder
  FF_SYNCED=${PWD:A}
  FF_PUSH_AT=$EPOCHREALTIME
  ff_log "push: $PWD"
  ff_push "$PWD"
}
add-zsh-hook chpwd ff_chpwd

# ---- ff command + prompt indicator -----------------------------------------

ff() {
  case ${1:-} in
    off|pause)
      FF_PAUSED=1; psvar[9]=paused
      print "finder-follow: paused (ff on to resume)" ;;
    on|resume)
      FF_PAUSED=0; psvar[9]=""
      ff_pull force
      print "finder-follow: on — $PWD" ;;
    "")
      local fp="(none)"; [[ -r $FF_FILE ]] && IFS= read -r fp < "$FF_FILE"
      print "finder-follow: $(( FF_PAUSED )) && print -n paused || print -n on)"
      print "  shell:  $PWD"
      print "  finder: $fp"
      print "  file:   $FF_FILE" ;;
    *) print -u2 "usage: ff [on|off]"; return 2 ;;
  esac
}

# Prepend a paused marker to the prompt. Works with plain PROMPT strings; prompt
# frameworks that rebuild PROMPT on every precmd (starship, p10k) will drop it —
# use `ff` or $FF_PAUSED there. Set FINDER_FOLLOW_INDICATOR= to disable.
if [[ -n $FF_INDICATOR ]]; then
  PROMPT="%(9v.${FF_INDICATOR}.)${PROMPT}"
fi

# Start in sync: treat whatever is in the file now as already seen.
if [[ -r $FF_FILE ]]; then IFS= read -r FF_SEEN < "$FF_FILE" 2>/dev/null; FF_SEEN=${FF_SEEN%%/##}; fi
FF_SYNCED=${PWD:A}
