#!/usr/bin/env bash
#
# fdroid-submit.sh — publish an Android app to F-Droid, or a new version of it.
#
#   fdroid-submit.sh [options]   (--help lists them)
#
# The wizard is one function (wizard_fdroid), called at the bottom. Its body
# is deliberately not indented: its here-documents must start at column 0.
# store-submit.sh, next to this file, can run it after checking the app and
# this machine first.

set -eu

# ##########################################################################
#   F-Droid wizard — fdroid-submit.sh [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_fdroid() {
#
# fdroid-submit.sh — interactive wizard for submitting an Android app to F-Droid.
#
# Walks through the process described in:
#   https://f-droid.org/docs/Submitting_to_F-Droid_Quick_Start_Guide/
#   https://f-droid.org/docs/Build_Metadata_Reference/
#
# It detects what it can from your app repo, then asks about every line of
# metadata/<applicationId>.yml in your fdroiddata fork — starting from F-Droid's
# file for an update, your own copy, or another app built the same way — so a
# recipe can be shaped app by app. It validates the file with the fdroid CLI,
# pushes a branch and — with glab logged in — opens the merge request.
#
# Nothing leaves your machine without asking first, unless you pass --yes.

set -eu
# NOTE: deliberately no `set -o pipefail` — `cmd | head` would SIGPIPE and abort.

# ------------------------------------------------------------------ arguments
DRYRUN=0
SAVE=1
ASSUME_YES=0   # --yes: take every detected answer, only stop on problems
ASK_ALL=0      # --ask: ask every question, even the ones it can answer itself
RUN_BUILD=0    # --build: run the full `fdroid build` as part of validation
WANT_RFP=0     # --rfp: open an RFP issue without asking
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/storepublisher"
CONF="$CONF_DIR/last.conf"     # answers that carry across tasks (fork, clone, user)
TASK_DIR="$CONF_DIR/tasks"     # one file per task: this store, this app, this version
STORE_ID=fdroid
PR_ONLY=0      # -p: pick a finished task and open its merge request

usage() {
  cat <<'USAGE'
fdroid-submit.sh — interactive wizard for getting an Android app into F-Droid.

  -h, --help        show this text
  -y, --yes         use everything it detects and don't ask; stops only on
                    problems. A version update becomes a single command.
      --ask         also ask what it can work out about your repo itself
                    (every line of the recipe is asked either way)
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --build       also run the full `fdroid build` (slow)
      --rfp         open a Request For Packaging issue too (new apps)
  -n, --dry-run     do everything except pushing, tagging and opening issues/MRs
      --no-save     do not remember the answers for next time
  -p, --pull-request  pick a task that pushed its branch and open its merge
                    request — nothing else
      --forget      delete every remembered answer and task, and exit
      --forget-app  forget every task for one application id
      --forget-task forget one task by name (as the task list shows it)

Detects what it can from your app's git checkout and only asks for the rest,
writes metadata/<applicationId>.yml into your fdroiddata fork, validates it,
pushes a branch and — with glab logged in — opens the merge request.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --ask)        ASK_ALL=1 ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    --build)      RUN_BUILD=1 ;;
    --rfp)        WANT_RFP=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -rf "$CONF" "$TASK_DIR"; printf 'forgot %s and every task\n' "$CONF"; exit 0 ;;
    -p|--pull-request) PR_ONLY=1 ;;
    --forget-task) FORGET_TASK="${2-}"; shift
                  [ -n "$FORGET_TASK" ] || { printf 'which task? --forget-task <name>\n' >&2; exit 2; }
                  rm -f "$TASK_DIR/$FORGET_TASK.conf" "$TASK_DIR/$FORGET_TASK.mr.md"
                  printf 'forgot task %s\n' "$FORGET_TASK"; exit 0 ;;
    --forget-app) FORGET_APP="${2-}"; shift
                  [ -n "$FORGET_APP" ] || { printf 'which app? --forget-app <applicationId>\n' >&2; exit 2; }
                  rm -f "$TASK_DIR/$STORE_ID-$FORGET_APP"-*.conf "$TASK_DIR/$STORE_ID-$FORGET_APP"-*.mr.md
                  printf 'forgot every task for %s\n' "$FORGET_APP"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- presentation
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; CYN=""
fi
step()  { printf '\n%s━━ %s %s\n' "$B$CYN" "$*" "$R"; }
say()   { printf '   %s\n' "$*"; }
note()  { printf '   %s%s%s\n' "$DIM" "$*" "$R"; }
warn()  { printf '   %s! %s%s\n' "$YLW" "$*" "$R"; }
ok()    { printf '   %s✓ %s%s\n' "$GRN" "$*" "$R"; }
die()   { printf '\n%sERROR: %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# This is a wizard: without someone to answer, there is nothing sensible to do.
# Bailing out on EOF keeps a required question from spinning forever when stdin
# runs dry (a closed pipe, a background run).
readline() {  # readline VAR — false on EOF
  IFS= read -r "$1" && return 0
  printf '\n' >&2
  die "end of input — this script needs an interactive terminal"
}

# ask VAR "question" "default"   — empty default means required
ask() {
  local __var="$1" __q="$2" __def="${3-}" __in=""
  # nothing detected? then what this app answered last time is the default
  [ -n "$__def" ] || __def="$(recall "$__var")"
  if [ "$ASSUME_YES" = 1 ]; then
    [ -n "$__def" ] || die "--yes: nothing to answer \"$__q\" with — run once without --yes"
    printf -v "$__var" '%s' "$__def"; ok "$__q: $__def"; return 0
  fi
  while :; do
    if [ -n "$__def" ]; then
      printf '   %s%s%s [%s]: ' "$B" "$__q" "$R" "$__def" >&2
    else
      printf '   %s%s%s: ' "$B" "$__q" "$R" >&2
    fi
    readline __in
    [ -z "$__in" ] && __in="$__def"
    if [ -z "$__in" ]; then printf '   %sthis one is required%s\n' "$YLW" "$R" >&2; continue; fi
    break
  done
  printf -v "$__var" '%s' "$__in"
  remember "$__var" "$__in"
}

ask_opt() {  # like ask, but blank is allowed and means "omit this field";
             # with a default, Enter keeps it and "-" leaves the field out
  local __var="$1" __q="$2" __def="${3-}" __in=""
  [ -n "$__def" ] || __def="$(recall "$__var")"
  if [ "$ASSUME_YES" = 1 ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  printf '   %s%s%s%s: ' "$B" "$__q" "$R" "${__def:+ [$__def, - for none]}" >&2
  readline __in
  [ -z "$__in" ] && __in="$__def"
  [ "$__in" = - ] && __in=""
  printf -v "$__var" '%s' "$__in"
  remember "$__var" "$__in"
}

confirm() {  # confirm "question" [default y|n] — --yes takes the default
  local q="$1" def="${2:-n}" a=""
  if [ "$ASSUME_YES" = 1 ]; then
    [ "$def" = y ] && return 0
    warn "$q — no (the safe answer; run without --yes to choose)"; return 1
  fi
  local hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  printf '   %s%s%s %s ' "$B" "$q" "$R" "$hint" >&2
  readline a
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# go "question" — for the actions that leave your machine (push, tag, MR, RFP):
# asked with Yes as the default; --yes answers it.
go() {
  if [ "$ASSUME_YES" = 1 ]; then ok "$1 — yes (--yes)"; return 0; fi
  confirm "$1" y
}

# auto VAR "label" "detected value" — take what was detected without asking
# (shown as a ✓ line); ask only when nothing was detected, or with --ask.
auto() {
  local __var="$1" __label="$2" __val="${3-}"
  [ -n "$__val" ] || __val="$(recall "$__var")"
  if [ "$ASK_ALL" = 0 ] && [ -n "$__val" ]; then
    printf -v "$__var" '%s' "$__val"; ok "$__label: $__val"; remember "$__var" "$__val"
  else
    ask "$__var" "$__label" "$__val"
  fi
}

auto_opt() {  # like auto, for optional fields: blank is fine and not asked
  local __var="$1" __label="$2" __val="${3-}"
  [ -n "$__val" ] || __val="$(recall "$__var")"
  if [ "$ASK_ALL" = 0 ]; then
    printf -v "$__var" '%s' "$__val"; remember "$__var" "$__val"
    [ -n "$__val" ] && ok "$__label: $__val"
    return 0
  fi
  ask_opt "$__var" "$__label" "$__val"
}

# ask_once VAR "label" "default" — for the fields that end up on f-droid.org:
# asked the first time this app is submitted, then taken from memory, because
# quietly publishing whatever `git config user.name` happens to say is not on.
ask_once() {
  local __var="$1" __label="$2" __def="${3-}"
  if [ "$ASK_ALL" = 0 ] && [ -n "$(recall "$__var")" ]; then
    auto "$__var" "$__label" "$(recall "$__var")"
  else
    ask "$__var" "$__label" "$__def"
  fi
}

# edit_file <path> — hand the file to your editor and come back
edit_file() {
  local ed c
  ed="${VISUAL:-${EDITOR:-}}"
  if [ -z "$ed" ]; then
    for c in nvim vim nano micro helix hx vi; do
      if have "$c"; then ed="$c"; break; fi
    done
  fi
  if [ -z "$ed" ]; then
    warn "no editor found — set \$EDITOR, or edit it in another window:"
    note "$1"
    return 1
  fi
  # /dev/tty, not stdin: answers may be arriving on a pipe, an editor cannot use that
  if ! { true > /dev/tty; } 2>/dev/null; then
    warn "no terminal to open $ed in — edit it in another window:"
    note "$1"
    return 1
  fi
  note "opening $1 in $ed"
  # unquoted on purpose: $EDITOR may carry arguments, e.g. "code -w"
  # shellcheck disable=SC2086
  if ! $ed "$1" < /dev/tty > /dev/tty 2>&1; then
    warn "$ed exited non-zero — leaving the file as it stands"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- scratch space
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdroid-submit.XXXXXX")"
KEEP_WORK=0
cleanup() {
  if [ "$KEEP_WORK" = 1 ]; then
    printf '   %sleft behind: %s%s\n' "$DIM" "$WORK" "$R"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------- remembered answers
# Written by this script only, as `SAVED_X=<shell-quoted>` lines.
SAVED_REPO=""; SAVED_SUBDIR=""; SAVED_LICENSE=""; SAVED_CATSEL=""
SAVED_AUTHORNAME=""; SAVED_AUTHOREMAIL=""; SAVED_AUTHORSITE=""; SAVED_WEBSITE=""
SAVED_GLUSER=""; SAVED_FORKURL=""; SAVED_FDROIDDATA=""; SAVED_JDK=""
SAVED_FDROIDSERVER=""; SAVED_CATSEL_APP=""; SAVED_LICENSE_APP=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi

save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  # A run only answers some questions (an update asks no categories, license
  # or author): keep what was remembered for everything it didn't answer.
  local catsel="${SAVED_CATSEL:-}" catapp="${SAVED_CATSEL_APP:-}"
  if [ -n "${CATSEL:-}" ]; then catsel="$CATSEL"; catapp="${APPID:-}"; fi
  local lic="${SAVED_LICENSE:-}" licapp="${SAVED_LICENSE_APP:-}"
  if [ -n "${LICENSE:-}" ]; then lic="$LICENSE"; licapp="${APPID:-}"; fi
  {
    printf '# written by fdroid-submit.sh — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'         "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_SUBDIR=%q\n'       "${SUBDIR:-${SAVED_SUBDIR:-}}"
    printf 'SAVED_LICENSE=%q\n'      "$lic"
    printf 'SAVED_LICENSE_APP=%q\n'  "$licapp"
    printf 'SAVED_CATSEL=%q\n'       "$catsel"
    printf 'SAVED_CATSEL_APP=%q\n'   "$catapp"
    printf 'SAVED_AUTHORNAME=%q\n'   "${AUTHORNAME:-${SAVED_AUTHORNAME:-}}"
    printf 'SAVED_AUTHOREMAIL=%q\n'  "${AUTHOREMAIL:-${SAVED_AUTHOREMAIL:-}}"
    printf 'SAVED_AUTHORSITE=%q\n'   "${AUTHORSITE:-${SAVED_AUTHORSITE:-}}"
    printf 'SAVED_WEBSITE=%q\n'      "${WEBSITE:-${SAVED_WEBSITE:-}}"
    printf 'SAVED_GLUSER=%q\n'       "${GLUSER:-${SAVED_GLUSER:-}}"
    printf 'SAVED_FORKURL=%q\n'      "${FORKURL:-${SAVED_FORKURL:-}}"
    printf 'SAVED_FDROIDDATA=%q\n'   "${FDROIDDATA:-${SAVED_FDROIDDATA:-}}"
    printf 'SAVED_JDK=%q\n'          "${JDK:-${SAVED_JDK:-}}"
    printf 'SAVED_FDROIDSERVER=%q\n' "${FDROIDSERVER_DIR:-${SAVED_FDROIDSERVER:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------- what this app answered last
# $CONF_DIR/apps/<appid>.conf holds every answer this app has been given, plus
# the milestones that leave your machine (tag pushed, branch pushed, merge
# request, release). A re-run walks all five sections again — that is the point,
# they check each other — but every question comes back with last time's answer
# as its default, and every finished step is recognised instead of redone.
declare -A MEM=()
TASK_FILE=""
task_id() { printf '%s-%s-%s' "$STORE_ID" "${APPID:-unknown}" "${VCODE:-0}"; }

read_task() {  # read_task <file> — merge its answers in, without overwriting this run's
  local k
  [ -f "$1" ] || return 0
  declare -A REM=()
  # shellcheck disable=SC1090
  . "$1" || { warn "could not read $1"; return 0; }
  for k in "${!REM[@]}"; do
    [ -v "MEM[$k]" ] || MEM["$k"]="${REM[$k]}"
  done
}
state_load() {  # settle which task file this run belongs to, and load it
  TASK_FILE="$TASK_DIR/$(task_id).conf"
  read_task "$TASK_FILE"
  remember ST_STORE "$STORE_ID"
  remember ST_APPID "$APPID"
  [ -n "$(recall ST_STATUS)" ] || remember ST_STATUS started
}
state_save() {
  { [ "$SAVE" = 1 ] && [ -n "$TASK_FILE" ]; } || return 0
  local k
  mkdir -p "${TASK_FILE%/*}"
  {
    printf '# fdroid-submit.sh — task %s\n' "$(basename "${TASK_FILE%.conf}")"
    printf '# delete this file, or run --forget-task, to start it afresh\n'
    for k in "${!MEM[@]}"; do printf 'REM[%s]=%q\n' "$k" "${MEM[$k]}"; done
  } > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"
  chmod 600 "$TASK_FILE" 2>/dev/null || true
}
remember() { MEM["$1"]="$2"; state_save; }
recall()   { printf '%s' "${MEM[$1]:-}"; }
done_with() { [ -n "${MEM[ST_$1]:-}" ]; }

# The task files used to be one per app under ~/.config/fdroid-submit/apps.
# Carry them over once so remembered answers survive the move.
migrate_tasks() {
  local old="${XDG_CONFIG_HOME:-$HOME/.config}/fdroid-submit" f appid
  [ -d "$old" ] || return 0
  [ -f "$CONF_DIR/.migrated" ] && return 0
  mkdir -p "$TASK_DIR"
  if [ -f "$old/last.conf" ] && [ ! -f "$CONF" ]; then cp "$old/last.conf" "$CONF"; fi
  for f in "$old"/apps/*.conf; do
    [ -f "$f" ] || continue
    appid="$(basename "$f" .conf)"
    (
      declare -A REM=()
      # shellcheck disable=SC1090
      . "$f" 2>/dev/null || exit 0
      local_status=started
      [ -n "${REM[ST_BRANCH]:-}" ] && local_status=pushed
      [ -n "${REM[ST_MR]:-}" ] && local_status=submitted
      t="$TASK_DIR/$STORE_ID-$appid-${REM[VCODE]:-0}.conf"
      [ -f "$t" ] && exit 0
      {
        printf '# migrated from %s\n' "$f"
        for k in "${!REM[@]}"; do printf 'REM[%s]=%q\n' "$k" "${REM[$k]}"; done
        printf 'REM[ST_STORE]=%q\n' "$STORE_ID"
        printf 'REM[ST_APPID]=%q\n' "$appid"
        printf 'REM[ST_STATUS]=%q\n' "$local_status"
      } > "$t"
      chmod 600 "$t" 2>/dev/null || true
    )
  done
  mkdir -p "$CONF_DIR"
  : > "$CONF_DIR/.migrated"
}

# task_rows — one line per task of this store, newest first:
#   <file>TAB<appid>TAB<version>TAB<status>TAB<when>
task_rows() {
  local f
  for f in $(ls -t "$TASK_DIR/$STORE_ID"-*.conf 2>/dev/null || true); do
    [ -f "$f" ] || continue
    (
      declare -A REM=()
      # shellcheck disable=SC1090
      . "$f" 2>/dev/null || exit 0
      printf '%s\t%s\t%s\t%s\t%s\n' "$f" \
        "${REM[ST_APPID]:-${REM[APPID]:-?}}" \
        "${REM[VNAME]:-?}+${REM[VCODE]:-?}" \
        "${REM[ST_STATUS]:-started}" \
        "${REM[ST_RUN]:-}"
    )
  done
}

# pick_task [status-filter] — show this store's tasks and load the chosen one.
# Selecting one makes its answers the defaults for this run; with a filter, only
# tasks in that state are offered. Returns 1 when nothing was picked.
pick_task() {
  local want="${1-}" rows=() row n=0 f appid ver st when choice
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    st="$(printf '%s' "$row" | cut -f4)"
    case "$want" in
      '') ;;
      pushed-or-submitted) case "$st" in pushed|submitted) ;; *) continue ;; esac ;;
      *) [ "$st" = "$want" ] || continue ;;
    esac
    rows+=("$row")
  done <<EOF
$(task_rows)
EOF
  [ "${#rows[@]}" -gt 0 ] || return 1
  step "Tasks"
  for row in "${rows[@]}"; do
    n=$((n + 1))
    appid="$(printf '%s' "$row" | cut -f2)"
    ver="$(printf '%s' "$row" | cut -f3)"
    st="$(printf '%s' "$row" | cut -f4)"
    when="$(printf '%s' "$row" | cut -f5)"
    printf '     %2d) %-34s %-12s %-10s %s\n' "$n" "$appid" "$ver" "$st" "$when"
  done
  [ -z "$want" ] && printf '     %2s) %s\n' "n" "start a new task"
  if [ "$ASSUME_YES" = 1 ]; then choice=1; else
    printf '   %sContinue%s [1]: ' "$B" "$R" >&2
    readline choice
    choice="${choice:-1}"
  fi
  case "$choice" in
    n|N*)        return 1 ;;   # "new task" without a filter, "none of these" with one
    *[!0-9]*|'') warn "not a number"; return 1 ;;
  esac
  [ "$choice" -ge 1 ] && [ "$choice" -le "${#rows[@]}" ] || { warn "no task $choice"; return 1; }
  f="$(printf '%s' "${rows[$((choice - 1))]}" | cut -f1)"
  read_task "$f"
  TASK_FILE="$f"
  ok "continuing $(basename "${f%.conf}")"
  return 0
}

# ------------------------------------------------------------------- fdroid CLI
# The wizard never installs fdroidserver itself. It uses the one you have:
# `fdroid` on PATH, or a source checkout of fdroidserver (run the way
# fdroiddata's CI runs master: PATH and PYTHONPATH pointed at the checkout).
# If there is neither, it says how to install one and waits for you.
RUNNER=""
FDROIDSERVER_DIR=""

fdroid_checkout_runs() {  # fdroid_checkout_runs <dir>
  PATH="$1:$PATH" PYTHONPATH="$1${PYTHONPATH:+:$PYTHONPATH}" \
    "$1/fdroid" --version >/dev/null 2>&1
}

find_fdroid() {  # sets RUNNER; false if nothing usable was found
  local d ver
  make_git_shim
  if have fdroid; then
    ver="$(fdroid --version 2>/dev/null | tail -1)"
    RUNNER=path; ok "fdroid ${ver:+$ver }on PATH ($(command -v fdroid))"
    return 0
  fi
  for d in "${FDROIDSERVER:-}" "${SAVED_FDROIDSERVER:-}" \
           "$HOME/Opt/fdroidserver" "$HOME/opt/fdroidserver" "$HOME/fdroidserver" \
           "$HOME/src/fdroidserver" "$HOME/Projects/fdroidserver"; do
    [ -n "$d" ] || continue
    d="${d/#\~/$HOME}"
    [ -f "$d/fdroid" ] || continue
    if fdroid_checkout_runs "$d"; then
      RUNNER=checkout; FDROIDSERVER_DIR="$d"
      ver="$(PATH="$d:$PATH" PYTHONPATH="$d" "$d/fdroid" --version 2>/dev/null | tail -1)"
      ok "fdroidserver checkout ${ver:+$ver }at $d"
      return 0
    fi
    warn "found $d, but it doesn't run — are its Python dependencies installed?"
  done
  return 1
}

detect_runner() {
  make_git_shim
  find_fdroid && return 0
  warn "fdroidserver is not installed (or not in the places this wizard looks)"
  say "It validates the metadata before you open the merge request. Install it"
  say "yourself, whichever way suits you — for example:"
  note "  nix:            nix profile install nixpkgs#fdroidserver   (or add it to your config)"
  note "  Debian/Ubuntu:  sudo apt install fdroidserver"
  note "  like F-Droid CI: git clone https://gitlab.com/fdroid/fdroidserver.git ~/Opt/fdroidserver"
  note "                  (runs from the checkout; its Python dependencies must be installed)"
  while :; do
    say "r) check again   p) give the path to a checkout   s) skip validation   q) quit"
    ask FDCHOICE "Choice" "r"
    case "$FDCHOICE" in
      r|R) find_fdroid && return 0; warn "still not found" ;;
      p|P) ask FDROIDSERVER "Path to the fdroidserver checkout" "$HOME/Opt/fdroidserver"
           find_fdroid && return 0 ;;
      s|S) RUNNER=none; warn "validation will be skipped — the maintainers' CI will still run it"
           return 0 ;;
      q|Q) exit 0 ;;
      *)   warn "r, p, s or q" ;;
    esac
  done
}

# Two things about this machine can stop fdroidserver's git calls dead, and
# neither shows up until something tries to clone (checkupdates, build):
#
#  * /bin/true and /bin/false may not exist — they do not on NixOS, nor in slim
#    containers. fdroidserver hardcodes both, to keep git from prompting and to
#    block ssh URLs (CVE-2017-1000117), as -c options *and* as GIT_ASKPASS,
#    SSH_ASKPASS and GIT_SSH (its common.py, VCSgit.git()). Nothing from outside
#    can override all of those, and git dies with "cannot exec '/bin/false'".
#
#  * a personal `url.ssh://git@github.com/.insteadOf = https://github.com/` in
#    ~/.gitconfig or ~/.config/git/config — a common convenience — turns every
#    https clone into an ssh one, and fdroidserver blocks ssh on purpose. Its CI
#    has no such rewrite, so this fails only on your machine.
#
# A git shim first on PATH fixes both for fdroid's calls alone: real binaries in
# place of the missing ones, keeping fdroidserver's intent (an askpass that says
# nothing, an ssh that refuses), and global git config out of the way when it
# would reroute https to ssh.
GIT_SHIM=""
GIT_CFG_OFF=""      # set when global git config reroutes https, so fdroid ignores it
GIT_REAL_FALSE=""   # a /bin/false that exists here, for git's ssh command
git_rewrites_https() {  # true if git turns an https forge URL into something else
  local host out
  for host in github.com gitlab.com codeberg.org; do
    out="$(git ls-remote --get-url "https://$host/owner/repo.git" 2>/dev/null || true)"
    case "$out" in
      ''|https://*) ;;
      *) return 0 ;;
    esac
  done
  return 1
}
make_git_shim() {
  [ -z "$GIT_SHIM" ] || return 0
  local t f g need=0 drop_global=""
  { [ -x /bin/true ] && [ -x /bin/false ]; } || need=1
  if git_rewrites_https; then
    need=1
    drop_global="export GIT_CONFIG_GLOBAL=/dev/null"
    GIT_CFG_OFF=1
  fi
  [ "$need" = 1 ] || return 0
  t="$(type -P true || true)"; f="$(type -P false || true)"; g="$(type -P git || true)"
  if [ -z "$t" ] || [ -z "$f" ] || [ -z "$g" ]; then
    warn "no /bin/true, /bin/false or git replacement found — fdroid's clones may fail"
    return 0
  fi
  GIT_REAL_FALSE="$f"
  GIT_SHIM="$WORK/gitshim"
  mkdir -p "$GIT_SHIM"
  cat > "$GIT_SHIM/git" <<SHIM
#!/bin/sh
# Written by fdroid-submit.sh, for fdroid's git calls only. See the comment at
# make_git_shim() for why each line is here.
export GIT_ASKPASS='$t' SSH_ASKPASS='$t' GIT_SSH='$f' GIT_SSH_COMMAND='$f'
$drop_global
n=\$#
while [ "\$n" -gt 0 ]; do
  a=\$1; shift
  case "\$a" in
    core.askpass=/bin/true)     a='core.askpass=$t' ;;
    core.sshCommand=/bin/false) a='core.sshCommand=$f' ;;
  esac
  set -- "\$@" "\$a"
  n=\$((n - 1))
done
exec '$g' "\$@"
SHIM
  chmod +x "$GIT_SHIM/git"
  { [ -x /bin/true ] && [ -x /bin/false ]; } \
    || note "no /bin/true or /bin/false here — fdroid gets a git shim with the real ones"
  if [ -n "$drop_global" ]; then
    note "your git config rewrites https forge URLs to ssh, which fdroidserver blocks:"
    note "fdroid's own git calls will ignore it (your config is untouched)"
  fi
}

frun() {  # frun <fdroid args...>   — run inside $FDROIDDATA
  # The shim below goes on PATH, but PATH alone is not enough: a packaged
  # fdroid (nix, pipx) is a wrapper script that prepends its own store paths,
  # so the real git wins and the shim is never called. Pass the same fixes as
  # environment variables too, which no wrapper reorders. fdroidserver sets
  # GIT_ASKPASS and GIT_SSH itself, but not GIT_SSH_COMMAND (which outranks
  # GIT_SSH) and not GIT_CONFIG_GLOBAL, so these two still land.
  local envs=()
  [ -n "$GIT_CFG_OFF" ] && envs+=("GIT_CONFIG_GLOBAL=/dev/null")
  [ -n "$GIT_REAL_FALSE" ] && envs+=("GIT_SSH_COMMAND=$GIT_REAL_FALSE")
  case "$RUNNER" in
    path)     ( cd "$FDROIDDATA" && PATH="${GIT_SHIM:+$GIT_SHIM:}$PATH" \
                env "${envs[@]+"${envs[@]}"}" fdroid "$@" ) ;;
    checkout) ( cd "$FDROIDDATA" && \
                PATH="${GIT_SHIM:+$GIT_SHIM:}$FDROIDSERVER_DIR:$PATH" \
                PYTHONPATH="$FDROIDSERVER_DIR${PYTHONPATH:+:$PYTHONPATH}" \
                env "${envs[@]+"${envs[@]}"}" "$FDROIDSERVER_DIR/fdroid" "$@" ) ;;
    none)     warn "skipped: fdroid $*"; return 0 ;;
  esac
}

# ------------------------------------------------------- GitLab, and the fork
# Definitions only, kept up here because `-p` below needs them before the main
# flow has run: where the fork lives, how to ask GitLab things, and how to see
# whether a branch already has a merge request.
GL_API="${GITLAB_API_ROOT:-https://gitlab.com/api/v4}"
FDROIDDATA_UPSTREAM="${FDROIDDATA_UPSTREAM:-https://gitlab.com/fdroid/fdroiddata.git}"
glab_ready() { have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; }

glab_fd() {
  if [ -d "${FDROIDDATA:-}/.git" ]; then
    ( cd "$FDROIDDATA" && glab "$@" )
  else
    glab "$@"
  fi
}

gitlab_get() {  # gitlab_get <api path> — authenticated GET, JSON on stdout
  if glab_ready; then glab api "$1" 2>/dev/null || true
  elif [ -n "${GITLAB_TOKEN:-}" ]; then
    curl -s --max-time 20 -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GL_API/$1" || true
  fi
}

json_str() {  # json_str <key> — first "key":"value" in the JSON on stdin
  grep -Eo "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed -n 1p | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}

fork_path() {  # namespace/project from a gitlab.com clone URL, or nothing
  printf '%s' "$1" | sed -nE 's#^(git@gitlab\.com:|https://gitlab\.com/|ssh://git@gitlab\.com/)##p' \
    | sed -E 's#\.git$##'
}

urlencode() {  # percent-encode every byte except RFC 3986 unreserved ones
  local LC_ALL=C s="$1" out="" c hex i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      # bytes above 0x7F can come back sign-extended (FFFF…E2); the last
      # two hex digits are the byte either way
      *) printf -v hex '%02X' "'$c"; out+="%${hex: -2}" ;;
    esac
  done
  printf '%s' "$out"
}

existing_mr() {
  gitlab_get "projects/fdroid%2Ffdroiddata/merge_requests?state=opened&source_branch=$(urlencode "$BRANCH")" \
    | grep -Eo 'https://[^"]*/-/merge_requests/[0-9]+' | head -1
}

# sync_mr_description <mr url> <body file> — put the App Inclusion template,
# with the boxes this run could tick, into a merge request that already exists.
# One opened from the plain web link has none of it, and reviewers ask for it.
sync_mr_description() {
  local url="$1" body="$2"
  [ -s "$body" ] || { note "no saved description to put in the merge request"; return 0; }
  if ! glab_ready; then
    note "glab is not logged in — paste $body into the merge request yourself"
    return 0
  fi
  go "Replace the merge request description with the filled-in template?" || return 0
  if glab_fd mr update "${url##*/}" -R fdroid/fdroiddata \
       --description "$(cat "$body")" >/dev/null 2>&1; then
    ok "description updated"
  else
    warn "glab could not update it — paste it yourself from $body"
  fi
}

# reference_apk_reproducible <apk> <appid> — will F-Droid's rebuild match this?
# A Flutter APK carries the absolute path of its generated plugin registrant
# inside lib/*/libapp.so, and a hash of that path spreads through the whole Dart
# snapshot. The rebuild therefore has to happen at the same path, or the
# reproducible-build check fails on libapp.so however identical everything else
# is. The apps in fdroiddata that manage this do not move their own build: they
# make F-Droid build where they built, with a sudo line and a mv in the recipe.
# reference_apk_blocks <apk> — F-Droid's scanner rejects an APK carrying extra
# signing blocks. The Android Gradle Plugin adds one, "Dependency metadata", for
# Play Console; nothing outside Play reads it, and it fails the "check apk" job
# after everything else has already passed.
reference_apk_blocks() {
  have python3 || return 0
  python3 - "$1" <<'PYBLOCKS'
import struct, sys
KNOWN = {0x7109871a: 'v2 signature', 0xf05368c0: 'v3 signature',
         0x1b93ad61: 'v3.1 signature', 0x42726577: 'padding',
         0x504b4453: 'Dependency metadata'}
d = open(sys.argv[1], 'rb').read()
i = d.rfind(b'APK Sig Block 42')
if i < 0:
    sys.exit(0)
size_end = struct.unpack('<Q', d[i - 8:i])[0]
start = i + 8 - size_end
size_begin = struct.unpack('<Q', d[start:start + 8])[0]
p, end, bad = start + 8, start + 8 + size_begin - 24, []
while p < end:
    ln = struct.unpack('<Q', d[p:p + 8])[0]
    bid = struct.unpack('<I', d[p + 8:p + 12])[0]
    if bid == 0x504b4453:
        bad.append(KNOWN[bid])
    p += 8 + ln
print("\n".join(bad))
PYBLOCKS
}

reference_apk_build_path() {  # the directory the APK was compiled in, if it says
  local found
  { have unzip && have strings; } || return 0
  found="$(unzip -p "$1" 'lib/*/libapp.so' 2>/dev/null \
            | strings -n 20 2>/dev/null \
            | grep -m1 -oE 'file://[^"]*dart_plugin_registrant\.dart' || true)"
  [ -n "$found" ] || return 0
  found="${found#file://}"
  printf '%s' "${found%/.dart_tool/*}"
}
reference_apk_reproducible() {
  local apk="$1" appid="$2" path top
  path="$(reference_apk_build_path "$apk")"
  [ -n "$path" ] || return 0    # not Flutter, or nothing baked in: nothing to say
  case "$path" in
    /home/vagrant/build/"$appid"*) ok "built at F-Droid's own path — it can reproduce this"; return 0 ;;
  esac
  ok "the APK was built in: $path"
  case "$path" in
    /tmp/*|*/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*)
      warn "that looks like a throwaway directory — a later release built elsewhere"
      warn "would stop reproducing. Build releases somewhere fixed (CI is ideal:"
      warn "GitHub Actions is always /home/runner/work/<repo>/<repo>)." ;;
  esac
  note "F-Droid must build there too, or libapp.so will differ. Add to each build"
  note "entry — this is how the Flutter apps in fdroiddata do it:"
  # the path above ends in the app's subdir; the whole checkout moves, not just it
  local root="$path" sub="${FLUTTER_DIR:-${SUBDIR:-}}" ups=.. depth=1
  case "$sub" in
    ''|.) ;;
    *) root="${path%/$sub}"
       depth=$(( $(printf '%s' "$sub" | tr -cd / | wc -c) + 2 )) ;;
  esac
  ups="$(n=0; while [ "$n" -lt "$depth" ]; do printf '../'; n=$((n+1)); done)"
  top="/$(printf '%s' "${root#/}" | cut -d/ -f1-2)"
  cat <<SNIPPET
       sudo:
         - mkdir -p ${root%/*}
         - chown -R vagrant $top
       prebuild:
         - export repo=$root
         - cd ${ups%/}           # out of the build dir, so it can be moved
         - mv $appid \$repo
         - pushd \$repo${sub:+/$sub}    # …the usual prebuild steps here…
         - popd
         - mv \$repo $appid
SNIPPET
  note "and the same move around the build: steps. A native plugin may also stamp"
  note "a random build id; neutralise it, e.g. for package:jni"
  note "  sed -i -e '/^cmake_minimum_required/a add_link_options(\"LINKER:--build-id=none\")' \\"
  note "    \$PUB_CACHE/hosted/pub.dev/jni-*/src/CMakeLists.txt"
  return 1
}

# ------------------------------------------------- -p: just the merge request
# A task that pushed its branch but never opened the merge request (glab not
# logged in, you said no, the run stopped) can be finished here on its own.
open_mr_for_task() {
  local body title head
  APPID="$(recall ST_APPID)"
  BRANCH="$(recall ST_BRANCH)"
  FDROIDDATA="$(recall FDROIDDATA)"
  FORKURL="$(recall FORKURL)"
  GLUSER="$(recall GLUSER)"
  UPBRANCH="$(recall ST_UPBRANCH)"; UPBRANCH="${UPBRANCH:-master}"
  title="$(recall ST_COMMITMSG)"; title="${title:-New app: $APPID}"
  [ -n "$BRANCH" ] || die "that task has no pushed branch"
  ok "app: $APPID"
  ok "branch: $BRANCH -> fdroid/fdroiddata ($UPBRANCH)"
  ok "title: $title"

  body="${TASK_FILE%.conf}.mr.md"
  MR_URL="$(existing_mr || true)"
  [ -n "$MR_URL" ] || MR_URL="$(recall ST_MR)"
  if [ -n "$MR_URL" ]; then
    ok "a merge request from $BRANCH is already open: $MR_URL"
    remember ST_MR "$MR_URL"; remember ST_STATUS submitted
    # Reviewers ask for the App Inclusion template with its boxes ticked, which
    # is exactly what was saved when the branch was pushed. An MR opened from
    # the plain web link has none of it, so offer to put it in place.
    [ -s "$body" ] && { printf '%s' "$DIM"; sed 's/^/   | /' "$body" | head -20; printf '%s' "$R"; }
    sync_mr_description "$MR_URL" "$body"
    return 0
  fi
  if [ ! -s "$body" ]; then
    body="$WORK/mr.md"
    printf '%s\n\n' "$title" > "$body"
    [ -n "$(recall ST_RFP_REF)" ] && printf 'Closes %s\n' "$(recall ST_RFP_REF)" >> "$body"
    note "no saved description for this task — sending a short one"
  fi
  head="$(fork_path "$FORKURL")"
  if glab_ready && [ -n "$head" ]; then
    if ! go "Open the merge request on fdroid/fdroiddata now?"; then
      say "nothing opened"; return 0
    fi
    MR_OUT="$(glab_fd mr create -R fdroid/fdroiddata -H "$head" \
                -s "$BRANCH" -b "$UPBRANCH" -t "$title" \
                -d "$(cat "$body")" --allow-collaboration -y 2>&1 || true)"
    MR_URL="$(printf '%s\n' "$MR_OUT" | grep -Eo 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1 || true)"
    if [ -n "$MR_URL" ]; then
      ok "merge request: $MR_URL"
      remember ST_MR "$MR_URL"; remember ST_STATUS submitted
      return 0
    fi
    warn "glab did not open it:"
    printf '%s\n' "$MR_OUT" | tail -5 | sed 's/^/       /'
  else
    note "glab is not logged in to gitlab.com — here is the link instead"
  fi
  say "${B}Open it here:${R} https://gitlab.com/${GLUSER:-<you>}/fdroiddata/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BRANCH&merge_request%5Btarget_branch%5D=$UPBRANCH"
  note "target fdroid/fdroiddata, branch $UPBRANCH, title \"$title\""
  note "the description is in $body"
}

if [ "$PR_ONLY" = 1 ]; then
  migrate_tasks
  step "Tasks with a branch on your fork"
  note "pushed: no merge request yet — submitted: one is open and can be re-described"
  if ! pick_task pushed-or-submitted; then
    say "nothing opened: no task with a pushed branch was picked."
    note "tasks live in $TASK_DIR"
    exit 0
  fi
  open_mr_for_task
  exit 0
fi

# =============================================================== 0. orientation
cat <<BANNER

  ${B}F-Droid submission wizard${R}

  Five stages:
    1. your app repo      — what F-Droid needs to know, plus the usual pitfalls
    2. fdroiddata fork    — clone it, branch off current upstream master
    3. metadata           — write (or extend) metadata/<appid>.yml
    4. validate           — fdroid readmeta / rewritemeta / lint / build
    5. push               — branch pushed, merge request opened

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything except the final push"

[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
# New app or version update is decided later, from upstream fdroiddata itself.
IS_UPDATE=0

migrate_tasks
# Pick up an earlier task, if there is one: its answers become this run's
# defaults, so continuing where you stopped needs no retyping.
if [ "$PR_ONLY" = 0 ] && [ "$ASSUME_YES" = 0 ] && [ -d "$TASK_DIR" ]; then
  pick_task || true
fi

detect_runner

# ============================================================== 1. the app repo
step "1/5  Your app repository"

# The app repo: --repo, else the git repo you run this from (unless that's
# this script's own), else the one from last time.
SELF_REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ "$HERE_REPO" = "$SELF_REPO" ] && HERE_REPO=""
REPO_GUESS="${REPO_ARG:-${HERE_REPO:-${SAVED_REPO:-}}}"
while :; do
  if [ -n "$REPO_ARG" ]; then REPO="$REPO_ARG"
  else auto REPO "App repository" "$REPO_GUESS"; fi
  REPO="${REPO/#\~/$HOME}"
  [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] && break
  [ -n "$REPO_ARG" ] && die "$REPO is not a git checkout"
  warn "$REPO is not a git checkout"; REPO_GUESS=""
  ask REPO "Path to the app's git checkout" ""
  REPO="${REPO/#\~/$HOME}"
  [ -d "$REPO/.git" ] && break
done
REPO="$(cd "$REPO" && pwd)"

# --- Flutter? Its Android project lives under <flutter dir>/android, the
# version lives in pubspec.yaml, and F-Droid needs a different build recipe.
FLUTTER_DIR=""
for p in "$REPO/pubspec.yaml" "$REPO"/*/pubspec.yaml "$REPO"/*/*/pubspec.yaml; do
  [ -f "$p" ] || continue
  d="$(dirname "$p")"
  grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
  [ -f "$d/android/app/build.gradle.kts" ] || [ -f "$d/android/app/build.gradle" ] || continue
  FLUTTER_DIR="${d#"$REPO"}"; FLUTTER_DIR="${FLUTTER_DIR#/}"; FLUTTER_DIR="${FLUTTER_DIR:-.}"
  break
done
# Flutter or not decides the whole build recipe — the srclib, the prebuild
# steps, one APK per CPU type — so it is confirmed rather than assumed, and can
# be answered either way when the guess is wrong.
if [ -n "$FLUTTER_DIR" ]; then
  ok "Flutter app in ${FLUTTER_DIR}/"
  if [ "$ASSUME_YES" = 0 ] && ! confirm "Build it as a Flutter app?" y; then
    FLUTTER_DIR=""
    note "treating it as a plain Gradle app instead"
  fi
elif [ "$ASSUME_YES" = 0 ] && confirm "Is this a Flutter app? (no pubspec.yaml was found)" n; then
  ask FLUTTER_DIR "Path to the Flutter module, relative to the repo" "."
  FLUTTER_DIR="${FLUTTER_DIR#./}"; FLUTTER_DIR="${FLUTTER_DIR%/}"; FLUTTER_DIR="${FLUTTER_DIR:-.}"
  if [ ! -f "$REPO/$FLUTTER_DIR/pubspec.yaml" ]; then
    warn "no pubspec.yaml in $REPO/$FLUTTER_DIR"
    if confirm "Use the Flutter recipe anyway?" n; then
      note "the build will probably need hand-editing before it works"
    else
      FLUTTER_DIR=""
      note "treating it as a plain Gradle app"
    fi
  fi
fi
if [ -n "$FLUTTER_DIR" ]; then
  FLUTTER_ANDROID="$FLUTTER_DIR/android/app"; FLUTTER_ANDROID="${FLUTTER_ANDROID#./}"
fi

# --- subdir (the gradle module that produces the APK)
SUBDIR_GUESS=""
for cand in "${SAVED_SUBDIR:-}" "${FLUTTER_ANDROID:-}" app mobile android .; do
  [ -n "$cand" ] || continue
  for gf in build.gradle.kts build.gradle; do
    if [ -f "$REPO/$cand/$gf" ] && grep -qE 'applicationId|namespace' "$REPO/$cand/$gf" 2>/dev/null; then
      SUBDIR_GUESS="$cand"; break 2
    fi
  done
done
GRADLE_FILE=""
FIRST=1
while :; do
  if [ "$FIRST" = 1 ]; then auto SUBDIR "Gradle module" "$SUBDIR_GUESS"
  else ask SUBDIR "Gradle module subdirectory (the one with applicationId)" "${SUBDIR_GUESS:-app}"; fi
  FIRST=0
  SUBDIR="${SUBDIR#./}"; SUBDIR="${SUBDIR%/}"
  for gf in build.gradle.kts build.gradle; do
    [ -f "$REPO/$SUBDIR/$gf" ] && GRADLE_FILE="$REPO/$SUBDIR/$gf" && break
  done
  [ -n "$GRADLE_FILE" ] && break
  [ "$ASSUME_YES" = 1 ] && die "no build.gradle(.kts) in $SUBDIR/"
  warn "no build.gradle(.kts) in $SUBDIR/"
  # An easy slip: typing the application ID here (it is asked next).
  if printf '%s' "$SUBDIR" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'; then
    note "that looks like an application ID — this asks for a folder; the ID comes next"
  fi
done
[ "$ASK_ALL" = 1 ] && ok "gradle file: ${GRADLE_FILE#"$REPO"/}"

# --- detect identity and version
# Handles both Kotlin DSL (`applicationId = "x"`) and Groovy (`applicationId "x"`),
# ignores // comments, and takes the first hit. References like Flutter's
# `flutter.versionCode` are not values and are skipped.
gval() {
  sed -e 's,//.*,,' "$GRADLE_FILE" \
    | grep -Eo "(^|[^A-Za-z_.])$1[[:space:]]*(=[[:space:]]*)?[\"']?[A-Za-z0-9_.-]+" \
    | sed -E "s/.*$1[[:space:]]*(=[[:space:]]*)?[\"']?//" \
    | grep -v '^flutter\.' \
    | sed -n 1p
}
APPID_GUESS="$(gval applicationId)"
[ -n "$APPID_GUESS" ] || APPID_GUESS="$(gval namespace)"
VNAME_GUESS="$(gval versionName)"
VCODE_GUESS="$(gval versionCode)"

# Flutter: `version: 1.2.3+45` in pubspec.yaml is versionName+versionCode.
if [ -n "$FLUTTER_DIR" ] && [ -z "$VNAME_GUESS$VCODE_GUESS" ]; then
  PUBSPEC_VERSION="$(sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" \
                      "$REPO/$FLUTTER_DIR/pubspec.yaml" | sed -n 1p)"
  VNAME_GUESS="${PUBSPEC_VERSION%%+*}"
  case "$PUBSPEC_VERSION" in *+*) VCODE_GUESS="${PUBSPEC_VERSION#*+}" ;; esac
fi

while :; do
  auto APPID "Application ID" "$APPID_GUESS"
  printf '%s' "$APPID" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' && break
  [ "$ASSUME_YES" = 1 ] && die "'$APPID' is not a valid application ID"
  warn "'$APPID' is not a valid application ID (e.g. com.example.app)"
  APPID_GUESS=""
done
auto VNAME "versionName" "$VNAME_GUESS"
while :; do
  auto VCODE "versionCode" "$VCODE_GUESS"
  case "$VCODE" in ''|*[!0-9]*) [ "$ASSUME_YES" = 1 ] && die "versionCode '$VCODE' is not a plain integer"
                                warn "versionCode must be a plain integer"; VCODE_GUESS="" ;; *) break ;; esac
done

# A task is one store, one app, one version: from here on every answer and every
# milestone belongs to it. It can only be named now, since the version is part of
# the name — a new version is a new task, and a new branch in the fork.
state_load
if done_with TAG || done_with BRANCH || done_with MR || done_with RELEASE; then
  step "Where you left off"
  note "task: $(basename "${TASK_FILE%.conf}")"
  if done_with RUN;     then note "last run: $(recall ST_RUN)"; fi
  if done_with TAG;     then ok "tag pushed: $(recall ST_TAG)"; fi
  if done_with BRANCH;  then ok "branch on your fork: $(recall ST_BRANCH)"; fi
  if done_with MR;      then ok "merge request: $(recall ST_MR)"; fi
  if done_with RELEASE; then ok "release published: $(recall ST_RELEASE)"; fi
  note "each question below offers last time's answer; Enter keeps it"
  note "anything already done is checked, not repeated — and can be redone"
fi
remember ST_RUN "$(date '+%Y-%m-%d %H:%M')"

# --- tag: F-Droid builds the tag — so it must exist, be pushed, and hold
# exactly this application ID and version. The wizard sorts that out itself.
# The URL as configured: `remote get-url` would apply url.*.insteadOf rewrites,
# which say nothing about where the project lives on the web.
ORIGIN="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || echo "")"
GRADLE_REL="${GRADLE_FILE#"$REPO"/}"
PUB_REL=""
if [ -n "$FLUTTER_DIR" ]; then
  PUB_REL="pubspec.yaml"; [ "$FLUTTER_DIR" != "." ] && PUB_REL="$FLUTTER_DIR/pubspec.yaml"
fi
ref_appid() {  # ref_appid <git ref> — applicationId in the gradle file at that ref
  git -C "$REPO" show "$1:$GRADLE_REL" 2>/dev/null | sed -e 's,//.*,,' \
    | grep -Eo "(^|[^A-Za-z_.])applicationId[[:space:]]*(=[[:space:]]*)?[\"'][A-Za-z0-9_.]+" \
    | sed -E "s/.*applicationId[[:space:]]*(=[[:space:]]*)?[\"']//" | sed -n 1p
}
ref_version() {  # ref_version <git ref> — pubspec `name+code` at that ref (Flutter)
  [ -n "$PUB_REL" ] || return 0
  git -C "$REPO" show "$1:$PUB_REL" 2>/dev/null \
    | sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" | sed -n 1p
}
ref_matches() {  # ref_matches <ref> — true if it builds $APPID at $VNAME+$VCODE
  local a v
  a="$(ref_appid "$1")"; v="$(ref_version "$1")"
  { [ -z "$a" ] || [ "$a" = "$APPID" ]; } && { [ -z "$v" ] || [ "$v" = "$VNAME+$VCODE" ]; }
}
tag_on_remote() {
  [ -n "$ORIGIN" ] && git -C "$REPO" ls-remote --tags --exit-code origin "refs/tags/$1" >/dev/null 2>&1
}
remote_tag_sha() {  # what origin's copy of the tag points at (tag object, as local rev-parse gives)
  [ -n "$ORIGIN" ] || return 0
  git -C "$REPO" ls-remote origin "refs/tags/$1" 2>/dev/null | awk 'NR==1 {print $1}'
}

# --- AutoName
# fdroidserver reads android:label off the <application> element of the app's
# manifest and stores it as AutoName (common.py, fetch_real_name). CI runs
# `checkupdates --auto`, which does exactly that, and then fails the job on the
# diff it produced — so the field has to be in the file from the start. Working
# it out here means that gate no longer depends on checkupdates being able to
# run on this machine at all.
manifest_label() {  # manifest_label <AndroidManifest.xml> — the application label
  awk 'BEGIN { RS = ">" }
       /<application[[:space:]]/ {
         if (match($0, /android:label[ \t]*=[ \t]*"[^"]*"/)) {
           s = substr($0, RSTART, RLENGTH)
           sub(/^android:label[ \t]*=[ \t]*"/, "", s)
           sub(/"$/, "", s)
           print s
           exit
         }
       }' "$1" 2>/dev/null
}
find_autoname() {
  local m label name sx
  for m in ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/android/app/src/main/AndroidManifest.xml"} \
           "$REPO/$SUBDIR/src/main/AndroidManifest.xml" \
           "$REPO/app/src/main/AndroidManifest.xml" \
           "$REPO/src/main/AndroidManifest.xml"; do
    [ -f "$m" ] || continue
    label="$(manifest_label "$m")"
    [ -n "$label" ] || continue
    case "$label" in
      @string/*)  # resolve it from res/values/strings.xml, as fdroidserver does
        name="${label#@string/}"
        sx="$(dirname "$m")/res/values/strings.xml"
        [ -f "$sx" ] || return 0
        sed -n "s@.*<string[^>]*name=\"$name\"[^>]*>\([^<]*\)</string>.*@\\1@p" "$sx" | sed -n 1p
        return 0 ;;
      @*) return 0 ;;   # some other resource reference: leave it to the maintainers
      *) printf '%s' "$label"; return 0 ;;
    esac
  done
}
AUTONAME="$(find_autoname || true)"
if [ -n "$AUTONAME" ]; then
  ok "AutoName: $AUTONAME (android:label, the value CI expects)"
else
  note "no android:label found — CI's checkupdates may add an AutoName of its own"
fi

# --- the release itself
# F-Droid builds a tag and sees only what that tag holds, so the version bump
# and the "what's new" text have to be in the commit *before* it is tagged.
# Offered when the source version is already tagged and work has moved on: the
# commits since then cannot reach anyone without a new version.
# Commit titles as "- title" lines. Drops the "#123 " / "#{id} " ids some
# commit workflows put in front, and titles that tell a reader nothing: a bare
# file name ("../../commit-changes.md"), or three letters or fewer ("ok").
clean_notes() {  # stdin: one title per line
  sed -E 's/^#(\{id\}|[0-9]+)[[:space:]]+//' \
    | grep -Eiv '^[[:space:]]*$|^[./]*[a-z0-9_./-]+\.[a-z0-9]+$|^.{0,3}$|^(wip|update|updates|fixes)$' \
    | sed 's/^/- /'
}
log_notes() {  # log_notes <since-ref> — "- title" lines, oldest first
  if [ -n "$1" ]; then
    { git -C "$REPO" log --reverse --no-merges --pretty=format:'%s' "$1..HEAD"; echo; }
  else
    { git -C "$REPO" log --reverse --no-merges --pretty=format:'%s' -20; echo; }
  fi | clean_notes
}

# where the version lives, and what the next one would be
VER_FILE=""; VER_KIND=""
if [ -n "$PUB_REL" ] && [ -f "$REPO/$PUB_REL" ]; then VER_FILE="$REPO/$PUB_REL"; VER_KIND=pubspec
elif [ -n "$GRADLE_FILE" ] && [ -n "$(gval versionName)" ]; then VER_FILE="$GRADLE_FILE"; VER_KIND=gradle
fi
next_vname() {  # bump the last component: 0.1.0 -> 0.1.1
  printf '%s' "$1" | awk -F. -v OFS=. '{ $NF = $NF + 1; print }'
}

# F-Droid shows changelogs/<versionCode>.txt as "What's new"; the forge
# release below reuses it. Known here, not only inside the bump, so a version
# bumped by hand still gets its written notes rather than commit titles.
FL_BASE="$REPO/fastlane/metadata/android/en-US"
[ -n "$FLUTTER_DIR" ] && [ "$FLUTTER_DIR" != "." ] \
  && [ -d "$REPO/$FLUTTER_DIR/fastlane" ] && FL_BASE="$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US"

CUR_TAGGED=0
for t in "v$VNAME" "$VNAME"; do
  git -C "$REPO" rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1 && { CUR_TAGGED=1; break; }
done
LASTTAG="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)"
AHEAD=0
[ -n "$LASTTAG" ] && AHEAD="$(git -C "$REPO" rev-list --count "$LASTTAG..HEAD" 2>/dev/null || echo 0)"

if [ "$CUR_TAGGED" = 1 ] && [ "$AHEAD" -gt 0 ] && [ -n "$VER_FILE" ] && [ "$DRYRUN" = 0 ]; then
  warn "$AHEAD commit(s) since $LASTTAG, but ${VER_FILE#"$REPO"/} still says $VNAME+$VCODE"
  note "that version is already tagged, so those commits cannot be released as it"
  if confirm "Bump the version and make the release commit?" n; then
    ask NEW_VNAME "New versionName" "$(next_vname "$VNAME")"
    ask NEW_VCODE "New versionCode" "$((VCODE + 1))"

    # --- what's new: F-Droid shows changelogs/<versionCode>.txt from the repo.
    # Notes written ahead of time for this code win over commit titles.
    NOTES="$WORK/release-notes.txt"
    if [ -s "$FL_BASE/changelogs/$NEW_VCODE.txt" ]; then
      cp "$FL_BASE/changelogs/$NEW_VCODE.txt" "$NOTES"
      say "Release notes, from ${FL_BASE#"$REPO"/}/changelogs/$NEW_VCODE.txt:"
      EDIT_NOTES=n
    else
      log_notes "$LASTTAG" > "$NOTES"
      say "Release notes, from the $AHEAD commit(s) since $LASTTAG:"
      EDIT_NOTES=y
    fi
    printf '%s' "$DIM"; sed 's/^/   | /' "$NOTES"; printf '%s' "$R"
    [ "$EDIT_NOTES" = y ] && note "users see these as “What's new” — short, plain words work best"
    if [ "$ASSUME_YES" = 0 ] && confirm "Edit them before committing?" "$EDIT_NOTES"; then
      "${EDITOR:-${VISUAL:-vi}}" "$NOTES" || warn "editor exited non-zero — using the text as it stands"
    fi
    mkdir -p "$FL_BASE/changelogs"
    # With an ABI split, F-Droid publishes 10 * versionCode + 1/2/3, and
    # looks for a changelog named after the code it actually publishes. Which
    # split is used is settled later, so write every name it might look for —
    # the ones that never exist are simply ignored.
    CL_CODES="$NEW_VCODE"
    [ -n "$FLUTTER_DIR" ] && CL_CODES="$NEW_VCODE $((10 * NEW_VCODE + 1)) $((10 * NEW_VCODE + 2)) $((10 * NEW_VCODE + 3))"
    for c in $CL_CODES; do cp "$NOTES" "$FL_BASE/changelogs/$c.txt"; done
    ok "wrote ${FL_BASE#"$REPO"/}/changelogs/{$(echo "$CL_CODES" | tr ' ' ',')}.txt"

    # --- the bump itself
    case "$VER_KIND" in
      pubspec)
        awk -v v="$NEW_VNAME+$NEW_VCODE" 'BEGIN{done=0}
          !done && /^version:[[:space:]]/ { print "version: " v; done=1; next } { print }' \
          "$VER_FILE" > "$VER_FILE.new" && mv "$VER_FILE.new" "$VER_FILE" ;;
      gradle)
        awk -v n="$NEW_VNAME" -v c="$NEW_VCODE" 'BEGIN{dn=0;dc=0}
          !dn && sub(/versionName[[:space:]]*=?[[:space:]]*"[^"]*"/, "versionName = \"" n "\"") { dn=1 }
          !dc && sub(/versionCode[[:space:]]*=?[[:space:]]*[0-9]+/, "versionCode = " c) { dc=1 }
          { print }' "$VER_FILE" > "$VER_FILE.new" && mv "$VER_FILE.new" "$VER_FILE" ;;
    esac
    git -C "$REPO" --no-pager diff --stat -- "${VER_FILE#"$REPO"/}" | sed 's/^/     /'
    git -C "$REPO" --no-pager diff -- "${VER_FILE#"$REPO"/}" | grep -E '^[-+]version|^[-+].*version(Name|Code)' | sed 's/^/     /'

    auto RELMSG "Commit message" "Release $NEW_VNAME+$NEW_VCODE"
    if go "Commit the bump and the changelog?"; then
      git -C "$REPO" add -- "${VER_FILE#"$REPO"/}" "${FL_BASE#"$REPO"/}/changelogs"
      git -C "$REPO" commit -q -m "$RELMSG" || die "the release commit failed"
      HEAD_SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
      ok "committed $RELMSG ($HEAD_SHORT)"
      VNAME="$NEW_VNAME"; VCODE="$NEW_VCODE"
      if go "Push the commit to origin?"; then
        git -C "$REPO" push origin HEAD || warn "could not push — the tag push below will fail too"
      fi
    else
      git -C "$REPO" checkout -- "${VER_FILE#"$REPO"/}" 2>/dev/null || true
      warn "reverted the version bump; the changelog files are left in place"
    fi
  fi
fi

# Prefer an existing v<version> or <version> tag; else the usual v<version>.
TAG_GUESS="v$VNAME"
for t in "v$VNAME" "$VNAME"; do
  if git -C "$REPO" rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1; then TAG_GUESS="$t"; break; fi
done
auto TAG "Release tag" "$TAG_GUESS"

HEAD_SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
TAG_MOVED=0
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  warn "there is no tag $TAG yet"
  if ! ref_matches HEAD; then
    die "HEAD ($HEAD_SHORT) doesn't build $APPID $VNAME+$VCODE either — commit the release first"
  fi
  if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
    warn "you have uncommitted changes; the tag only covers what is committed"
  fi
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would tag HEAD ($HEAD_SHORT) as $TAG and push it"
  elif go "Tag HEAD ($HEAD_SHORT) as $TAG and push it to origin?"; then
    git -C "$REPO" tag "$TAG" HEAD
    git -C "$REPO" push origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "tagged and pushed $TAG"
    TAG_MOVED=1; remember ST_TAG "$TAG"
  else
    die "F-Droid needs the release tag — create and push $TAG, then re-run"
  fi
elif ! ref_matches "$TAG"; then
  # The classic slip: a tag made before the last change (ID, version…).
  warn "tag $TAG builds '$(ref_appid "$TAG")' $(ref_version "$TAG"), not '$APPID' $VNAME+$VCODE"
  if ref_matches HEAD && [ "$DRYRUN" = 0 ] \
     && confirm "Move $TAG to HEAD ($HEAD_SHORT) and force-push it? (only if it isn't published yet)" n; then
    git -C "$REPO" tag -f "$TAG" HEAD >/dev/null
    git -C "$REPO" push -f origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "moved $TAG to $HEAD_SHORT"
    TAG_MOVED=1; remember ST_TAG "$TAG"
  else
    die "tag $TAG doesn't hold this release — move it or bump the version"
  fi
elif ! tag_on_remote "$TAG"; then
  warn "tag $TAG is not on origin yet — F-Droid would not find it"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would push tag $TAG"
  elif go "Push tag $TAG to origin?"; then
    git -C "$REPO" push origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "pushed $TAG"
    remember ST_TAG "$TAG"
  else
    die "push the tag first: git push origin $TAG"
  fi
elif [ -n "$(remote_tag_sha "$TAG")" ] \
     && [ "$(remote_tag_sha "$TAG")" != "$(git -C "$REPO" rev-parse "$TAG" 2>/dev/null)" ]; then
  # Your local tag was moved but origin still has the old one. F-Droid builds
  # origin's copy, so this is the one that decides what gets built.
  warn "origin's $TAG is not your $TAG"
  note "origin: $(remote_tag_sha "$TAG" | cut -c1-12)   local: $(git -C "$REPO" rev-parse "$TAG" | cut -c1-12)"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would delete $TAG on origin and push yours"
  elif go "Delete $TAG on origin and push yours in its place?"; then
    git -C "$REPO" push origin ":refs/tags/$TAG" || die "could not delete $TAG on origin"
    git -C "$REPO" push origin "refs/tags/$TAG"  || die "could not push $TAG"
    ok "replaced $TAG on origin"
    TAG_MOVED=1; remember ST_TAG "$TAG"
  else
    die "F-Droid would build origin's $TAG, which is not this release"
  fi
else
  ok "tag $TAG is pushed and holds $APPID $VNAME+$VCODE"
  remember ST_TAG "$TAG"
fi
# fdroiddata wants the full commit hash in `commit:`, not the tag name.
COMMIT="$(git -C "$REPO" rev-list -n1 "$TAG" 2>/dev/null || true)"
[ -n "$COMMIT" ] || COMMIT="$TAG"

# --- a published release on the forge
# The metadata's Changelog: field points at the releases page, and a tag alone
# does not put anything there. Offered once the tag is pushed, because that is
# what a release is made from.
FORGE=""; FORGE_CLI=""
case "$ORIGIN" in
  *github.com[:/]*) FORGE=github; have gh   && gh auth status   >/dev/null 2>&1 && FORGE_CLI=gh ;;
  *gitlab.com[:/]*) FORGE=gitlab; have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1 && FORGE_CLI=glab ;;
esac
release_exists() {
  case "$FORGE_CLI" in
    gh)   ( cd "$REPO" && gh release view "$TAG" >/dev/null 2>&1 ) ;;
    glab) ( cd "$REPO" && glab release view "$TAG" >/dev/null 2>&1 ) ;;
    *)    return 1 ;;
  esac
}
if [ "$DRYRUN" = 0 ] && [ -n "$FORGE_CLI" ]; then
  NEED_RELEASE=1
  if release_exists; then
    remember ST_RELEASE "$TAG"
    if [ "$TAG_MOVED" = 1 ]; then
      # the release still names the tag, but the tag is a different commit now
      warn "$FORGE has a release for $TAG, and the tag moved in this run"
      if go "Delete that release and publish it again from the new tag?"; then
        case "$FORGE_CLI" in
          gh)   ( cd "$REPO" && gh release delete "$TAG" --yes ) >/dev/null 2>&1 || warn "could not delete the release" ;;
          glab) ( cd "$REPO" && glab release delete "$TAG" --yes ) >/dev/null 2>&1 || warn "could not delete the release" ;;
        esac
        if release_exists; then
          warn "the old release is still there — publish by hand"
          NEED_RELEASE=0
        fi
      else
        NEED_RELEASE=0
      fi
    else
      ok "$FORGE already has a release for $TAG"
      NEED_RELEASE=0
    fi
  fi
  if [ "$NEED_RELEASE" = 1 ]; then
    if ! release_exists; then
      warn "$TAG is a tag, but $FORGE has no release for it"
    fi
    note "your Changelog: URL points at the releases page, which is empty until one exists"
    if go "Publish a release for $TAG on $FORGE?"; then
      RELNOTES="$WORK/forge-notes.txt"
      # prefer the changelog F-Droid will show, so both say the same thing
      if [ -n "${FL_BASE:-}" ] && [ -f "$FL_BASE/changelogs/$VCODE.txt" ]; then
        cp "$FL_BASE/changelogs/$VCODE.txt" "$RELNOTES"
      else
        PREVTAG="$(git -C "$REPO" describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
        if [ -n "$PREVTAG" ]; then
          { git -C "$REPO" log --reverse --no-merges --pretty=format:'%s' "$PREVTAG..$TAG"; echo; } | clean_notes > "$RELNOTES"
        else
          { git -C "$REPO" log --reverse --no-merges --pretty=format:'%s' -20 "$TAG"; echo; } | clean_notes > "$RELNOTES"
        fi
      fi
      printf '%s' "$DIM"; sed 's/^/   | /' "$RELNOTES"; printf '%s' "$R"
      REL_OUT=""
      case "$FORGE_CLI" in
        gh)   REL_OUT="$( cd "$REPO" && gh release create "$TAG" --title "$TAG" \
                            --notes-file "$RELNOTES" 2>&1 || true )" ;;
        glab) REL_OUT="$( cd "$REPO" && glab release create "$TAG" --name "$TAG" \
                            --notes "$(cat "$RELNOTES")" 2>&1 || true )" ;;
      esac
      if release_exists; then
        ok "release published: ${WEB_GUESS:+$WEB_GUESS/releases/tag/$TAG}"
        remember ST_RELEASE "$TAG"
      else
        warn "$FORGE_CLI did not publish the release:"
        printf '%s\n' "$REL_OUT" | tail -5 | sed 's/^/       /'
        [ -n "$WEB_GUESS" ] && note "do it by hand: $WEB_GUESS/releases/new?tag=$TAG"
      fi
    fi
  fi
elif [ -n "$FORGE" ] && [ "$DRYRUN" = 0 ]; then
  note "no $FORGE CLI logged in — a release for $TAG would have to be published by hand"
fi

# --- URLs from the git remote
WEB_GUESS=""
case "$ORIGIN" in
  git@*)     WEB_GUESS="https://$(echo "$ORIGIN" | sed 's/^git@//; s/:/\//; s/\.git$//')" ;;
  ssh://*)   WEB_GUESS="https://$(echo "$ORIGIN" | sed 's,^ssh://\(git@\)\?,,; s,:[0-9]*/,/,; s/\.git$//')" ;;
  https://*) WEB_GUESS="${ORIGIN%.git}" ;;
esac
[ -n "$WEB_GUESS" ] || warn "no usable 'origin' remote — you will have to type the URLs"

# ----------------------------------------------------- 1b. common MR blockers
step "Pitfall check"
BLOCKERS=0
PROPRIETARY_PUB=""

# Binaries committed to the repo: F-Droid builds from source only.
BINFILES="$(git -C "$REPO" ls-files \
  | grep -Ei '\.(jar|aar|so|apk|aab|dex|keystore|jks|p12)$' \
  | grep -v 'gradle/wrapper/gradle-wrapper.jar' | head -10 || true)"
if [ -n "$BINFILES" ]; then
  warn "prebuilt binaries are tracked in git — maintainers will ask about these:"
  printf '%s\n' "$BINFILES" | sed "s/^/       /"
  BLOCKERS=$((BLOCKERS+1))
else
  ok "no stray prebuilt binaries tracked"
fi

# Proprietary dependencies: the usual cause of a NonFreeDep anti-feature or a reject.
PROPRIETARY="$(git -C "$REPO" grep -lEi \
  'com\.google\.android\.gms|com\.google\.firebase|crashlytics|play-services|com\.google\.mlkit|billingclient|appcenter|com\.google\.android\.play' \
  -- '*.gradle' '*.gradle.kts' '*.toml' 2>/dev/null | head -5 || true)"
if [ -n "$PROPRIETARY" ]; then
  warn "possible proprietary dependencies referenced in:"
  printf '%s\n' "$PROPRIETARY" | sed "s/^/       /"
  note "these usually need removing, or an AntiFeature such as NonFreeDep"
  BLOCKERS=$((BLOCKERS+1))
else
  ok "no obvious proprietary dependencies"
fi

# Release builds signed with the debug key (the Flutter template does this).
# F-Droid wants an unsigned APK to sign itself, and Play rejects debug keys.
if sed -e 's,//.*,,' "$GRADLE_FILE" \
     | grep -qE 'signingConfig[[:space:]]*=?[[:space:]]*signingConfigs\.(getByName\("debug"\)|debug)([^A-Za-z0-9_]|$)'; then
  warn "the release build is signed with the debug key (${GRADLE_FILE#"$REPO"/})"
  note "make the release signingConfig conditional on your key being present,"
  note "so builds without it — like F-Droid's — come out unsigned"
  BLOCKERS=$((BLOCKERS+1))
fi

# The Android Gradle Plugin signs a "Dependency metadata" block into every APK
# for Play Console. F-Droid's "check apk" job flags it, and nothing outside
# Play reads it, so reviewers ask for it to be switched off.
if ! git -C "$REPO" grep -qE 'includeInApk[[:space:]]*=?[[:space:]]*false' -- '*.gradle' '*.gradle.kts' 2>/dev/null; then
  warn "the APK will carry Google's \"Dependency metadata\" block — F-Droid's CI flags it"
  note "switch it off in ${GRADLE_FILE#"$REPO"/}:"
  note "  android { dependenciesInfo { includeInApk = false; includeInBundle = false } }"
fi

if [ -n "$FLUTTER_DIR" ]; then
  PUBSPEC="$REPO/$FLUTTER_DIR/pubspec.yaml"
  # Plugins that pull in Google Play services / Firebase / ads.
  PROPRIETARY_PUB="$(grep -oE '^[[:space:]]+(firebase_[a-z_]+|google_mobile_ads|google_sign_in|google_ml_kit[a-z_]*|in_app_purchase|in_app_review|play_integrity[a-z_]*|google_maps_flutter|flutter_facebook_[a-z_]+):' \
                      "$PUBSPEC" 2>/dev/null | tr -d ' :' | tr '\n' ' ' || true)"
  if [ -n "${PROPRIETARY_PUB// /}" ]; then
    warn "Flutter plugins that usually mean proprietary code: $PROPRIETARY_PUB"
    note "these usually need removing, or an AntiFeature such as NonFreeDep"
    BLOCKERS=$((BLOCKERS+1))
  else
    ok "no obvious proprietary Flutter plugins"
  fi
  # F-Droid pins one Flutter release per build; a dev/beta SDK constraint
  # means no stable Flutter can build the tag.
  if sed -n '/^environment:/,/^[^[:space:]]/p' "$PUBSPEC" | grep -qE 'sdk:.*[0-9]-[0-9A-Za-z]'; then
    warn "pubspec.yaml requires a pre-release Dart SDK — only a dev/master Flutter builds it"
    note "F-Droid maintainers expect a stable Flutter release; relax the 'sdk:' constraint"
    BLOCKERS=$((BLOCKERS+1))
  fi
fi

# Store listing: F-Droid reads it from the app repo, not from the .yml.
FASTLANE="$REPO/fastlane/metadata/android/en-US"
if [ -d "$FASTLANE" ] || [ -d "$REPO/metadata/en-US" ] || [ -d "$REPO/$SUBDIR/src/main/play" ] \
   || { [ -n "$FLUTTER_DIR" ] && [ -d "$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US" ]; }; then
  ok "store listing (fastlane/triple-t metadata) found in the repo"
else
  warn "no fastlane metadata — your F-Droid listing will have no description"
  note "F-Droid reads it from the app repo at the build tag, not from the .yml"
  if confirm "Create fastlane/metadata/android/en-US now?" y; then
    while :; do
      ask SUMMARY "Short description (max 80 chars)" ""
      [ "${#SUMMARY}" -le 80 ] && break
      warn "that is ${#SUMMARY} characters — F-Droid's limit is 80"
    done
    ask FULLDESC "Full description (one line is fine, edit the file later)" "$SUMMARY"
    mkdir -p "$FASTLANE"
    printf '%s\n' "$SUMMARY"  > "$FASTLANE/short_description.txt"
    printf '%s\n' "$FULLDESC" > "$FASTLANE/full_description.txt"
    ok "wrote ${FASTLANE#"$REPO"/}/{short,full}_description.txt"
    warn "commit these and move the tag '$TAG' onto that commit — F-Droid only"
    warn "sees what is in the tagged revision"
    BLOCKERS=$((BLOCKERS+1))
  fi
fi

# Screenshots and icon: optional, but a listing without them looks abandoned.
# Same fastlane tree, same rule — F-Droid only sees what the build tag holds.
IMGDIR=""
for d in "$FASTLANE/images" \
         ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US/images"}; do
  [ -d "$d" ] && { IMGDIR="$d"; break; }
done
SHOTS=0
[ -n "$IMGDIR" ] && SHOTS="$(find "$IMGDIR" -type f \
  \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -path '*creenshots/*' 2>/dev/null | wc -l)"
if [ "${SHOTS:-0}" -gt 0 ]; then
  ok "$SHOTS screenshot(s) in ${IMGDIR#"$REPO"/}"
  [ -f "$IMGDIR/icon.png" ] || note "no images/icon.png — F-Droid falls back to the app's launcher icon"
else
  warn "no screenshots — your F-Droid listing will show none"
  note "PNGs go in fastlane/metadata/android/en-US/images/phoneScreenshots/,"
  note "alongside icon.png and featureGraphic.png; commit them under the build tag"
fi

[ "$BLOCKERS" = 0 ] || { echo; confirm "Carry on despite the above?" y || exit 1; }

# ========================================================== 2. fdroiddata fork
step "2/5  Your fdroiddata fork"
# Who you are on GitLab: glab knows, if it's logged in.
GL_ME=""
if have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; then
  GL_ME="$(glab api user 2>/dev/null | grep -Eo '"username"[[:space:]]*:[[:space:]]*"[^"]+"' \
           | sed -n 1p | sed -E 's/.*"([^"]+)"$/\1/')"
fi
auto GLUSER "GitLab user" "${GL_ME:-${SAVED_GLUSER:-}}"
FORK_GUESS="git@gitlab.com:$GLUSER/fdroiddata.git"
# a remembered URL only counts if it belongs to this user
case "${SAVED_FORKURL:-}" in *[:/]"$GLUSER"/*) FORK_GUESS="$SAVED_FORKURL" ;; esac
auto FORKURL "Fork" "$FORK_GUESS"
# Always asked (Enter takes the default): the clone is large, so where it goes
# is yours to pick. --yes takes the default.
# what this app used last time beats a guess at where the clone might live
FD_DEF="${SAVED_FDROIDDATA:-$(recall FDROIDDATA)}"
ask FDROIDDATA "Local clone of fdroiddata" "${FD_DEF:-$HOME/fdroiddata}"
FDROIDDATA="${FDROIDDATA/#\~/$HOME}"
case "$FDROIDDATA" in /*) ;; *) FDROIDDATA="$PWD/$FDROIDDATA" ;; esac
FDROIDDATA="${FDROIDDATA%/}"

# The usual first-run failure is a fork that doesn't exist yet, which git only
# reports as "project not found or no permission". Forks of fdroiddata are
# public, so GitLab's API can tell us up front.
check_fork() {
  local p code
  p="$(fork_path "$FORKURL")"
  [ -n "$p" ] && have curl || return 0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "${GITLAB_API_ROOT:-https://gitlab.com/api/v4}/projects/$(printf '%s' "$p" | sed 's#/#%2F#g')" || echo 000)"
  case "$code" in
    200) ok "fork found: gitlab.com/$p"; return 0 ;;
    404) warn "there is no gitlab.com/$p yet"
         note "fork it (namespace $GLUSER): https://gitlab.com/fdroid/fdroiddata/-/forks/new"
         note "a fork this size can take a few minutes to appear"
         return 1 ;;
    *)   note "could not check the fork (HTTP $code) — trying anyway"; return 0 ;;
  esac
}

# Creating the fork: with glab when it's logged in, else GitLab's API with
# $GITLAB_TOKEN. GitLab copies the repo in the background, so wait for it.
# where upstream fdroiddata is cloned from (overridable for testing)

# glab works out which project it is acting on partly from the current
# directory's git remotes, even when -R and -H name the projects. The wizard's
# own cwd is the app's checkout, whose remote is usually GitHub, and glab then
# gives up with "None of the git remotes configured for this repository point
# to a known GitLab host. Configured remotes: github.com". Run it from the
# fdroiddata clone instead: both of its remotes are gitlab.com, and the branch
# being proposed actually exists there.



create_fork() {  # asks GitLab to fork fdroid/fdroiddata into your namespace
  local code
  if glab_ready; then
    glab api --method POST "projects/fdroid%2Ffdroiddata/fork" >/dev/null 2>&1 \
      || { warn "glab could not start the fork"; return 1; }
  else
    code="$(curl -s -o "$WORK/fork.json" -w '%{http_code}' --max-time 30 -X POST \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GL_API/projects/fdroid%2Ffdroiddata/fork" || echo 000)"
    case "$code" in
      2*) ;;
      *) warn "GitLab answered HTTP $code — the fork was not created"
         note "the token needs the 'api' scope"; return 1 ;;
    esac
  fi
  ok "fork requested"
}

wait_for_fork() {  # wait_for_fork <namespace/project> — until GitLab finishes copying
  local p="$1" s i
  say "GitLab is copying fdroiddata — this usually takes a few minutes…"
  for ((i = 0; i < 90; i++)); do  # ~15 minutes
    s="$(gitlab_get "projects/$(printf '%s' "$p" | sed 's#/#%2F#g')" | json_str import_status)"
    case "$s" in
      finished) printf '\n' >&2; ok "fork ready: gitlab.com/$p"; return 0 ;;
      failed)   printf '\n' >&2; warn "GitLab reports the fork failed — delete it on GitLab and retry"
                return 1 ;;
    esac
    printf '.' >&2; sleep 10
  done
  printf '\n' >&2; warn "still not ready after 15 minutes"; return 1
}

ensure_fork() {
  local p me
  check_fork && return 0
  p="$(fork_path "$FORKURL")"
  if [ -n "$p" ]; then
    if have glab && ! glab_ready && [ -z "${GITLAB_TOKEN:-}" ]; then
      note "glab is installed but not logged in to gitlab.com"
      if confirm "Log in with glab now, so it can create the fork?" y; then
        glab auth login --hostname gitlab.com || warn "glab login did not finish"
      fi
    fi
    if glab_ready || [ -n "${GITLAB_TOKEN:-}" ]; then
      # A fork lands in the logged-in account; it must be the one in the URL.
      me="$(gitlab_get user | json_str username)"
      if [ -n "$me" ] && [ "$me" != "${p%%/*}" ]; then
        warn "logged in to GitLab as '$me', but the fork URL is for '${p%%/*}' — not creating it"
      elif confirm "Create the fork gitlab.com/$p now?" y; then
        create_fork && wait_for_fork "$p" && return 0
      fi
    fi
  fi
  until check_fork; do
    confirm "Check again?" y || exit 0
  done
}

if [ -d "$FDROIDDATA/.git" ]; then
  ok "reusing $FDROIDDATA"
else
  ensure_fork
  # fdroiddata is huge; a full clone of the fork over SSH can be cut off
  # midway. The wizard only needs upstream to branch from and the fork to push
  # one branch to: so clone upstream over HTTPS (no login) with history but
  # no file contents (they load as needed), and add the fork as `origin`.
  say "cloning fdroiddata from upstream over HTTPS (history only — a minute or two)…"
  CLONE_T0=$SECONDS
  if ! git clone --filter=blob:none -o upstream "$FDROIDDATA_UPSTREAM" "$FDROIDDATA"; then
    die "could not clone $FDROIDDATA_UPSTREAM — check your connection and re-run"
  fi
  git -C "$FDROIDDATA" remote add origin "$FORKURL"
  ok "cloned in $((SECONDS - CLONE_T0))s; your fork is 'origin' (for pushing), fdroid's repo is 'upstream'"
fi

git -C "$FDROIDDATA" remote get-url upstream >/dev/null 2>&1 || \
  git -C "$FDROIDDATA" remote add upstream "$FDROIDDATA_UPSTREAM"
say "fetching upstream (git prints its own progress below)…"
FETCH_T0=$SECONDS
git -C "$FDROIDDATA" fetch upstream || die "could not fetch upstream fdroiddata"
ok "fetched upstream ($((SECONDS - FETCH_T0))s)"

UPBRANCH=master
git -C "$FDROIDDATA" rev-parse -q --verify "refs/remotes/upstream/$UPBRANCH" >/dev/null 2>&1 || UPBRANCH=main
BASE="upstream/$UPBRANCH"
ok "base: $BASE ($(git -C "$FDROIDDATA" rev-parse --short "$BASE"))"

# --- new app or update? the fork's own state does not decide this, upstream does
EXISTING=""
if git -C "$FDROIDDATA" cat-file -e "$BASE:metadata/$APPID.yml" 2>/dev/null; then
  EXISTING="$BASE:metadata/$APPID.yml"
  IS_UPDATE=1
  ok "$APPID is already in F-Droid — this is a version update"
else
  ok "$APPID is not in F-Droid yet — this is a new app"
fi

# A half-finished earlier run leaves changes behind that would block the checkout.
# Leftovers from an earlier run of this wizard for this same app (a dry run
# leaves the file behind) are reset without asking; anything else is asked.
DIRTY="$(git -C "$FDROIDDATA" status --porcelain --untracked-files=no | awk '{print $NF}')"
if [ -n "$DIRTY" ] && [ "$DIRTY" = "metadata/$APPID.yml" ]; then
  git -C "$FDROIDDATA" reset -q --hard
  note "reset the leftover metadata/$APPID.yml from an earlier run"
fi
if ! git -C "$FDROIDDATA" diff --quiet || ! git -C "$FDROIDDATA" diff --cached --quiet; then
  warn "$FDROIDDATA has uncommitted changes:"
  git -C "$FDROIDDATA" --no-pager diff --stat HEAD | sed 's/^/       /'
  if confirm "Discard them (this clone is only a scratch area)?" n; then
    git -C "$FDROIDDATA" reset -q --hard
  else
    die "commit or stash them first"
  fi
fi

# Branching off upstream (not off whatever the fork happened to be on) keeps the
# merge request to a single file change.
BRANCH="$APPID"
[ "$IS_UPDATE" = 1 ] && BRANCH="$APPID-$VCODE"
# Earlier attempts leave branches behind on the fork — a different versionCode,
# an abandoned try, a rejected merge request. They confuse nobody but you, and
# GitLab keeps offering to open merge requests from them.
if [ "$DRYRUN" = 0 ]; then
  STALE="$(git -C "$FDROIDDATA" ls-remote --heads origin "$APPID*" 2>/dev/null \
            | sed -n 's,.*refs/heads/,,p' | grep -vx "$BRANCH" || true)"
  if [ -n "$STALE" ]; then
    warn "older branches for this app on your fork:"
    printf '%s\n' "$STALE" | sed 's/^/       /'
    note "delete them only once their merge requests are closed or merged"
    if confirm "Delete them from your fork?" n; then
      for b in $STALE; do
        if git -C "$FDROIDDATA" push origin --delete "$b" >/dev/null 2>&1; then
          ok "deleted $b"
        else
          warn "could not delete $b"
        fi
      done
    fi
  fi
fi

git -C "$FDROIDDATA" checkout -q -B "$BRANCH" "$BASE" || die "could not create branch $BRANCH"
ok "branch: $BRANCH (off $BASE)"

# ================================================================ 3. metadata
step "3/5  Metadata"

# Every line of metadata/<appid>.yml is asked, one at a time, with the best
# default there is: the answer given last time, else the recipe this run starts
# from — F-Droid's own file for an update, your merge request's or your app
# repo's copy, or another app built the same way — else what was detected.
# Enter keeps a line, a new value replaces it, "-" leaves it out, and any field
# of the Build Metadata Reference can be added. F-Droid recipes differ app by
# app, so nothing goes into the file without being shown to you first.
have python3 || die "python3 is needed to read and write metadata/$APPID.yml (fdroidserver needs it too)"
cat > "$WORK/recipe.py" <<'PYRECIPE'
import os, re, sys

# recipe.py — reads and writes fdroiddata metadata for fdroid-submit.sh, which
# asks about it one line at a time. A field lives as a file: <dir>/top/<Key>,
# or <dir>/b/<n>/<key> for build entry n, holding the value, and beside it
# <name>.k holding its kind:
#   s  one line                    l  a list, one item per line
#   b  a block of text             a  anti-features: "Name" or "Name: why"
#   r  YAML kept exactly as written (a structure this file does not take apart)
# A <name>.del file in a result folder means: leave this field out.

# fdroidserver's own order (metadata.py: yaml_app_field_order, build_flags)
TOP_ORDER = [
    'Disabled', 'AntiFeatures', 'Categories', 'License', 'AuthorName',
    'AuthorEmail', 'AuthorWebSite', 'WebSite', 'SourceCode', 'IssueTracker',
    'Translation', 'Changelog', 'Donate', 'Liberapay', 'OpenCollective',
    'Bitcoin', 'Litecoin', '\n',
    'Name', 'AutoName', 'Summary', 'Description', '\n',
    'RequiresRoot', '\n',
    'RepoType', 'Repo', 'Binaries', '\n',
    'Builds', '\n',
    'AllowedAPKSigningKeys', '\n',
    'MaintainerNotes', '\n',
    'ArchivePolicy', 'AutoUpdateMode', 'UpdateCheckMode', 'UpdateCheckIgnore',
    'VercodeOperation', 'UpdateCheckName', 'UpdateCheckData', 'CurrentVersion',
    'CurrentVersionCode', '\n',
    'NoSourceSince',
]
TOP_KEYS = [k for k in TOP_ORDER if k != '\n']
BUILD_ORDER = [
    'versionName', 'versionCode', 'disable', 'commit', 'timeout', 'subdir',
    'submodules', 'sudo', 'init', 'patch', 'gradle', 'maven', 'output',
    'binary', 'srclibs', 'oldsdkloc', 'encoding', 'forceversion',
    'forcevercode', 'rm', 'extlibs', 'prebuild', 'androidupdate', 'target',
    'scanignore', 'scandelete', 'build', 'buildjni', 'ndk', 'preassemble',
    'gradleprops', 'antcommands', 'postbuild', 'novcheck', 'antifeatures',
]
# A script with a single command is written on one line, as rewritemeta does.
SCRIPTS = {'sudo', 'init', 'prebuild', 'build', 'postbuild'}
# Numbers and booleans: written plain, never quoted.
PLAIN = {'versionCode', 'CurrentVersionCode', 'ArchivePolicy', 'timeout',
         'RequiresRoot', 'submodules', 'oldsdkloc', 'forceversion',
         'forcevercode', 'novcheck'}
ANTIF = {'AntiFeatures', 'antifeatures'}

KEY = re.compile(r'^([A-Za-z0-9_][\w.-]*):(?:[ \t]+(.*?))?[ \t]*$')
BLOCK = {'|', '|-', '|+', '>', '>-', '>+'}


def indent(s):
    return len(s) - len(s.lstrip(' '))


def dedent(lines):
    real = [l for l in lines if l.strip()]
    if not real:
        return []
    cut = min(indent(l) for l in real)
    return [l[cut:] if l.strip() else '' for l in lines]


def unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        esc = {'n': '\n', 't': '\t', '"': '"', '\\': '\\', '/': '/', ' ': ' '}
        return re.sub(r'\\(.)', lambda m: esc.get(m.group(1), m.group(0)), s[1:-1])
    m = re.search(r'\s#', s)          # a comment after a plain value
    return s[:m.start()].rstrip() if m else s


def flow_list(s):
    s = s.strip()
    if s == '[]':
        return []
    return [unquote(x) for x in s[1:-1].split(',') if x.strip()]


def parse_map(lines):
    """[(key, kind, value)] from lines whose keys start at column 0."""
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip() or line[0] in ' #':
            i += 1
            continue
        m = KEY.match(line)
        if not m:
            i += 1
            continue
        key, rest = m.group(1), (m.group(2) or '')
        j = i + 1
        while j < n and (not lines[j].strip() or lines[j][0] == ' '):
            j += 1
        child = lines[i + 1:j]
        while child and not child[-1].strip():
            child.pop()
        if key == 'Builds' and not rest:
            out.append((key, 'B', parse_builds(child)))
        else:
            out.append(parse_value(key, rest, child))
        i = j
    return out


def parse_value(key, rest, child):
    if rest in BLOCK:
        return key, 'b', '\n'.join(dedent(child)).rstrip('\n')
    if rest.startswith('[') and rest.rstrip().endswith(']'):
        return antif(key, 'l', flow_list(rest))
    if rest.strip() == '{}':
        return key, 's', ''
    if rest:
        # a value on the key's line, maybe folded onto the lines after it
        val = ' '.join([rest] + [c.strip() for c in child if c.strip()])
        val = unquote(val)
        return (key, 'b', val) if '\n' in val else (key, 's', val)
    real = [c for c in child if c.strip()]
    if not real:
        return key, 's', ''
    at = min(indent(c) for c in real)
    first = real[0][at:]
    if first.startswith('- ') or first == '-':
        items = []
        for c in child:
            if not c.strip():
                continue
            if indent(c) == at and (c[at:].startswith('- ') or c[at:] == '-'):
                items.append(c[at + 2:].strip())
            elif items:                    # an item folded onto more lines
                items[-1] += ' ' + c.strip()
        return antif(key, 'l', [unquote(x) for x in items])
    if KEY.match(first):
        if key in ANTIF:
            return antif_map(key, dedent(child))
        return key, 'r', dedent(child)
    val = unquote(' '.join(c.strip() for c in real))
    return (key, 'b', val) if '\n' in val else (key, 's', val)


def antif(key, kind, items):
    return (key, 'a', items) if key in ANTIF else (key, kind, items)


def antif_map(key, lines):
    """Anti-features with reasons; kept as written unless every reason is en-US."""
    out = []
    for name, kind, val in parse_map(lines):
        if kind == 's':
            out.append(name + (': ' + val if val else ''))
            continue
        if kind != 'r':
            return key, 'r', lines
        locs = parse_map(val)
        if any(k != 'en-US' or kd != 's' for k, kd, _ in locs):
            return key, 'r', lines
        why = locs[0][2] if locs else ''
        out.append(name + (': ' + why if why else ''))
    return key, 'a', out


def parse_builds(child):
    real = [c for c in child if c.strip()]
    if not real:
        return []
    at = min(indent(c) for c in real)
    entries, cur = [], None
    for c in child:
        if not c.strip():
            if cur is not None:
                cur.append('')
            continue
        if indent(c) == at and c[at:].startswith('- '):
            cur = [' ' * (at + 2) + c[at + 2:]]
            entries.append(cur)
        elif cur is not None:
            cur.append(c)
    return [parse_map([l[at + 2:] if l.strip() else '' for l in e]) for e in entries]


# ---------------------------------------------------------------- field files
def write_field(d, name, kind, value):
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name)
    with open(p, 'w') as f:
        if kind in ('l', 'a', 'r'):
            f.write(''.join(v + '\n' for v in value))
        else:
            f.write(value + '\n')
    with open(p + '.k', 'w') as f:
        f.write(kind + '\n')


def read_field(p):
    try:
        kind = open(p + '.k').read().strip() or 's'
    except FileNotFoundError:
        kind = 's'
    text = open(p).read()
    if kind in ('l', 'a'):
        return kind, [l for l in text.split('\n') if l.strip()]
    if kind == 'r':
        lines = text.split('\n')
        while lines and not lines[-1].strip():
            lines.pop()
        return kind, lines
    return kind, text.rstrip('\n')


def read_dir(d, order):
    """{name: (kind, value)} for the fields in d, and the names to leave out."""
    fields, dels = {}, set()
    if not os.path.isdir(d):
        return fields, dels
    names = sorted(os.listdir(d))
    for f in names:
        p = os.path.join(d, f)
        if f.endswith('.del'):
            dels.add(f[:-4])
        elif not f.endswith('.k') and os.path.isfile(p):
            fields[f] = read_field(p)
    known = [k for k in order if k in fields]
    rest = [k for k in fields if k not in order]
    return {k: fields[k] for k in known + rest}, dels


def read_entries(d):
    out, n = [], 1
    while os.path.isdir(os.path.join(d, 'b', str(n))):
        fields, _ = read_dir(os.path.join(d, 'b', str(n)), BUILD_ORDER)
        out.append(fields)
        n += 1
    return out


def write_entries(d, entries):
    for n, e in enumerate(entries, 1):
        for k, (kind, v) in e.items():
            write_field(os.path.join(d, 'b', str(n)), k, kind, v)
    with open(os.path.join(d, 'b.count'), 'w') as f:
        f.write('%d\n' % len(entries))


# ---------------------------------------------------------------- commands
def cmd_load(path, out):
    """Take a metadata file apart into field files."""
    lines = open(path, encoding='utf-8').read().split('\n')
    os.makedirs(os.path.join(out, 'top'), exist_ok=True)
    order, entries = [], []
    for key, kind, val in parse_map(lines):
        if kind == 'B':
            entries = [{k: (kd, v) for k, kd, v in e} for e in val]
            continue
        write_field(os.path.join(out, 'top'), key, kind, val)
        order.append(key)
    with open(os.path.join(out, 'top.order'), 'w') as f:
        f.write(''.join(k + '\n' for k in order))
    write_entries(out, entries)


def code_of(e):
    try:
        return int(e.get('versionCode', ('s', '0'))[1])
    except ValueError:
        return 0


def evalop(op, vcode):
    expr = op.replace('%c', str(vcode))
    if not re.fullmatch(r'[\d\s+\-*/()]+', expr):
        raise ValueError(op)
    return int(eval(expr.replace('//', '/').replace('/', '//')))


def cmd_template(gdir, ddir, kind, out, vcode):
    """The new build entries: the generator's, on top of the base recipe's.

    The version lines are always this run's. Everything else comes from the
    base when there is one: the previous release's entries for an update or an
    unmerged merge request, the newest entry of another app for a reference.
    """
    gen = read_entries(gdir)
    base = read_entries(ddir)
    version = ('versionName', 'versionCode', 'commit')

    def bump(new, g):
        # a Flutter srclib follows the version this run detected
        if 'srclibs' in new and 'srclibs' in g:
            gf = [x for x in g['srclibs'][1] if x.startswith('flutter@')]
            if gf and gf[0] != 'flutter@stable':
                new['srclibs'] = (new['srclibs'][0],
                                  [gf[0] if x.startswith('flutter@') else x
                                   for x in new['srclibs'][1]])
        return new

    def from_base(e, g, keep=()):
        new = dict(e)
        for k in version + tuple(keep):
            if k in g:
                new[k] = g[k]
            else:
                new.pop(k, None)
        return bump(new, g)

    entries = gen
    if base and kind in ('upstream', 'fork', 'app'):
        last = base[-1].get('versionName', ('s', ''))[1]
        group = []
        for e in reversed(base):
            if e.get('versionName', ('s', ''))[1] != last:
                break
            group.insert(0, e)
        group.sort(key=code_of)
        ops = []
        if os.path.isfile(os.path.join(ddir, 'top', 'VercodeOperation')):
            ops = read_field(os.path.join(ddir, 'top', 'VercodeOperation'))[1]
        if len(gen) == 1 and len(group) > 1 and len(ops) == len(group):
            # one APK per CPU type: each entry's code from the app's own
            try:
                codes = sorted(evalop(op, vcode) for op in ops)
                entries = []
                for e, c in zip(group, codes):
                    new = from_base(e, gen[0])
                    new['versionCode'] = ('s', str(c))
                    entries.append(new)
            except (ValueError, SyntaxError):
                entries = [from_base(base[-1], g) for g in gen]
        elif len(group) == len(gen):
            entries = [from_base(e, g) for e, g in zip(group, sorted(gen, key=code_of))]
        else:
            entries = [from_base(base[-1], g) for g in gen]
    elif base and kind == 'reference':
        # another app's build steps; where its source lives is its own business
        entries = [from_base(base[-1], g, keep=('subdir', 'binary')) for g in gen]
    write_entries(out, [{k: e[k] for k in order_build(e)} for e in entries])


def order_build(e):
    return [k for k in BUILD_ORDER if k in e] + [k for k in e if k not in BUILD_ORDER]


# ---------------------------------------------------------------- writing YAML
NUMBERISH = re.compile(
    r'(?i)(true|false|null|~|[-+]?(\d[\d_]*|\.\d+|\d[\d_]*\.\d*)([eE][-+]?\d+)?'
    r'|[-+]?\.(inf|nan)|0x[0-9a-f]+|0o[0-7]+)')


def q(v, key=''):
    """v as a YAML scalar, quoted only when it has to be."""
    if key in PLAIN and re.fullmatch(r'-?\d+|true|false', v):
        return v
    if v == '':
        return "''"
    if '\n' in v:
        return '"' + v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
    need = (v != v.strip() or v[0] in "!&*|>'\"%@`#,[]{}" or v[:2] in ('- ', '? ', ': ')
            or v in ('-', '?', ':') or ': ' in v or ' #' in v or v.endswith(':')
            or '\t' in v or NUMBERISH.fullmatch(v))
    return "'" + v.replace("'", "''") + "'" if need else v


def af_lines(items, ind):
    pairs = []
    for it in items:
        name, _, why = it.partition(':')
        pairs.append((name.strip(), why.strip()))
    if not any(w for _, w in pairs):
        return ['%s- %s' % (ind, n) for n, _ in sorted(pairs, key=lambda p: p[0].lower())]
    out = []
    for n, w in pairs:
        if w:
            out += ['%s%s:' % (ind, n), '%s  en-US: %s' % (ind, q(w))]
        else:
            out.append('%s%s: {}' % (ind, n))
    return out


def render_top(key, kind, v):
    if kind == 's':
        return ['%s: %s' % (key, q(v, key))]
    if kind == 'b':
        return ['%s: |-' % key] + [('  ' + l) if l else '' for l in v.split('\n')]
    if kind == 'l':
        return ['%s:' % key] + ['  - %s' % q(x) for x in v]
    if kind == 'a':
        return ['%s:' % key] + af_lines(v, '  ')
    return ['%s:' % key] + v


def render_entry(e):
    out = []
    for i, k in enumerate(order_build(e)):
        kind, v = e[k]
        lead = '  - ' if i == 0 else '    '
        if kind == 'l' and k in SCRIPTS and len(v) == 1:
            kind, v = 's', v[0]
        if kind == 's':
            out.append('%s%s: %s' % (lead, k, q(v, k)))
        elif kind == 'l':
            out += ['%s%s:' % (lead, k)] + ['      - %s' % q(x) for x in v]
        elif kind == 'b':
            out += ['%s%s: |-' % (lead, k)] + [('      ' + l) if l else '' for l in v.split('\n')]
        elif kind == 'a':
            out += ['%s%s:' % (lead, k)] + af_lines(v, '      ')
        else:
            out += ['%s%s:' % (lead, k)] + [('    ' + l) if l else '' for l in v]
    return out


def group_of(k):
    g = 0
    for x in TOP_ORDER:
        if x == '\n':
            g += 1
        elif x == k:
            return g
    return g + 1


def canon(k):
    return TOP_KEYS.index(k) if k in TOP_KEYS else len(TOP_KEYS)


def segments(lines):
    """The base file as [key or None, lines]: fields, and what lies between."""
    segs, i, n = [], 0, len(lines)
    while i < n:
        l = lines[i]
        m = KEY.match(l) if l and l[0] not in ' #' else None
        if not m:
            segs.append([None, [l]])
            i += 1
            continue
        j = i + 1
        while j < n and (not lines[j].strip() or lines[j][0] == ' '):
            j += 1
        body, k = lines[i:j], j - i
        while k > 1 and not body[k - 1].strip():
            k -= 1
        segs.append([m.group(1), body[:k]])
        segs += [[None, [b]] for b in body[k:]]
        i = j
    return segs


def cmd_render(base, rdir, out, mode):
    """Write the recipe: the base file with every answered field put in place.

    Fields nobody touched stay exactly as they were written, so an update's
    merge request shows only what changed; new ones go where fdroidserver
    would put them. mode keep|replace: the base's own build entries stay in
    front of the new ones, or go.
    """
    top, dels = read_dir(os.path.join(rdir, 'top'), TOP_KEYS)
    new = [render_entry(e) for e in read_entries(rdir)]
    lines = []
    if base != '-' and os.path.isfile(base):
        lines = open(base, encoding='utf-8').read().split('\n')
    segs = segments(lines)
    if not any(s[0] for s in segs):
        segs = []

    def builds_lines(old):
        body = ['Builds:']
        if mode == 'keep' and old:
            kept = old[1:]
            while kept and not kept[-1].strip():
                kept.pop()
            if kept:
                body += kept + ['']
        for i, e in enumerate(new):
            body += ([''] if i else []) + e
        return body

    done = set()
    for s in segs:
        k = s[0]
        if k is None:
            continue
        if k == 'Builds':
            s[1] = builds_lines(s[1])
        elif k in dels:
            s[1] = None
        elif k in top:
            s[1] = render_top(k, *top[k])
        done.add(k)
    segs = [s for s in segs if s[1] is not None]
    missing = [k for k in top if k not in done]
    if 'Builds' not in done and new:
        missing.append('Builds')
    missing.sort(key=canon)

    def block(k):
        return builds_lines(None) if k == 'Builds' else render_top(k, *top[k])

    if not segs:
        # a fresh file: fdroidserver's groups, a blank line between them
        groups, cur = [], []
        for k in TOP_ORDER:
            if k == '\n':
                if cur:
                    groups.append(cur)
                cur = []
            elif k in missing:
                cur += block(k)
        if cur:
            groups.append(cur)
        rest = [k for k in missing if k not in TOP_KEYS]
        if rest:
            groups.append(sum((block(k) for k in rest), []))
        lines = []
        for g in groups:
            lines += ([''] if lines else []) + g
    else:
        for k in missing:
            # right before the first field fdroidserver writes after it, with a
            # blank line wherever that crosses one of its groups
            at = next((i for i, s in enumerate(segs) if s[0] and canon(s[0]) > canon(k)), len(segs))
            ins = [[k, block(k)]]
            if at < len(segs) and group_of(segs[at][0]) != group_of(k):
                ins.append([None, ['']])
            if at and segs[at - 1][0] and group_of(segs[at - 1][0]) != group_of(k):
                ins.insert(0, [None, ['']])
            segs[at:at] = ins
        lines = sum((s[1] for s in segs), [])
    # one blank line at most between fields, none at the ends
    tidy = []
    for l in lines:
        if not l.strip() and (not tidy or not tidy[-1].strip()):
            continue
        tidy.append(l.rstrip() if not l.strip() else l)
    while tidy and not tidy[-1].strip():
        tidy.pop()
    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(tidy) + '\n')


# ---------------------------------------------------------------- CI's wrapping
# fdroiddata's CI runs `fdroid rewritemeta` with Debian trixie's ruamel.yaml
# 0.18.10, whose plain-scalar writer gives a word longer than the line (80)
# a line of its own: `output: ` with a trailing space, the path below it.
# ruamel.yaml 0.19 dropped that rule, so a newer local fdroid writes such a
# value on one line and CI's rewritemeta job then fails on the difference.
# Everything else wraps the same in both, so only values holding a word over
# 80 characters are rewritten, with 0.18.10's write_plain replayed exactly.
WIDTH = 80
MAPLINE = re.compile(r'^( *)(- )?([A-Za-z0-9_][\w.-]*):(?: (.*))?$')
SEQLINE = re.compile(r'^( *)- (.*)$')


def plain(v):
    return v and v[0] not in "'\"|>[{&*!"


def flow018(head, column, indent, text, whitespace):
    out = [head]

    def write(s):
        out[-1] += s

    if not whitespace:
        write(' ')
        column += 1
    spaces, start, end = False, 0, 0
    while end <= len(text):
        ch = text[end] if end < len(text) else None
        if spaces:
            if ch != ' ':
                if start + 1 == end and column > WIDTH:
                    out.append(' ' * indent)
                    column = indent
                else:
                    write(text[start:end])
                    column += end - start
                start = end
        elif ch is None or ch == ' ':
            data = text[start:end]
            if len(data) > WIDTH and column > indent:
                out.append(' ' * indent)
                column = indent
            write(data)
            column += len(data)
            start = end
        if ch is not None:
            spaces = ch == ' '
        end += 1
    return out


def cmd_ciwrap(path, every=False):
    """every: wrap all values (for a file no local rewritemeta has formatted)."""
    lines = open(path, encoding='utf-8').read().split('\n')
    out, i, n, changed = [], 0, len(lines), []
    while i < n:
        line = lines[i]
        m, s = MAPLINE.match(line), SEQLINE.match(line)
        if m:
            col = len(m.group(1)) + (2 if m.group(2) else 0)
            indent, val = col + 2, (m.group(4) or '').strip()
            head = line[:len(m.group(1)) + (2 if m.group(2) else 0) + len(m.group(3)) + 1]
            whitespace = False
        elif s and not MAPLINE.match(' ' * len(s.group(1)) + '  ' + s.group(2)):
            indent = len(s.group(1)) + 2
            val, head, whitespace = s.group(2).strip(), line[:indent], True
        else:
            out.append(line)
            i += 1
            continue
        if val in ('|', '|-', '|+', '>', '>-', '>+'):
            # a block of text: copy it as it is
            out.append(line)
            i += 1
            while i < n and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent - 2):
                out.append(lines[i])
                i += 1
            continue
        j = i + 1
        while (j < n and lines[j].strip() and len(lines[j]) - len(lines[j].lstrip()) == indent
               and not SEQLINE.match(lines[j]) and not MAPLINE.match(lines[j])):
            j += 1
        text = ' '.join([val] + [l.strip() for l in lines[i + 1:j]]).strip()
        if not val and j == i + 1:
            out.append(line)                 # a key with a list or a map below it
            i += 1
            continue
        if plain(text) and (every or any(len(w) > WIDTH for w in text.split(' '))):
            new = flow018(head, len(head), indent, text, whitespace)
            if new != lines[i:j]:
                changed.append((m.group(3) if m else '-') + ' (line %d)' % (i + 1))
            out += new
        else:
            out += lines[i:j]
        i = j
    if changed:
        with open(path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(out))
        print('\n'.join(changed))


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'load':
        cmd_load(sys.argv[2], sys.argv[3])
    elif cmd == 'template':
        cmd_template(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]))
    elif cmd == 'render':
        cmd_render(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == 'ciwrap':
        cmd_ciwrap(sys.argv[2], len(sys.argv) > 3 and sys.argv[3] == 'all')
    else:
        sys.exit('recipe.py: unknown command ' + cmd)
PYRECIPE
rcp() { python3 "$WORK/recipe.py" "$@"; }
# the recipe it starts from, what this run would write itself, the new build
# entries before they are asked about, and the answers
RD="$WORK/d"; RG="$WORK/g"; RT="$WORK/t"; RR="$WORK/r"
rm -rf "$RD" "$RG" "$RT" "$RR"; mkdir -p "$RD/top" "$RR/top"

# --- every field, in fdroidserver's order, with what it is for
# kind: s one line · l a list · b paragraphs · a anti-features ("Name: why")
declare -A FHELP=() FKIND=()
FTOP=""; FBUILD=""
fdef() {  # fdef top|build <name> <kind> <help>
  FKIND["$1:$2"]="$3"; FHELP["$1:$2"]="$4"
  if [ "$1" = top ]; then FTOP="$FTOP $2"; else FBUILD="$FBUILD $2"; fi
}
fdef top Disabled s "stops F-Droid building the app; the value says why"
fdef top AntiFeatures a "what users may not want: ads, tracking, non-free network services or parts"
fdef top Categories l "what the app is, from fdroiddata's list"
fdef top License s "the SPDX id of the app's license, e.g. GPL-3.0-or-later"
fdef top AuthorName s "shown on f-droid.org — any name will do, it needn't be your real one"
fdef top AuthorEmail s "public in fdroiddata"
fdef top AuthorWebSite s "the author's site"
fdef top WebSite s "the app's site"
fdef top SourceCode s "where the source can be read"
fdef top IssueTracker s "where bugs are reported"
fdef top Translation s "where the app is translated (Weblate, Crowdin…)"
fdef top Changelog s "where the release notes are"
fdef top Donate s "a page that takes donations"
fdef top Liberapay s "the Liberapay name, not the URL"
fdef top OpenCollective s "the OpenCollective name, not the URL"
fdef top Bitcoin s "a Bitcoin address for donations"
fdef top Litecoin s "a Litecoin address for donations"
fdef top Name s "the name F-Droid shows, when it should differ from the app's own"
fdef top AutoName s "the app's android:label — CI fills it in when it is missing"
fdef top Summary s "one line about the app — normally read from fastlane in your repo"
fdef top Description b "the long description — normally read from fastlane in your repo"
fdef top RequiresRoot s "true if the app needs root on the phone"
fdef top RepoType s "git, almost always"
fdef top Repo s "the address F-Droid clones the source from"
fdef top Binaries s "where your signed APKs are, for reproducible builds (%v is the version)"
fdef top AllowedAPKSigningKeys l "the SHA-256 of your signing certificate, for reproducible builds"
fdef top MaintainerNotes b "notes for F-Droid's maintainers: why the recipe is the way it is"
fdef top ArchivePolicy s "how many old versions stay available (a number)"
fdef top AutoUpdateMode s "Version: F-Droid adds new versions by itself · None: you send a merge request"
fdef top UpdateCheckMode s "how new versions are found: Tags, Tags <regex>, RepoManifest, HTTP, Static or None"
fdef top UpdateCheckIgnore s "a regex of versions the update check skips"
fdef top VercodeOperation l "formulas from the app's versionCode to each build's, e.g. 10 * %c + 1"
fdef top UpdateCheckName s "the application id the update check looks for, when the source has several"
fdef top UpdateCheckData s "where the update check reads versions: file|code regex|file|name regex"
fdef top CurrentVersion s "the newest version F-Droid offers"
fdef top CurrentVersionCode s "its versionCode"
fdef top NoSourceSince s "the version since which the source is gone"
fdef build versionName s "the version this entry builds"
fdef build versionCode s "its versionCode — the APK must carry exactly this one"
fdef build disable s "skips this entry; the value says why"
fdef build commit s "the commit to build: the full hash (a tag works, reviewers prefer the hash)"
fdef build timeout s "seconds the build may take (the default is 2 hours)"
fdef build subdir s "the folder the build runs in: the Gradle module, or the project"
fdef build submodules s "true to check out the git submodules too"
fdef build sudo l "commands run as root first, e.g. apt-get install -y rustup"
fdef build init l "commands run right after the checkout, before anything else"
fdef build patch l "patch files from fdroiddata, applied before the build"
fdef build gradle l "the Gradle flavour to build, or yes for the default one"
fdef build maven s "build with Maven instead (yes, or a module)"
fdef build output s "the APK the build leaves, when it is not the usual Gradle one"
fdef build binary s "the address of your signed APK, for reproducible builds"
fdef build srclibs l "other source trees the build needs, as name@ref"
fdef build oldsdkloc s "true for very old projects that keep sdk.dir elsewhere"
fdef build encoding s "the source files' encoding, when it is not UTF-8"
fdef build forceversion s "true to force versionName into the manifest"
fdef build forcevercode s "true to force versionCode into the manifest"
fdef build rm l "files and folders deleted before the build, e.g. a proprietary.gradle"
fdef build extlibs l "libraries from fdroiddata's extlib folder"
fdef build prebuild l "commands run before the build: sed out non-free parts, set things up"
fdef build androidupdate l "projects to run android update on (old Ant builds)"
fdef build target s "the Android target to build against (old Ant builds)"
fdef build scanignore l "paths the source scanner skips — reviewers ask to avoid it"
fdef build scandelete l "paths deleted after the scan, e.g. a downloaded cache"
fdef build build l "commands that build the app, instead of plain Gradle"
fdef build buildjni l "folders to run ndk-build in (yes for the default one)"
fdef build ndk s "the NDK version, when the app has native code (r27c, or 27.2.12479018)"
fdef build preassemble l "Gradle tasks run before assemble"
fdef build gradleprops l "-P properties passed to Gradle, as name=value"
fdef build antcommands l "Ant targets (old Ant builds)"
fdef build postbuild l "commands run after the build"
fdef build novcheck s "true to skip the check that the APK's version matches"
fdef build antifeatures a "anti-features of this version only"

# --- one line at a time
# A line lives as a file under $RR (see recipe.py): the value, and beside it
# <name>.k, its kind. Answers are remembered per task, so a re-run offers them.
fv()   { [ -f "$1" ] && cat "$1" || true; }        # a field's value
fk()   { cat "$1.k" 2>/dev/null || echo s; }        # its kind
mkey() { printf 'Y_%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }
rset() {  # rset <rel> <kind> <value> — a line of the result
  local f="$RR/$1"
  mkdir -p "${f%/*}"; rm -f "$f.del"
  if [ -n "$3" ]; then printf '%s\n' "$3" > "$f"; else : > "$f"; fi
  printf '%s\n' "$2" > "$f.k"
}
rdel() {  # rdel <rel> — the result leaves this line out
  local f="$RR/$1"
  mkdir -p "${f%/*}"; rm -f "$f" "$f.k"; : > "$f.del"
}
akind() {  # akind <scope> <name> <field file> — how to ask about it
  local k t
  k="$(fk "$3")"; t="${FKIND[$1:$2]:-}"
  case "$k" in r) printf 'r'; return ;; esac
  printf '%s' "${t:-$k}"
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

yhelp() {  # yhelp <scope> <name> — the grey line saying what a field is for
  [ -n "${FHELP[$1:$2]:-}" ] && note "$2 — ${FHELP[$1:$2]}"
  return 0
}

# What reviewers say about a line, shown with it.
yhint() {  # yhint <scope> <name> <value>
  local n="$2" v="$3"
  case "$n" in
    srclibs)
      if printf '%s\n' "$v" | grep -qi '^rustup@'; then
        warn "reviewers ask for Debian's rustup instead of the rustup srclib:"
        note "drop it here, and add 'apt-get install -y rustup' to sudo:"
      fi ;;
    scanignore)
      [ -n "$v" ] && warn "reviewers ask not to hide files from the scanner: delete them (rm:, prebuild:) or bring them in as a srclib" ;;
    sudo)
      if printf '%s\n' "$v" | grep -q 'openjdk'; then
        note "the build server already has JDKs — reviewers ask to drop a JDK install unless the build needs that one"
      fi
      if [ -n "$HAS_RUST" ] && ! printf '%s\n' "$v" | grep -q rustup; then
        note "this project has Rust code: Debian's rustup goes here, as apt-get install -y rustup"
      fi ;;
    gradle)
      [ -n "${FLAVOURS// /}" ] && note "product flavours in ${GRADLE_FILE#"$REPO"/}: $FLAVOURS" ;;
    ndk)
      [ -n "$NATIVE" ] && note "native code: $NATIVE" ;;
    UpdateCheckMode)
      if [ "${MANIFESTS:-0}" -gt 20 ]; then
        note "$MANIFESTS AndroidManifest.xml files in the repo: with Tags, checkupdates reads them all"
        note "and gives up — Fennec uses None for that reason"
      fi ;;
  esac
  return 0
}

ycheck() {  # ycheck <scope> <name> <value> — false, with a warning, if fdroiddata would refuse it
  local n="$2" v="$3"
  case "$n" in
    versionCode|CurrentVersionCode|timeout|ArchivePolicy)
      case "$v" in *[!0-9]*) warn "$n is a whole number"; return 1 ;; esac
      if [ "$n" = versionCode ] || [ "$n" = CurrentVersionCode ]; then
        [ "$v" -le 2100000000 ] || { warn "Android allows versionCode up to 2100000000"; return 1; }
      fi ;;
    RequiresRoot|submodules|oldsdkloc|forceversion|forcevercode|novcheck)
      case "$v" in true|false) ;; *) warn "$n is true or false"; return 1 ;; esac ;;
    RepoType)
      case "$v" in git|git-svn|hg|srclib) ;; *) warn "RepoType is git, git-svn, hg or srclib"; return 1 ;; esac ;;
    UpdateCheckMode)
      printf '%s' "$v" | grep -qE '^(None|Static|HTTP|RepoManifest(/.+)?|Tags( .*)?)$' \
        || { warn "UpdateCheckMode is Tags, Tags <regex>, RepoManifest[/branch], HTTP, Static or None"; return 1; } ;;
    AutoUpdateMode)
      printf '%s' "$v" | grep -qE '^(None|Version|Version( \+.+)? [^+].+)$' \
        || { warn "AutoUpdateMode is None, Version, or Version with a tag pattern"; return 1; } ;;
    ndk)
      printf '%s' "$v" | grep -qE '^(r[0-9]+([b-e]?|-.*)|[0-9.]+)$' \
        || { warn "ndk looks like r27c or 27.2.12479018"; return 1; } ;;
    subdir|output)
      case "$v" in .|./*) warn "$n is written without ./ (and . means: leave it out)"; return 1 ;; esac ;;
    SourceCode|IssueTracker|WebSite|Changelog|Translation|Donate|AuthorWebSite)
      case "$v" in http://*|https://*) ;; *) warn "$n is a web address (https://…)"; return 1 ;; esac ;;
    binary|Binaries)
      case "$v" in https://*) ;; *) warn "$n has to be an https:// address"; return 1 ;; esac ;;
    srclibs)
      printf '%s\n' "$v" | grep -qv '@' && { warn "every srclib is name@ref, e.g. rustup@1.28.2"; return 1; } ;;
  esac
  return 0
}

# The memory of a line: last time's answer ("-" = it was left out), or nothing.
ymem() {  # ymem <rel> <default> — prints the default to offer
  local last; last="$(recall "$(mkey "$1")")"
  case "$last" in '') printf '%s' "$2" ;; -) ;; *) printf '%s' "$last" ;; esac
}
ysave() {  # ysave <rel> <kind> <value>
  if [ -n "$3" ]; then rset "$1" "$2" "$3"; remember "$(mkey "$1")" "$3"
  else rdel "$1"; remember "$(mkey "$1")" -; fi
}

yline() {  # yline <rel> <scope> <default> [req] — a one-line field
  local rel="$1" scope="$2" def req="${4-}" name="${1##*/}" ans
  def="$(ymem "$rel" "$3")"
  if [ "$ASSUME_YES" = 1 ]; then
    [ -z "$def" ] && [ "$req" = req ] && die "--yes: nothing to answer $name with — run once without --yes"
    [ -n "$def" ] && ok "$name: $def"
    ysave "$rel" s "$def"; return 0
  fi
  yhelp "$scope" "$name"; yhint "$scope" "$name" "$def"
  while :; do
    if [ -n "$def" ] && [ "$req" = req ]; then printf '   %s%s%s [%s]: ' "$B" "$name" "$R" "$def" >&2
    elif [ -n "$def" ]; then printf '   %s%s%s [%s, - for none]: ' "$B" "$name" "$R" "$def" >&2
    elif [ "$req" = req ]; then printf '   %s%s%s: ' "$B" "$name" "$R" >&2
    else printf '   %s%s%s [Enter for none]: ' "$B" "$name" "$R" >&2; fi
    readline ans
    ans="$(trim "$ans")"
    [ -z "$ans" ] && ans="$def"
    [ "$ans" = - ] && ans=""
    if [ -z "$ans" ]; then
      [ "$req" = req ] && { warn "$name is required"; continue; }
      break
    fi
    ycheck "$scope" "$name" "$ans" && break
  done
  ysave "$rel" s "$ans"
}

YL_ADD=0   # set by the "add a line" menu: an empty list starts by asking for items
ylist() {  # ylist <rel> <scope> <default items, one per line> [kind] — a list
  local rel="$1" scope="$2" items kind="${4:-l}" name="${1##*/}" ch line tmp
  items="$(ymem "$rel" "$3")"
  if [ "$ASSUME_YES" = 1 ]; then
    [ -n "$items" ] && ok "$name: $(printf '%s' "$items" | tr '\n' ' ' | cut -c1-70)"
    ysave "$rel" "$kind" "$items"; return 0
  fi
  yhelp "$scope" "$name"; yhint "$scope" "$name" "$items"
  [ "$kind" = a ] && note "one per line: the anti-feature, then optionally \": why\" (users see the why)"
  ch=""; [ -z "$items" ] && [ "$YL_ADD" = 1 ] && ch=a
  while :; do
    if [ -z "$ch" ]; then
      if [ -n "$items" ]; then
        printf '   %s%s:%s\n' "$B" "$name" "$R" >&2
        printf '%s\n' "$items" | sed 's/^/     - /' >&2
        printf '   %s%s%s [Enter keeps · a adds · e edits · - for none]: ' "$B" "$name" "$R" >&2
      else
        printf '   %s%s%s [Enter for none · a adds · e edits]: ' "$B" "$name" "$R" >&2
      fi
      readline ch
    fi
    case "$(trim "$ch")" in
      '')  if [ -z "$items" ] || ycheck "$scope" "$name" "$items"; then break; fi ;;
      -)   items=""; break ;;
      a|A) note "one per line; an empty line ends it"
           while :; do
             printf '     - ' >&2; readline line; line="$(trim "$line")"
             [ -n "$line" ] || break
             line="${line#- }"; items="${items:+$items$'\n'}$line"
           done ;;
      e|E) tmp="$WORK/edit-$name.txt"
           printf '%s\n' "$items" > "$tmp"
           if edit_file "$tmp"; then
             items="$(sed -e 's/^[[:space:]]*- //' -e 's/[[:space:]]*$//' -e '/^$/d' "$tmp")"
           fi ;;
      *)   warn "Enter, a, e or -" ;;
    esac
    ch=""
  done
  ysave "$rel" "$kind" "$items"
}

yblock() {  # yblock <rel> <scope> <default text> [kind] — paragraphs, or YAML kept as written
  local rel="$1" scope="$2" text kind="${4:-b}" name="${1##*/}" ch tmp n
  text="$(ymem "$rel" "$3")"
  if [ "$ASSUME_YES" = 1 ]; then ysave "$rel" "$kind" "$text"; return 0; fi
  yhelp "$scope" "$name"
  [ "$kind" = r ] && note "kept exactly as written — e opens it in your editor"
  while :; do
    if [ -n "$text" ]; then
      n="$(printf '%s\n' "$text" | wc -l)"
      printf '   %s%s:%s\n' "$B" "$name" "$R" >&2
      printf '%s\n' "$text" | head -8 | sed "s/^/     $DIM|$R /" >&2
      [ "$n" -gt 8 ] && note "  … $((n - 8)) more lines — e shows them all"
      printf '   %s%s%s [Enter keeps · e edits · - for none]: ' "$B" "$name" "$R" >&2
    else
      printf '   %s%s%s [Enter for none · e writes it · or type one line]: ' "$B" "$name" "$R" >&2
    fi
    readline ch
    case "$(trim "$ch")" in
      '') break ;;
      -)  text=""; break ;;
      e|E) tmp="$WORK/edit-$name.txt"
           printf '%s\n' "$text" > "$tmp"
           edit_file "$tmp" && text="$(sed -e 's/[[:space:]]*$//' "$tmp")" ;;
      *)  if [ -z "$text" ]; then text="$(trim "$ch")"; else warn "Enter, e or -"; fi ;;
    esac
  done
  ysave "$rel" "$kind" "$text"
}

yfield() {  # yfield <rel> <scope> <kind> <default> [req]
  case "$3" in
    l|a) ylist  "$1" "$2" "$4" "$3" ;;
    b|r) yblock "$1" "$2" "$4" "$3" ;;
    *)   yline  "$1" "$2" "$4" "${5-}" ;;
  esac
}

K=1
ycopy_build() {  # ycopy_build <name> — entry 1's answer for this line, in every entry
  local n x f="$RR/b/1/$1"
  for n in $(seq 2 "$K"); do
    mkdir -p "$RR/b/$n"; rm -f "$RR/b/$n/$1" "$RR/b/$n/$1.k" "$RR/b/$n/$1.del"
    for x in "" .k .del; do [ -f "$f$x" ] && cp "$f$x" "$RR/b/$n/$1$x"; done
  done
  return 0
}

# The fields the recipe does not have yet, any of them a number away.
yadd() {  # yadd top|build <label>
  local scope="$1" label="$2" names=() k i ch pre="top/" list
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$scope" = build ] && pre="b/1/"
  while :; do
    names=()
    list="$FTOP"; [ "$scope" = build ] && list="$FBUILD"
    for k in $list; do
      [ -f "$RR/$pre$k" ] && continue
      case "$scope:$k" in top:Builds|build:versionName|build:versionCode) continue ;; esac
      names+=("$k")
    done
    printf '\n'; say "$label — a number or a field name, Enter when done:"
    i=1
    for k in "${names[@]}"; do
      printf '   %3d) %-22s' "$i" "$k"; [ $((i % 3)) = 0 ] && printf '\n'; i=$((i + 1))
    done
    [ $(((i - 1) % 3)) = 0 ] || printf '\n'
    printf '   %sAdd%s: ' "$B" "$R" >&2; readline ch; ch="$(trim "$ch")"
    [ -n "$ch" ] || break
    case "$ch" in
      *[!0-9]*) k="$ch" ;;
      *) if [ "$ch" -ge 1 ] && [ "$ch" -lt "$i" ]; then k="${names[$((ch - 1))]}"
         else warn "there is no $ch"; continue; fi ;;
    esac
    if [ -z "${FKIND[$scope:$k]:-}" ]; then
      warn "$k is not in the Build Metadata Reference — fdroiddata's schema will refuse it"
      confirm "Add it anyway?" n || continue
      if confirm "Does it hold a list (several values)?" n; then FKIND["$scope:$k"]=l; else FKIND["$scope:$k"]=s; fi
    fi
    YL_ADD=1; yfield "$pre$k" "$scope" "${FKIND[$scope:$k]}" ""; YL_ADD=0
    [ "$scope" = build ] && ycopy_build "$k"
    case " $(recall "Y_added_$scope") " in *" $k "*) ;; *) remember "Y_added_$scope" "$(recall "Y_added_$scope") $k" ;; esac
  done
}

# --- what the project needs, as far as its files tell
REPO_FILES="$WORK/repo-files.txt"
git -C "$REPO" ls-files > "$REPO_FILES" 2>/dev/null || : > "$REPO_FILES"
SUBMODULES=""; [ -f "$REPO/.gitmodules" ] && SUBMODULES=1
NDK_GUESS="$(gval ndkVersion)"
printf '%s' "$NDK_GUESS" | grep -qE '^(r[0-9]+[a-z]?|[0-9][0-9.]*)$' || NDK_GUESS=""
NATIVE=""
if grep -qE 'externalNativeBuild|ndkBuild' "$GRADLE_FILE" 2>/dev/null; then NATIVE="externalNativeBuild in $GRADLE_REL"
elif [ -d "$REPO/$SUBDIR/src/main/cpp" ]; then NATIVE="$SUBDIR/src/main/cpp"
elif [ -d "$REPO/$SUBDIR/src/main/jni" ]; then NATIVE="$SUBDIR/src/main/jni"
fi
HAS_RUST=""; grep -qE '(^|/)(Cargo\.toml|rust-toolchain(\.toml)?)$' "$REPO_FILES" && HAS_RUST=1
# closed-source libraries kept apart in their own gradle file: the F-Droid build deletes it
PROPRIETARY_GRADLE="$(grep -iE '(^|/)[^/]*proprietary[^/]*\.gradle(\.kts)?$' "$REPO_FILES" | head -10 || true)"
MANIFESTS="$(grep -c 'AndroidManifest\.xml$' "$REPO_FILES" || true)"

# Offer the product flavours declared in the gradle file, if any.
# (plain POSIX awk — no gawk-only 3-argument match(), Debian's awk is mawk)
FLAVOURS="$(awk '
  /productFlavors[[:space:]]*\{/ { depth = 1; next }
  depth > 0 {
    line = $0
    name = line
    sub(/^[[:space:]]*/, "", name)
    sub(/^create\("/, "", name)
    if (name ~ /^[A-Za-z][A-Za-z0-9_]*("\))?[[:space:]]*\{/) {
      sub(/("\))?[[:space:]]*\{.*/, "", name)
      print name
    }
    depth += gsub(/\{/, "{", line); depth -= gsub(/\}/, "}", line)
    if (depth <= 0) exit
  }' "$GRADLE_FILE" 2>/dev/null | tr '\n' ' ' || true)"
# the build F-Droid wants is usually the FOSS flavour, when there is one
GRADLE_DEF="yes"
for f in $FLAVOURS; do
  case "$f" in foss|fdroid|libre|free|floss|oss|opensource) GRADLE_DEF="$f"; break ;; esac
done
GRADLEFLAVOUR=""
if [ -n "$FLUTTER_DIR" ] && { [ -n "${FLAVOURS// /}" ] || [ "$ASK_ALL" = 1 ]; }; then
  [ -n "${FLAVOURS// /}" ] && note "product flavours found: $FLAVOURS"
  ask_opt GRADLEFLAVOUR "Gradle flavour (blank = the default variant)" ""
fi

# --- Flutter: which Flutter F-Droid builds with, and one APK per CPU type
FLUTTERREF=""; FL_PIN=""; ABISPLIT=0; FL_RM=""
if [ -n "$FLUTTER_DIR" ]; then
  FL_GUESS=""
  # A version pinned in the Flutter project lets F-Droid's metadata read it at
  # build time (flutter@stable + checkout), so auto-updates follow your pin.
  if [ -f "$REPO/$FLUTTER_DIR/.fvmrc" ]; then
    FL_GUESS="$(sed -nE 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$REPO/$FLUTTER_DIR/.fvmrc" | sed -n 1p)"
    [ -n "$FL_GUESS" ] && FL_PIN=".fvmrc"
  elif [ -f "$REPO/$FLUTTER_DIR/.fvm/fvm_config.json" ]; then
    FL_GUESS="$(sed -nE 's/.*"flutterSdkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$REPO/$FLUTTER_DIR/.fvm/fvm_config.json" | sed -n 1p)"
  fi
  for tv in "$REPO/.tool-versions" "$REPO/$FLUTTER_DIR/.tool-versions"; do
    [ -z "$FL_GUESS" ] && [ -f "$tv" ] && \
      FL_GUESS="$(awk '$1 == "flutter" { sub(/-stable$/, "", $2); print $2; exit }' "$tv")"
  done
  if [ -z "$FL_GUESS" ] && have flutter; then
    FL_JSON="$(flutter --version --machine 2>/dev/null || true)"
    FL_GUESS="$(printf '%s' "$FL_JSON" | sed -nE 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | sed -n 1p)"
    FL_REV="$(printf '%s' "$FL_JSON" | sed -nE 's/.*"frameworkRevision"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | sed -n 1p)"
    # A pre-release version string is not a tag on flutter/flutter; the
    # commit it was built from is a ref F-Droid can check out.
    case "$FL_GUESS" in *-*) [ -n "${FL_REV:-}" ] && FL_GUESS="$FL_REV" ;; esac
  fi
  auto FLUTTERREF "Flutter version" "$FL_GUESS"
  if ! printf '%s' "$FLUTTERREF" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    warn "'$FLUTTERREF' is not a stable Flutter release"
    note "maintainers strongly prefer a stable tag; build and test the app on one"
    FL_PIN=""   # can't read a commit hash back from .fvmrc reliably
  fi
  [ -n "$FL_PIN" ] && [ "$(printf '%s' "$FL_GUESS")" != "$FLUTTERREF" ] && FL_PIN=""
  [ -n "$FL_PIN" ] && ok "F-Droid will read the Flutter version from $FLUTTER_DIR/$FL_PIN"

  # F-Droid asks for per-ABI APKs when the universal one is big (it is for
  # Flutter: every engine is inside). Flutter numbers split APKs itself as
  # 1000 * ABI + versionCode, but F-Droid's reviewers want 10 * versionCode +
  # ABI (arm32 1, arm64 2, x86_64 3), so a new release always outranks every
  # APK of the old one. The app sets that in its gradle file; without it the
  # APKs F-Droid builds don't match the codes in the metadata. An update keeps
  # whatever the app already has in F-Droid.
  ABISPLIT=1
  if [ "$IS_UPDATE" = 0 ]; then
    confirm "Build one APK per CPU type (smaller downloads; F-Droid asks for it)?" y || ABISPLIT=0
  fi
  [ "$ABISPLIT" = 1 ] && ok "one APK per CPU type: armeabi-v7a, arm64-v8a, x86_64"
  if [ "$ABISPLIT" = 1 ] && ! grep -q 'versionCodeOverride' "$GRADLE_FILE" 2>/dev/null; then
    warn "${GRADLE_FILE#"$REPO"/} does not set the per-CPU version codes F-Droid wants"
    note "add this to it (the reviewers ask for exactly this), then commit and tag again:"
    if [ "${GRADLE_FILE##*.}" = kts ]; then
      sed 's/^/       /' <<'EOF'
import com.android.build.gradle.internal.api.ApkVariantOutputImpl   // at the top

val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}
EOF
    else
      sed 's/^/       /' <<'EOF'
def abiCodes = ["armeabi-v7a": 1, "arm64-v8a": 2, "x86_64": 3]
android.applicationVariants.configureEach { variant ->
    variant.outputs.each { output ->
        def abiVersionCode = abiCodes.get(output.getFilter(com.android.build.OutputFile.ABI))
        if (abiVersionCode != null) {
            output.versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}
EOF
    fi
    [ "$ASSUME_YES" = 1 ] && die "add it and re-run"
    confirm "Continue anyway?" n || die "add it and re-run"
  fi

  # Platform folders F-Droid doesn't need are removed before the build.
  for pd in ios linux macos web windows; do
    [ -d "$REPO/$FLUTTER_DIR/$pd" ] || continue
    if [ "$FLUTTER_DIR" = "." ]; then FL_RM="$FL_RM $pd"; else FL_RM="$FL_RM $FLUTTER_DIR/$pd"; fi
  done
fi

# --- what this wizard would write by itself: the starting point when there is
# no recipe to start from, and the version lines either way
emit_entry() {  # emit_entry <versionCode> [<target platform> <abi>] — one Builds: item
  local vc="$1" tp="${2-}" abi="${3-}" apk flavor_flag="" f
  printf "  - versionName: '%s'\n" "$VNAME"
  printf '    versionCode: %s\n' "$vc"
  printf '    commit: %s\n' "$COMMIT"
  if [ -n "$FLUTTER_DIR" ]; then
    # build commands run inside subdir, so that is the Flutter project itself
    [ "$FLUTTER_DIR" != "." ] && printf '    subdir: %s\n' "$FLUTTER_DIR"
  else
    [ "$SUBDIR" != "." ] && printf '    subdir: %s\n' "$SUBDIR"
  fi
  [ -n "$SUBMODULES" ] && printf '    submodules: true\n'
  if [ -z "$FLUTTER_DIR" ]; then
    printf '    gradle:\n'
    printf "      - '%s'\n" "$GRADLE_DEF"
    if [ -n "$PROPRIETARY_GRADLE" ]; then
      printf '    rm:\n'
      printf '%s\n' "$PROPRIETARY_GRADLE" | sed "s/^/      - /"
    fi
    [ -n "$NDK_GUESS" ] && printf "    ndk: '%s'\n" "$NDK_GUESS"
    return 0
  fi
  # fdroiddata's Flutter recipe (templates/build-flutter.yml)
  apk="app"; [ -n "$abi" ] && apk="$apk-$abi"
  [ -n "$GRADLEFLAVOUR" ] && { apk="$apk-$GRADLEFLAVOUR"; flavor_flag=" --flavor $GRADLEFLAVOUR"; }
  printf '    output: build/app/outputs/flutter-apk/%s-release.apk\n' "$apk"
  printf '    srclibs:\n'
  if [ -n "$FL_PIN" ]; then printf '      - flutter@stable\n'; else printf '      - flutter@%s\n' "$FLUTTERREF"; fi
  if [ -n "$FL_RM" ]; then
    printf '    rm:\n'
    for f in $FL_RM; do printf '      - %s\n' "$f"; done
  fi
  printf '    prebuild:\n'
  if [ -n "$FL_PIN" ]; then
    printf '      - flutterVersion=$(sed -n -E '"'"'s/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\\1/p'"'"' %s)\n' "$FL_PIN"
    printf "      - '[[ \$flutterVersion ]]'\n"
    printf '      - git -C $$flutter$$ checkout -f $flutterVersion\n'
  fi
  printf '      - export PUB_CACHE=$(pwd)/.pub-cache\n'
  printf '      - $$flutter$$/bin/flutter config --no-analytics\n'
  printf '      - $$flutter$$/bin/flutter pub get --enforce-lockfile\n'
  printf '    scandelete:\n'
  if [ "$FLUTTER_DIR" = "." ]; then printf '      - .pub-cache\n'; else printf '      - %s/.pub-cache\n' "$FLUTTER_DIR"; fi
  printf '    build:\n'
  printf '      - export PUB_CACHE=$(pwd)/.pub-cache\n'
  if [ -n "$tp" ]; then
    printf '      - $$flutter$$/bin/flutter build apk --release --split-per-abi --target-platform=%s%s\n' "$tp" "$flavor_flag"
  else
    printf '      - $$flutter$$/bin/flutter build apk --release%s\n' "$flavor_flag"
  fi
}
{
  printf 'Builds:\n'
  if [ "$ABISPLIT" = 1 ]; then
    emit_entry "$((10 * VCODE + 1))" android-arm armeabi-v7a; printf '\n'
    emit_entry "$((10 * VCODE + 2))" android-arm64 arm64-v8a; printf '\n'
    emit_entry "$((10 * VCODE + 3))" android-x64 x86_64
    printf "\nVercodeOperation:\n  - '10 * %%c + 1'\n  - '10 * %%c + 2'\n  - '10 * %%c + 3'\n"
  else
    emit_entry "$VCODE"
  fi
  # The checker reads versions from gradle, where Flutter only has
  # references; point it at pubspec.yaml's `version: name+code` instead.
  if [ -n "$FLUTTER_DIR" ]; then
    UCD_FILE="pubspec.yaml"; [ "$FLUTTER_DIR" != "." ] && UCD_FILE="$FLUTTER_DIR/pubspec.yaml"
    printf 'UpdateCheckData: %s|version:\\s.+\\+(\\d+)|.|version:\\s(.+)\\+\n' "$UCD_FILE"
  fi
} > "$WORK/gen.yml"
rcp load "$WORK/gen.yml" "$RG"

# --- the recipe to start from
BASE_FILE=""; BASE_KIND=none; BASE_LABEL="what this wizard detected"
if [ "$IS_UPDATE" = 1 ]; then
  git -C "$FDROIDDATA" show "$EXISTING" > "$WORK/base.yml"
  BASE_FILE="$WORK/base.yml"; BASE_KIND=upstream; BASE_LABEL="F-Droid's metadata/$APPID.yml"
else
  CANDS=()
  # your merge request, if its branch is on your fork already
  if git -C "$FDROIDDATA" fetch -q origin "refs/heads/$BRANCH" 2>/dev/null \
     && git -C "$FDROIDDATA" show "FETCH_HEAD:metadata/$APPID.yml" > "$WORK/base-fork.yml" 2>/dev/null; then
    CANDS+=("fork|$WORK/base-fork.yml|your merge request's recipe (branch $BRANCH on your fork)")
  fi
  # a copy kept in the app's own repo, e.g. fdroid/<appid>.yml
  for f in "fdroid/$APPID.yml" "metadata/$APPID.yml" ".fdroid.yml"; do
    [ -f "$REPO/$f" ] || continue
    if [ -f "$WORK/base-fork.yml" ] && cmp -s "$REPO/$f" "$WORK/base-fork.yml"; then
      note "$f in your app repo is the same as your merge request's recipe"
      continue
    fi
    CANDS+=("app|$REPO/$f|$f in your app repo")
  done
  say "Start the recipe from:"
  i=1
  for c in "${CANDS[@]}"; do printf '     %d) %s\n' "$i" "${c##*|}"; i=$((i + 1)); done
  REF_N=$i;  printf '     %d) %s\n' "$i" "another app's recipe in fdroiddata — one built the way yours is"; i=$((i + 1))
  NEW_N=$i;  printf '     %d) %s\n' "$i" "a fresh one, from what this wizard detected"
  BASE_DEF=$NEW_N; [ "${#CANDS[@]}" -gt 0 ] && BASE_DEF=1
  while :; do
    ask BASE_PICK "Which" "$BASE_DEF"
    case "$BASE_PICK" in *[!0-9]*|'') warn "a number from the list"; continue ;; esac
    if [ "$BASE_PICK" -ge 1 ] && [ "$BASE_PICK" -le "${#CANDS[@]}" ]; then
      c="${CANDS[$((BASE_PICK - 1))]}"
      BASE_KIND="${c%%|*}"; c="${c#*|}"; BASE_FILE="${c%%|*}"; BASE_LABEL="${c#*|}"
      break
    elif [ "$BASE_PICK" = "$REF_N" ]; then
      note "its newest build entry becomes the template for yours; the rest of the recipe stays yours"
      ask REF_APP "Its application id (e.g. org.mozilla.fennec_fdroid)" "$(recall REF_APP)"
      if git -C "$FDROIDDATA" show "$BASE:metadata/$REF_APP.yml" > "$WORK/base-ref.yml" 2>/dev/null; then
        BASE_FILE="$WORK/base-ref.yml"; BASE_KIND=reference; BASE_LABEL="$REF_APP's recipe"
        break
      fi
      warn "fdroiddata has no metadata/$REF_APP.yml"
    elif [ "$BASE_PICK" = "$NEW_N" ]; then
      break
    else
      warn "a number from the list"
    fi
  done
fi
[ -n "$BASE_FILE" ] && rcp load "$BASE_FILE" "$RD"
[ "$BASE_KIND" = none ] || ok "starting from $BASE_LABEL"
# Last time's answers are the defaults — unless this run starts from another
# recipe: then that recipe's lines are what you came for.
case "$BASE_KIND" in
  reference) BASE_ID="reference:$REF_APP" ;;
  app)       BASE_ID="app:${BASE_FILE#"$REPO"/}" ;;
  *)         BASE_ID="$BASE_KIND" ;;
esac
if [ -n "$(recall Y_BASE)" ] && [ "$(recall Y_BASE)" != "$BASE_ID" ]; then
  note "a different starting recipe from last time: its lines are the defaults now, not last time's answers"
  for k in "${!MEM[@]}"; do case "$k" in Y_*) unset "MEM[$k]" ;; esac; done
fi
remember Y_BASE "$BASE_ID"
if [ "$BASE_KIND" = reference ]; then
  # another app's license, links and author are no default for yours
  for f in "$RD"/top/*; do
    case "${f##*/}" in AntiFeatures|AntiFeatures.k|UpdateCheckMode|UpdateCheckMode.k|AutoUpdateMode|AutoUpdateMode.k) ;;
      *) rm -f "$f" ;; esac
  done
  : > "$RD/top.order"
  note "from it: the build steps, the anti-features and the update checks — each one asked"
fi

# The new build entries: this run's versions, on top of the base's build steps.
rcp template "$RG" "$RD" "$BASE_KIND" "$RT" "$VCODE"
K="$(cat "$RT/b.count")"
if [ "$IS_UPDATE" = 1 ]; then
  for n in $(seq 1 "$K"); do
    vc="$(fv "$RT/b/$n/versionCode")"
    for e in $(cat "$RD"/b/*/versionCode 2>/dev/null); do
      [ "$e" = "$vc" ] && die "versionCode $vc is already in metadata/$APPID.yml — nothing to do"
    done
  done
fi
# The base's own build entries: F-Droid's stay, an unmerged recipe's are asked about.
BUILDS_MODE=replace
[ "$BASE_KIND" = upstream ] && BUILDS_MODE=keep
if [ "$BASE_KIND" = fork ] || [ "$BASE_KIND" = app ]; then
  OLDV="$(cat "$RD"/b/*/versionName 2>/dev/null | grep -vxF "$VNAME" | sort -u | tr '\n' ' ' || true)"
  if [ -n "$OLDV" ]; then
    note "it has build entries for ${OLDV% } — a new app's merge request usually has only the newest"
    confirm "Keep them next to the new one?" n && BUILDS_MODE=keep
  fi
fi

# where a field comes from: the base recipe, else what was detected
dflt() {  # dflt <Key> <fallback>
  local v=""
  [ -f "$RD/top/$1" ] && v="$(fv "$RD/top/$1")"
  printf '%s' "${v:-$2}"
}
TOP_DONE=" "
tdone() { TOP_DONE="$TOP_DONE$* "; }

# --- the app itself: license, categories, links, author, anti-features
ask_about_app() {
  local c i found lic_guess="" lic_from="" mail_def a n why whydef new cur defnums
  printf '\n'; say "${B}About the app${R}"
  # license: what the recipe says, else last time's answer, else the repo's file
  if [ -f "$RD/top/License" ]; then lic_guess="$(fv "$RD/top/License")"; lic_from="$BASE_LABEL"
  elif [ "${SAVED_LICENSE_APP:-}" = "$APPID" ] && [ -n "${SAVED_LICENSE:-}" ]; then
    lic_guess="$SAVED_LICENSE"; lic_from="your answer last time"
  fi
  if [ -z "$lic_guess" ]; then
    for f in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING COPYING.md; do
      [ -f "$REPO/$f" ] || continue
      # Only the head: the GPL-3.0 text itself mentions the Affero license
      # (section 13), so matching the whole file calls every GPL app AGPL.
      head -n 30 "$REPO/$f" > "$WORK/license.head"
      LH="$WORK/license.head"
      GNU=""
      if   grep -qi "GNU AFFERO GENERAL PUBLIC LICENSE" "$LH"; then GNU="AGPL-3.0"
      elif grep -qi "GNU LESSER GENERAL PUBLIC LICENSE" "$LH"; then
        if grep -q "Version 2.1" "$LH"; then GNU="LGPL-2.1"; else GNU="LGPL-3.0"; fi
      elif grep -qi "GNU GENERAL PUBLIC LICENSE" "$LH"; then
        if grep -q "Version 3" "$LH"; then GNU="GPL-3.0"; else GNU="GPL-2.0"; fi
      elif grep -qi "Apache License" "$LH";        then lic_guess="Apache-2.0"
      elif grep -qi "MIT License" "$LH";           then lic_guess="MIT"
      elif grep -qi "Mozilla Public License" "$LH"; then lic_guess="MPL-2.0"
      elif grep -qi "Redistribution and use in source" "$LH"; then lic_guess="BSD-3-Clause"
      elif grep -qi "This is free and unencumbered" "$LH"; then lic_guess="Unlicense"
      fi
      if [ -n "$GNU" ]; then
        # The license text is the same for "-only" and "-or-later"; the
        # difference is in the notices in the source files.
        if git -C "$REPO" grep -qi "any later version" -- ':!LICENSE*' ':!LICENCE*' ':!COPYING*' 2>/dev/null; then
          lic_guess="$GNU-or-later"; lic_from="$f; source files say \"any later version\""
        else
          lic_guess="$GNU-only"; lic_from="$f; no \"any later version\" notice in the source"
        fi
      elif [ -n "$lic_guess" ]; then
        lic_from="$f"
      fi
      [ -n "$lic_guess" ] && break
    done
  fi
  if [ -n "$lic_guess" ]; then
    note "License from $lic_from — Enter keeps it, or type another SPDX id"
    case "$lic_guess" in *GPL*) note "(GPL-3.0-only and GPL-3.0-or-later are different licenses: pick the one you mean)" ;; esac
  else
    note "no license found — an SPDX identifier, e.g. GPL-3.0-only, Apache-2.0, MIT, AGPL-3.0-only"
  fi
  ask LICENSE "License" "$(ymem top/License "$lic_guess")"
  ysave top/License s "$LICENSE"; tdone License

  # categories: fdroiddata keeps the real list in config/categories.yml, and it
  # is nothing like the old handful: ~120 precise ones (Bookmark, Ebook Reader,
  # Password Manager…). lint rejects anything not in it, and reviewers ask for
  # the precise one, so the list comes out of the clone rather than a guess.
  CATS_FILE="$FDROIDDATA/config/categories.yml"
  CATS=()
  if [ -f "$CATS_FILE" ]; then
    while IFS= read -r line; do CATS+=("$line"); done < <(
      sed -n "s/^\([A-Za-z][A-Za-z0-9 &_.,'-]*\):[[:space:]]*$/\1/p" "$CATS_FILE")
  fi
  if [ "${#CATS[@]}" -lt 5 ]; then
    warn "could not read $CATS_FILE — falling back to the old short list"
    CATS=(Connectivity Development Games Graphics Internet Money Multimedia
          Navigation "Phone & SMS" Reading "Science & Education" Security
          "Sports & Health" System Theming Time Writing)
  fi
  CATS_MAX="${#CATS[@]}"
  # remembered per app — another app's categories are no guess for this one
  CATSEL="$(recall CATSEL)"
  [ -z "$CATSEL" ] && [ "${SAVED_CATSEL_APP:-}" = "$APPID" ] && CATSEL="${SAVED_CATSEL:-}"
  if [ -z "$CATSEL" ] && [ -s "$RD/top/Categories" ]; then
    for c in $(tr ' ' '\037' < "$RD/top/Categories"); do
      c="${c//$'\037'/ }"; found=""
      for i in "${!CATS[@]}"; do [ "${CATS[$i]}" = "$c" ] && found=$((i + 1)); done
      if [ -n "$found" ]; then CATSEL="${CATSEL:+$CATSEL }$found"
      else warn "category '$c' from $BASE_LABEL is not in fdroiddata's list"; fi
    done
  fi
  print_cats() {  # print_cats [filter] — numbered, in columns, narrowed if asked
    local i=1 shown=0 c
    for c in "${CATS[@]}"; do
      if [ -z "${1-}" ] || printf '%s' "$c" | grep -qi -- "$1"; then
        printf '   %3d) %-26s' "$i" "$c"; shown=$((shown + 1))
        [ $((shown % 3)) = 0 ] && printf '\n'
      fi
      i=$((i + 1))
    done
    [ $((shown % 3)) = 0 ] || printf '\n'
    [ "$shown" = 0 ] && warn "nothing matches \"$1\""
    return 0
  }
  cat_names() { local n out=""; for n in $1; do out="${out:+$out, }${CATS[$((n - 1))]:-?}"; done; printf '%s' "$out"; }
  yhelp top Categories
  if [ -n "$CATSEL" ]; then
    say "Categories: $(cat_names "$CATSEL")"
    confirm "Keep them?" y || CATSEL=""
  fi
  if [ -z "$CATSEL" ]; then
    [ "$ASSUME_YES" = 1 ] && die "--yes: pick the categories once in a normal run first"
    say "$CATS_MAX categories. Type a word to narrow the list, or Enter to see them all."
    ask_opt CATFILTER "Narrow by" ""
    print_cats "$CATFILTER"
    say "Pick one or more by number, space separated. Reviewers ask for the"
    say "precise one — pick the category that names what the app is."
  fi
  while :; do
    [ -z "$CATSEL" ] && ask CATSEL "Numbers" ""
    CATEGORIES=""; BADSEL=""
    for n in $CATSEL; do
      case "$n" in ''|*[!0-9]*) BADSEL="$n"; break ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le "$CATS_MAX" ] || { BADSEL="$n"; break; }
      CATEGORIES="$CATEGORIES${CATEGORIES:+|}${CATS[$((n - 1))]}"
    done
    [ -z "$BADSEL" ] && [ -n "$CATEGORIES" ] && break
    warn "'${BADSEL:-}' is not one of 1-$CATS_MAX"; CATSEL=""
  done
  remember CATSEL "$CATSEL"
  ok "categories: ${CATEGORIES//|/, }"
  rset top/Categories l "$(printf '%s' "$CATEGORIES" | tr '|' '\n')"; tdone Categories

  # links and author: shown on the app's f-droid.org page
  yline top/SourceCode    top "$(dflt SourceCode "$WEB_GUESS")" req
  yline top/IssueTracker  top "$(dflt IssueTracker "${WEB_GUESS:+$WEB_GUESS/issues}")"
  yline top/Changelog     top "$(dflt Changelog "${WEB_GUESS:+$WEB_GUESS/releases}")"
  yline top/WebSite       top "$(dflt WebSite "${SAVED_WEBSITE:-}")"
  yline top/Translation   top "$(dflt Translation "")"
  yline top/Donate        top "$(dflt Donate "")"
  yline top/Liberapay     top "$(dflt Liberapay "")"
  yline top/OpenCollective top "$(dflt OpenCollective "")"
  yline top/AuthorName    top "$(dflt AuthorName "${SAVED_AUTHORNAME:-$(git -C "$REPO" config user.name 2>/dev/null || true)}")" req
  mail_def="$(dflt AuthorEmail "${SAVED_AUTHOREMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || true)}")"
  [ -n "$mail_def" ] && note "the email will be public in fdroiddata — Enter keeps it, - leaves it out"
  yline top/AuthorEmail   top "$mail_def"
  yline top/AuthorWebSite top "$(dflt AuthorWebSite "${SAVED_AUTHORSITE:-}")"
  yline top/AutoName      top "$(dflt AutoName "$AUTONAME")"
  tdone SourceCode IssueTracker Changelog WebSite Translation Donate Liberapay OpenCollective \
        AuthorName AuthorEmail AuthorWebSite AutoName
  SOURCE="$(fv "$RR/top/SourceCode")"; ISSUES="$(fv "$RR/top/IssueTracker")"
  CHANGELOG="$(fv "$RR/top/Changelog")"; WEBSITE="$(fv "$RR/top/WebSite")"
  AUTHORNAME="$(fv "$RR/top/AuthorName")"; AUTHOREMAIL="$(fv "$RR/top/AuthorEmail")"
  AUTHORSITE="$(fv "$RR/top/AuthorWebSite")"

  # anti-features, with a sentence each saying why (users see it)
  if [ "$(fk "$RD/top/AntiFeatures")" = r ]; then
    yblock top/AntiFeatures top "$(fv "$RD/top/AntiFeatures")" r
  else
    yhelp top AntiFeatures
    [ -n "${PROPRIETARY:-}${PROPRIETARY_PUB// /}" ] && \
      note "the pitfall check found non-free dependencies: NonFreeDep, unless the F-Droid build removes them"
    cur="$(ymem top/AntiFeatures "$(fv "$RD/top/AntiFeatures")")"
    if [ -n "$cur" ]; then say "AntiFeatures:"; printf '%s\n' "$cur" | sed 's/^/     - /'
    else say "AntiFeatures: none"; fi
    if [ "$ASSUME_YES" = 0 ] && confirm "Change them?" n; then
      AF_ALL="Ads ApplicationDebuggable KnownVuln NonFreeAdd NonFreeAssets NonFreeDep NonFreeNet NoSourceSince TetheredNet Tracking"
      i=1; defnums=""
      for a in $AF_ALL; do
        printf '     %2d) %s\n' "$i" "$a"
        printf '%s\n' "$cur" | grep -qE "^$a(:|$)" && defnums="${defnums:+$defnums }$i"
        i=$((i + 1))
      done
      ask_opt AFSEL "Numbers (space separated, - for none)" "$defnums"
      new=""
      for n in $AFSEL; do
        case "$n" in ''|*[!0-9]*) continue ;; esac
        a="$(echo "$AF_ALL" | awk -v k="$n" '{print $k}')"
        [ -n "$a" ] || continue
        whydef="$(printf '%s\n' "$cur" | sed -n "s/^$a:[[:space:]]*//p" | sed -n 1p)"
        ask_opt AFWHY "$a — why, in one sentence users see (- for none)" "$whydef"
        new="${new:+$new$'\n'}$a${AFWHY:+: $AFWHY}"
      done
      cur="$new"
    fi
    ysave top/AntiFeatures a "$cur"
  fi
  tdone AntiFeatures

  a=n; [ "$(dflt RequiresRoot false)" = true ] && a=y
  if [ "$ASSUME_YES" = 0 ]; then
    confirm "Does the app need root access on the phone? (RequiresRoot)" "$a" && a=y || a=n
  fi
  if [ "$a" = y ]; then rset top/RequiresRoot s true; else rdel top/RequiresRoot; fi
  tdone RequiresRoot
  yline top/RepoType top "$(dflt RepoType git)" req
  yline top/Repo     top "$(dflt Repo "${WEB_GUESS:+$WEB_GUESS.git}")" req
  REPOURL="$(fv "$RR/top/Repo")"
  case "$REPOURL" in *.git) ;; *) [ "$(fv "$RR/top/RepoType")" = git ] && warn "Repo usually ends in .git — fdroid lint will say so" ;; esac
  tdone RepoType Repo
}

# --- who signs what users install
ask_publishing() {
  local def=1 n abi b
  { [ -f "$RD/top/Binaries" ] || [ -f "$RD/top/AllowedAPKSigningKeys" ] \
    || ls "$RT"/b/*/binary >/dev/null 2>&1; } && def=2
  printf '\n'; say "${B}Publishing${R}"
  say "  1) ${B}F-Droid builds and signs${R}  — F-Droid compiles from source and signs with"
  say "     its own key. Simplest. Users get F-Droid's signature, so an app already"
  say "     installed from your GitHub APK cannot update to it."
  say "  2) ${B}Reproducible build${R}         — F-Droid rebuilds from source, checks the result"
  say "     matches your signed APK, and ships YOUR APK. Keeps your signature."
  say "     Needs Binaries: and AllowedAPKSigningKeys."
  ask MODE "Which?" "$(r="$(recall MODE)"; printf '%s' "${r:-$def}")"
  tdone Binaries AllowedAPKSigningKeys
  if [ "$MODE" != 2 ]; then
    rdel top/Binaries; rdel top/AllowedAPKSigningKeys
    for n in $(seq 1 "$K"); do rm -f "$RT/b/$n/binary" "$RT/b/$n/binary.k"; done
    return 0
  fi
  # Name the file after the project, not the local checkout's folder.
  if [ "$K" -gt 1 ]; then
    note "use %v for the version and %abi for the CPU type, e.g."
    note "  .../releases/download/v%v/App-%v-%abi.apk"
    note "each CPU type gets its own build entry, so each gets its own binary: line"
    ask BINARIES "Release APK URL pattern" \
      "$(dflt Binaries "${WEB_GUESS:+$WEB_GUESS/releases/download/v%v/${WEB_GUESS##*/}-%v-%abi.apk}")"
  else
    note "use %v where the version goes, e.g. .../releases/download/v%v/App-%v.apk"
    ask BINARIES "Binaries URL pattern" \
      "$(dflt Binaries "${WEB_GUESS:+$WEB_GUESS/releases/download/v%v/${WEB_GUESS##*/}-%v.apk}")"
  fi
  SIGNKEY="$(sed -n 1p "$RD/top/AllowedAPKSigningKeys" 2>/dev/null || true)"
  say "The signing certificate SHA-256 of your release APK is needed."
  if confirm "Extract it from a local APK now?" "$([ -n "$SIGNKEY" ] && echo n || echo y)"; then
    ask APKPATH "Path to your signed release APK" ""
    APKPATH="${APKPATH/#\~/$HOME}"
    if [ ! -f "$APKPATH" ]; then
      warn "no such file: $APKPATH"
    else
      AS=""
      if have apksigner; then AS="apksigner"
      elif [ -n "${ANDROID_HOME:-}" ]; then
        cand="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | tail -1)"
        [ -n "$cand" ] && [ -f "$cand/lib/apksigner.jar" ] && AS="java -jar $cand/lib/apksigner.jar"
      fi
      if [ -n "$AS" ]; then
        SIGNKEY="$($AS verify --print-certs "$APKPATH" 2>/dev/null \
                   | awk '/SHA-256 digest/ {print $NF; exit}')"
      fi
      # keytool ships with any JDK and reads the APK's signature block too
      if [ -z "$SIGNKEY" ] && have keytool; then
        SIGNKEY="$(keytool -printcert -jarfile "$APKPATH" 2>/dev/null \
                   | awk '/SHA256:/ {print $2; exit}' | tr -d ':' | tr 'A-Z' 'a-z')"
      fi
      [ -n "$SIGNKEY" ] && ok "signing key: $SIGNKEY" || warn "could not read it automatically"
      reference_apk_blocks "$APKPATH" | while IFS= read -r blk; do
        [ -n "$blk" ] || continue
        warn "the APK carries an extra signing block: $blk"
        note "F-Droid's scanner refuses it — the \"check apk\" job fails once"
        note "everything else has passed. Switch it off in the gradle file:"
        note "  android { dependenciesInfo { includeInApk = false; includeInBundle = false } }"
        note "that changes the APK, so it needs a new version and new binaries"
      done
      reference_apk_reproducible "$APKPATH" "$APPID" || \
        confirm "Submit with reproducible builds anyway?" n || \
        die "build the APK you publish at F-Droid's path first, then re-run"
    fi
  fi
  ask SIGNKEY "AllowedAPKSigningKeys (SHA-256, lowercase hex)" "$SIGNKEY"
  rset top/AllowedAPKSigningKeys l "$SIGNKEY"
  # Binaries: is one app-level pattern and only knows %v and %c, so it cannot
  # name per-ABI release assets. fdroidserver takes `build.binary or
  # app.Binaries`, so with a split each entry carries its own binary: line.
  if [ "$K" -gt 1 ]; then
    rdel top/Binaries
    for n in $(seq 1 "$K"); do
      abi="$(cat "$RT/b/$n/output" "$RT/b/$n/build" 2>/dev/null \
             | grep -oE 'armeabi-v7a|arm64-v8a|x86_64|x86' | sed -n 1p || true)"
      b="$BINARIES"; [ -n "$abi" ] && b="${b//%abi/$abi}"
      printf '%s\n' "$b" > "$RT/b/$n/binary"; echo s > "$RT/b/$n/binary.k"
    done
    ok "each build entry points at its own APK on the release page"
  else
    rset top/Binaries s "$BINARIES"
    for n in $(seq 1 "$K"); do rm -f "$RT/b/$n/binary" "$RT/b/$n/binary.k"; done
  fi
}

# --- the build entries, line by line
entry_label() {  # entry_label <n> — the CPU type an entry builds, else its versionCode
  local abi
  abi="$(cat "$RT/b/$1/output" "$RT/b/$1/build" "$RT/b/$1/gradleprops" "$RT/b/$1/prebuild" 2>/dev/null \
         | grep -oE 'armeabi-v7a|arm64-v8a|x86_64|x86' | sed -n 1p || true)"
  printf '%s' "${abi:-versionCode $(fv "$RT/b/$1/versionCode")}"
}
ask_build_entries() {
  local key keys n same t kind req vc dup e m
  printf '\n'
  if [ "$K" -gt 1 ]; then
    say "${B}Build entries${R} — $K of them, one per CPU type; a line that is the same in all is asked once"
  else
    say "${B}Build entry${R}"
  fi
  # the template's lines, in fdroidserver's order, then anything else it has,
  # then what was added by hand last time
  keys=""
  for key in $FBUILD; do ls "$RT"/b/*/"$key" >/dev/null 2>&1 && keys="$keys $key"; done
  for t in "$RT"/b/*/*; do
    [ -e "$t" ] || continue
    key="${t##*/}"
    case "$key" in *.k|*.del) continue ;; esac
    case " $keys " in *" $key "*) ;; *) keys="$keys $key" ;; esac
  done
  for key in $(recall Y_added_build); do case " $keys " in *" $key "*) ;; *) keys="$keys $key" ;; esac; done
  for key in $keys; do
    req=""; case "$key" in versionName|versionCode|commit) req=req ;; esac
    same=1
    for n in $(seq 2 "$K"); do
      { cmp -s "$RT/b/1/$key" "$RT/b/$n/$key" 2>/dev/null \
        || { [ ! -f "$RT/b/1/$key" ] && [ ! -f "$RT/b/$n/$key" ]; }; } || same=0
    done
    if [ "$same" = 1 ]; then
      kind="$(akind build "$key" "$RT/b/1/$key")"
      yfield "b/1/$key" build "$kind" "$(fv "$RT/b/1/$key")" "$req"
      ycopy_build "$key"
    else
      for n in $(seq 1 "$K"); do
        note "entry $n of $K — $(entry_label "$n"):"
        kind="$(akind build "$key" "$RT/b/$n/$key")"
        yfield "b/$n/$key" build "$kind" "$(fv "$RT/b/$n/$key")" "$req"
      done
    fi
  done
  # every new versionCode has to be new
  for n in $(seq 1 "$K"); do
    while :; do
      vc="$(fv "$RR/b/$n/versionCode")"; dup=""
      if [ "$BUILDS_MODE" = keep ]; then
        for e in $(cat "$RD"/b/*/versionCode 2>/dev/null); do [ "$e" = "$vc" ] && dup=1; done
      fi
      for m in $(seq 1 $((n - 1))); do [ "$(fv "$RR/b/$m/versionCode")" = "$vc" ] && dup=1; done
      [ -z "$dup" ] && break
      [ "$ASSUME_YES" = 1 ] && die "versionCode $vc is already in metadata/$APPID.yml"
      warn "versionCode $vc is already taken — every build entry needs its own"
      remember "$(mkey "b/$n/versionCode")" ""
      yline "b/$n/versionCode" build "" req
    done
  done
  # A $$name$$ is filled in from a srclib of that name (fdroidserver knows only
  # SDK, NDK, COMMIT, VERSION and VERCODE itself): one with no srclibs: line
  # behind it — typically a srclib just dropped — fails the build.
  local u lib seen=" "
  for n in $(seq 1 "$K"); do
    for u in $(cat "$RR/b/$n"/* 2>/dev/null | grep -o '\$\$[A-Za-z0-9_.-]*\$\$' | sort -u); do
      lib="${u//\$/}"
      case "$lib" in SDK|NDK|MVN3|COMMIT|VERSION|VERCODE) continue ;; esac
      sed 's/^[0-9]*://' "$RR/b/$n/srclibs" 2>/dev/null | grep -q "^$lib@" && continue
      case "$seen" in *" $lib "*) continue ;; esac
      seen="$seen$lib "
      warn "the build uses $u, but no srclibs: line brings in $lib — the build would fail"
      note "add the srclib below, or change the lines that use it (e at the preview opens the file)"
    done
  done
  # what is missing, before the add menu offers it
  if [ -n "$NATIVE" ] && [ ! -f "$RR/b/1/ndk" ]; then
    warn "native code ($NATIVE), but no ndk: line — F-Droid needs one; add it below"
  fi
  if [ -n "$HAS_RUST" ] && ! grep -qs rustup "$RR"/b/*/sudo "$RR"/b/*/srclibs "$RR"/b/*/build "$RR"/b/*/prebuild; then
    note "Rust code in the repo, and nothing installs rustup — reviewers ask for apt-get install -y rustup in sudo:"
  fi
  yadd build "Add a line to the build entr$([ "$K" -gt 1 ] && echo ies || echo y)"
}

# --- how F-Droid learns about new versions, and which one is current
ask_update_checks() {
  local ucm aum k src
  printf '\n'; say "${B}Updates${R}"
  ucm="$(dflt UpdateCheckMode "")"
  if [ -z "$ucm" ]; then ucm=Tags; [ "${MANIFESTS:-0}" -gt 20 ] && ucm=None; fi
  yline top/UpdateCheckMode top "$ucm" req
  aum="$(dflt AutoUpdateMode "")"
  if [ -z "$aum" ]; then
    aum=Version; [ "$(fv "$RR/top/UpdateCheckMode")" = None ] && aum=None
    case "$TAG" in
      "$VNAME"|"v$VNAME") ;;
      *) warn "tag '$TAG' is neither '$VNAME' nor 'v$VNAME'"
         note "UpdateCheckMode: Tags takes the newest tag whatever it is called, so"
         note "'Version' still works; answer None to update the metadata by hand" ;;
    esac
  fi
  yline top/AutoUpdateMode top "$aum" req
  for k in UpdateCheckIgnore VercodeOperation UpdateCheckName UpdateCheckData; do
    src=""
    if [ -f "$RD/top/$k" ]; then src="$RD/top/$k"; elif [ -f "$RG/top/$k" ]; then src="$RG/top/$k"; fi
    [ -n "$src" ] && yfield "top/$k" top "$(akind top "$k" "$src")" "$(fv "$src")"
  done
  tdone UpdateCheckMode AutoUpdateMode UpdateCheckIgnore VercodeOperation UpdateCheckName UpdateCheckData
}
ask_current_version() {
  local cur="" n vc
  for n in $(seq 1 "$K"); do
    vc="$(fv "$RR/b/$n/versionCode")"
    [ -z "$cur" ] || [ "$vc" -gt "$cur" ] && cur="$vc"
  done
  yline top/CurrentVersion     top "$VNAME" req
  yline top/CurrentVersionCode top "$cur" req
  tdone CurrentVersion CurrentVersionCode
}

# --- whatever else the base recipe holds, and what was added by hand last time
ask_rest() {
  local k
  for k in $(cat "$RD/top.order" 2>/dev/null) $(recall Y_added_top); do
    case "$TOP_DONE" in *" $k "*) continue ;; esac
    if [ -f "$RD/top/$k" ]; then
      yfield "top/$k" top "$(akind top "$k" "$RD/top/$k")" "$(fv "$RD/top/$k")"
    else
      yfield "top/$k" top "${FKIND[top:$k]:-s}" ""
    fi
    tdone "$k"
  done
}

ASK_TOP=1
[ "$IS_UPDATE" = 1 ] && ASK_TOP=0
if [ "$ASK_TOP" = 1 ]; then
  ask_about_app
  ask_publishing
fi
ask_build_entries
if [ "$ASK_TOP" = 1 ]; then
  ask_update_checks
  ask_current_version
else
  printf '\n'; say "${B}Current version${R}"
  ask_current_version
  # An older recipe may predate AutoName; CI's checkupdates would add it and
  # then fail the job on the diff, so it goes in now.
  if [ -n "$AUTONAME" ] && [ ! -f "$RD/top/AutoName" ]; then
    note "the recipe has no AutoName — CI's checkupdates would add it and then fail on the diff"
    yline top/AutoName top "$AUTONAME"
  fi
  tdone AutoName
  if [ "$ASSUME_YES" = 0 ] && confirm "Go through the rest of metadata/$APPID.yml too (license, links, update checks…)?" n; then
    ASK_TOP=1
  fi
fi
if [ "$ASK_TOP" = 1 ]; then
  ask_rest
  yadd top "Add a field to the recipe"
fi

YML="$WORK/$APPID.yml"
RENDER_BASE=-
case "$BASE_KIND" in upstream|fork|app) RENDER_BASE="$BASE_FILE" ;; esac
rcp render "$RENDER_BASE" "$RR" "$YML" "$BUILDS_MODE"
# laid out as fdroiddata's CI lays it out; a local rewritemeta does it again below
rcp ciwrap "$YML" all >/dev/null || true

# what the later steps — the merge request text, the RFP — need from all this
VCODES="$(for n in $(seq 1 "$K"); do fv "$RR/b/$n/versionCode"; done | tr '\n' ' ')"; VCODES="${VCODES% }"
CUR_VCODE="$(fv "$RR/top/CurrentVersionCode")"
ABISPLIT=0; [ "$K" -gt 1 ] && ABISPLIT=1
AUM="$(fv "$RR/top/AutoUpdateMode")"; [ -n "$AUM" ] || AUM="$(dflt AutoUpdateMode None)"
ok "metadata/$APPID.yml: $K build entr$([ "$K" -gt 1 ] && echo ies || echo y) ($VCODES)"

step "metadata/$APPID.yml"
while :; do
  if [ "$IS_UPDATE" = 1 ]; then
    # the file is long by now — only the added lines are interesting
    git -C "$FDROIDDATA" --no-pager diff --no-index --no-color -- \
      <(git -C "$FDROIDDATA" show "$EXISTING") "$YML" 2>/dev/null \
      | tail -n +5 | sed "s/^/   /" || true
  else
    printf '%s' "$DIM"; sed 's/^/   | /' "$YML"; printf '%s' "$R"
  fi
  [ "$ASSUME_YES" = 1 ] && break
  printf '   %sy) use it   e) edit it   n) stop%s [y]: ' "$B" "$R" >&2
  readline PREVIEW_CH
  case "${PREVIEW_CH:-y}" in
    y|Y*) break ;;
    e|E*) edit_file "$YML" || true; echo ;;   # then round again, showing the result
    n|N*) KEEP_WORK=1; say "the file is at: $YML"; die "stopped" ;;
    *)    warn "y, e or n" ;;
  esac
done

mkdir -p "$FDROIDDATA/metadata"
cp "$YML" "$FDROIDDATA/metadata/$APPID.yml"
YMLSUM="$(cksum < "$FDROIDDATA/metadata/$APPID.yml")"
ok "wrote $FDROIDDATA/metadata/$APPID.yml"
save_answers

# ================================================================ 4. validate
step "4/5  Validation"
if [ "$RUNNER" = none ]; then
  warn "no fdroidserver — skipping readmeta/rewritemeta/lint"
  warn "the maintainers' CI will run these anyway, so expect to fix what it reports"
else
  VALIDATE_AGAIN=1
  VALID_ROUNDS=0
  while [ "$VALIDATE_AGAIN" = 1 ]; do
  VALIDATE_AGAIN=0
  VALID_ROUNDS=$((VALID_ROUNDS + 1))
  VALID_FAIL=""
  # fdroidserver complains about this on every single command it runs.
  if [ -f "$FDROIDDATA/config.yml" ]; then
    case "$(stat -c '%a' "$FDROIDDATA/config.yml" 2>/dev/null || echo 600)" in
      *00) ;;
      *) chmod 600 "$FDROIDDATA/config.yml" && note "chmod 600 config.yml (fdroidserver insists)" ;;
    esac
  fi

  # readmeta takes no app argument: it parses every metadata/*.yml in the clone.
  # So an unrelated upstream entry — typically one written for a newer
  # fdroidserver than the one installed here — fails it, which says nothing
  # about our file. Only count it when the complaint names our app.
  say "fdroid readmeta"
  if ! frun readmeta > "$WORK/readmeta.log" 2>&1; then
    sed 's/^/     /' "$WORK/readmeta.log"
    if grep -Fq "$APPID" "$WORK/readmeta.log"; then
      VALID_FAIL="$VALID_FAIL readmeta"
    else
      warn "readmeta tripped over another app in fdroiddata, not $APPID"
      note "an upstream entry your fdroidserver is too old to parse — not your problem"
      note "rewritemeta and lint below only look at your app, so trust those"
    fi
  fi
  say "fdroid rewritemeta $APPID"; frun rewritemeta "$APPID" || VALID_FAIL="$VALID_FAIL rewritemeta"
  # CI's rewritemeta (Debian's ruamel.yaml 0.18) gives a word longer than a line
  # a line of its own; a newer local fdroid does not, and CI then fails the job.
  CIW="$(rcp ciwrap "$FDROIDDATA/metadata/$APPID.yml" || true)"
  [ -n "$CIW" ] && note "laid out long values the way fdroiddata's CI does: $(printf '%s' "$CIW" | tr '\n' ' ')"
  say "fdroid lint $APPID";        frun lint "$APPID"        || VALID_FAIL="$VALID_FAIL lint"

  # fdroiddata's CI validates every changed file against schemas/metadata.json
  # before anything else. lint does not do this, so a file that passes lint can
  # still be rejected minutes later; run the same check here.
  SCHEMA="$FDROIDDATA/schemas/metadata.json"
  if [ ! -f "$SCHEMA" ]; then
    note "no schemas/metadata.json in the clone — skipping the schema check"
  elif have check-jsonschema; then
    say "check-jsonschema metadata/$APPID.yml"
    ( cd "$FDROIDDATA" && check-jsonschema --schemafile schemas/metadata.json \
        "metadata/$APPID.yml" ) || VALID_FAIL="$VALID_FAIL schema"
  elif python3 -c 'import jsonschema, yaml' 2>/dev/null; then
    say "validating against schemas/metadata.json (python jsonschema)"
    python3 - "$SCHEMA" "$FDROIDDATA/metadata/$APPID.yml" <<'PYSCHEMA' || VALID_FAIL="$VALID_FAIL schema"
import json, sys, jsonschema, yaml
schema = json.load(open(sys.argv[1]))
doc = yaml.safe_load(open(sys.argv[2]))
errors = sorted(jsonschema.Draft7Validator(schema).iter_errors(doc), key=lambda e: list(e.path))
for e in errors:
    print("   $." + ".".join(str(p) for p in e.path) + ": " + e.message)
sys.exit(1 if errors else 0)
PYSCHEMA
  else
    note "no check-jsonschema — CI validates against schemas/metadata.json, you cannot"
    note "install it with: pipx install check-jsonschema   (or nix profile install nixpkgs#check-jsonschema)"
  fi
  if [ "$YMLSUM" != "$(cksum < "$FDROIDDATA/metadata/$APPID.yml")" ]; then
    note "rewritemeta reformatted the file — that is normal"
  fi

  if [ -n "$VALID_FAIL" ]; then
    warn "failed:$VALID_FAIL — maintainers' CI would reject this as it is"
    if [ "$ASSUME_YES" = 1 ]; then
      KEEP_WORK=1
      die "fix metadata/$APPID.yml in $FDROIDDATA and re-run"
    fi
    # After a few rounds, editing plainly is not fixing it: stop offering, so a
    # file that cannot pass (or an editor that changes nothing) cannot spin here.
    if [ "$VALID_ROUNDS" -ge 4 ]; then
      warn "still failing after $VALID_ROUNDS attempts — no more edit rounds"
      printf '   %sp) push it anyway   s) stop%s [s]: ' "$B" "$R" >&2
      readline VALID_CH
      case "${VALID_CH:-s}" in
        p|P*) ;;
        *)    KEEP_WORK=1; die "fix metadata/$APPID.yml in $FDROIDDATA and re-run" ;;
      esac
    else
      printf '   %se) edit and check again   p) push it anyway   s) stop%s [e]: ' "$B" "$R" >&2
      readline VALID_CH
      case "${VALID_CH:-e}" in
        p|P*) ;;
        s|S*) KEEP_WORK=1; die "fix metadata/$APPID.yml in $FDROIDDATA and re-run" ;;
        *)    if edit_file "$FDROIDDATA/metadata/$APPID.yml"; then
                YMLSUM="$(cksum < "$FDROIDDATA/metadata/$APPID.yml")"
                VALIDATE_AGAIN=1
              fi ;;
      esac
    fi
  else
    ok "metadata validates"
  fi
  done

  # The full build is the best predictor of acceptance, but slow (Android SDK,
  # the whole toolchain): only with --build, or when asked for with --ask. It is
  # outside the check-and-edit loop above: nobody wants it repeated on every edit.
  if [ "$RUN_BUILD" = 1 ] || { [ "$ASK_ALL" = 1 ] && confirm "Run 'fdroid build -v -l $APPID' now (slow)?" n; }; then
    say "fdroid build -v -l $APPID"
    if ! frun build -v -l "$APPID"; then
      warn "the build failed — F-Droid's CI would fail the same way"
      if [ "$ASSUME_YES" = 1 ] || ! go "Carry on and push anyway?"; then
        KEEP_WORK=1
        die "fix the app or metadata/$APPID.yml in $FDROIDDATA, then re-run"
      fi
    fi
  else
    note "full build skipped (--build to run it; F-Droid's CI builds it anyway)"
  fi
fi

# A recipe copy kept in the app repo (e.g. fdroid/<appid>.yml) is offered the
# final file, so it never drifts from the merge request. It is not committed.
APP_COPY=""
case "$BASE_KIND" in app) APP_COPY="${BASE_FILE#"$REPO"/}" ;; esac
[ -z "$APP_COPY" ] && [ -f "$REPO/fdroid/$APPID.yml" ] && APP_COPY="fdroid/$APPID.yml"
if [ -n "$APP_COPY" ] && ! cmp -s "$FDROIDDATA/metadata/$APPID.yml" "$REPO/$APP_COPY"; then
  if confirm "Copy the final recipe to $APP_COPY in your app repo too? (not committed there)" y; then
    cp "$FDROIDDATA/metadata/$APPID.yml" "$REPO/$APP_COPY"
    ok "updated $APP_COPY — commit it with your next change"
  fi
fi

# The app's display name, for titles: the fastlane title, else the ID.
APPNAME="$(for f in "$REPO/fastlane/metadata/android/en-US/title.txt" \
                   ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US/title.txt"}; do
             [ -f "$f" ] && { sed -n 1p "$f"; break; }; done)"
APPNAME="${APPNAME:-$APPID}"

# ================================================== 4b. RFP issue (optional)
# Filled from F-Droid's own template (gitlab.com/fdroid/rfp, the Default issue
# template) with the answers above. Opened with glab if it's logged in, else
# GitLab's API with $GITLAB_TOKEN, else as a pre-filled page in the browser
# for you to check and submit. `gh` can't help: the RFP tracker is on GitLab.
RFP_URL=""
RFP_REF=""
GITLAB_API_ROOT="${GITLAB_API_ROOT:-https://gitlab.com/api/v4}"
RFP_PROJECT="fdroid/rfp"


fastlane_text() {  # fastlane_text <file> — first match in the usual places
  local f
  for f in "$REPO/fastlane/metadata/android/en-US/$1" \
           ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US/$1"}; do
    [ -f "$f" ] && { cat "$f"; return 0; }
  done
  return 1
}

RFP_WANTED=0
if [ "$IS_UPDATE" = 0 ]; then
  if [ "$WANT_RFP" = 1 ]; then RFP_WANTED=1
  elif [ "$ASK_ALL" = 1 ]; then confirm "Open an RFP issue for this app on gitlab.com/$RFP_PROJECT?" n && RFP_WANTED=1
  else note "no RFP issue (optional when you send the metadata yourself; --rfp to open one)"
  fi
fi
if [ "$RFP_WANTED" = 1 ]; then
  step "Request For Packaging issue"
  if :; then
    auto RFP_NAME "App name" "$APPNAME"
    RFP_SUMMARY="$(fastlane_text short_description.txt 2>/dev/null | sed -n 1p || true)"
    [ -n "$RFP_SUMMARY" ] || RFP_SUMMARY="${SUMMARY:-}"
    auto RFP_SUMMARY "Summary" "$RFP_SUMMARY"
    RFP_DESC="$(fastlane_text full_description.txt 2>/dev/null || true)"
    [ -n "$RFP_DESC" ] || RFP_DESC="${FULLDESC:-$RFP_SUMMARY}"
    auto RFP_WHY "Why it belongs in F-Droid" \
      "I'm the developer; the metadata merge request is ready to go."

    RFP_BODY="$WORK/rfp.md"
    {
      printf '<!-- filled in by fdroid-submit.sh from the RFP template -->\n\n'
      printf '```yaml\n'
      printf 'Categories:\n'
      old_ifs="$IFS"; IFS='|'
      for c in $CATEGORIES; do printf ' - %s\n' "$c"; done
      IFS="$old_ifs"
      printf 'License: %s\n' "$LICENSE"
      printf 'AuthorName: %s\n' "${AUTHORNAME:-}"
      printf 'AuthorEmail: %s\n' "${AUTHOREMAIL:-}"
      printf 'AuthorWebSite: %s\n' "${AUTHORSITE:-}"
      printf 'WebSite: %s\n' "${WEBSITE:-}"
      printf 'SourceCode: %s\n' "$SOURCE"
      printf 'IssueTracker: %s\n' "${ISSUES:-}"
      printf 'AutoName: %s\n' "$RFP_NAME"
      printf 'RepoType: git\n'
      printf 'Repo: %s\n' "$REPOURL"
      printf '```\n\n'
      printf '### Why should it be included?\n\n%s\n\n' "$RFP_WHY"
      printf '### Summary\n\n%s\n\n' "$RFP_SUMMARY"
      printf '### Description\n\n%s\n\n' "$RFP_DESC"
      printf 'Metadata: `metadata/%s.yml` on branch `%s` of %s.\n' "$APPID" "$BRANCH" "$FORKURL"
    } > "$RFP_BODY"

    say "Title: $RFP_NAME"
    printf '%s' "$DIM"; sed 's/^/   | /' "$RFP_BODY"; printf '%s' "$R"

    if [ "$DRYRUN" = 1 ]; then
      warn "dry run — not opening the issue"
    elif have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; then
      say "opening it with glab…"
      RFP_URL="$(glab_fd issue create -R "$RFP_PROJECT" --title "$RFP_NAME" \
                   --description "$(cat "$RFP_BODY")" --yes 2>&1 \
                 | grep -Eo 'https://[^ ]+/-/issues/[0-9]+' | tail -1 || true)"
      [ -n "$RFP_URL" ] || warn "glab did not report an issue URL — check $RFP_PROJECT"
    elif [ -n "${GITLAB_TOKEN:-}" ]; then
      say "opening it through the GitLab API…"
      RFP_STATUS="$(curl -sS -o "$WORK/rfp.json" -w '%{http_code}' \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --data-urlencode "title=$RFP_NAME" \
        --data-urlencode "description@$RFP_BODY" \
        "$GITLAB_API_ROOT/projects/$(urlencode "$RFP_PROJECT")/issues" || echo 000)"
      case "$RFP_STATUS" in
        2*) RFP_URL="$(grep -Eo 'https://[^"]+/-/issues/[0-9]+' "$WORK/rfp.json" | sed -n 1p)" ;;
        *)  warn "GitLab answered HTTP $RFP_STATUS — the issue was not created"
            note "the token needs the 'api' scope" ;;
      esac
    else
      # No CLI or token: GitLab's new-issue page takes the title and text as
      # query parameters, so you only have to check them and press Create.
      NEWURL="https://gitlab.com/$RFP_PROJECT/-/issues/new?issue%5Btitle%5D=$(urlencode "$RFP_NAME")&issue%5Bdescription%5D=$(urlencode "$(cat "$RFP_BODY")")"
      say "No glab login or GITLAB_TOKEN — opening a pre-filled issue in your browser."
      note "check it and press 'Create issue' (sign in to GitLab first if asked)"
      if have xdg-open; then xdg-open "$NEWURL" >/dev/null 2>&1 &
      elif have open; then open "$NEWURL" >/dev/null 2>&1 &
      else note "open this link:"; printf '   %s\n' "$NEWURL"
      fi
      ask_opt RFP_URL "Paste the issue's URL once created (blank to skip)" ""
    fi
    if [ -n "$RFP_URL" ]; then
      ok "RFP issue: $RFP_URL"
      RFP_REF="$RFP_PROJECT#${RFP_URL##*/}"
    fi
  fi
fi

# ==================================================================== 5. push
step "5/5  Commit and push"
git -C "$FDROIDDATA" add "metadata/$APPID.yml"
git -C "$FDROIDDATA" --no-pager diff --cached --stat

if git -C "$FDROIDDATA" diff --cached --quiet; then
  die "nothing staged — metadata/$APPID.yml is identical to upstream"
fi
CHANGED="$(git -C "$FDROIDDATA" diff --cached --name-only | wc -l)"
[ "$CHANGED" = 1 ] || warn "$CHANGED files staged — an MR should normally touch only one"

# fdroiddata's titles: "New app: <name>", and updates name the version.
if [ "$IS_UPDATE" = 1 ]; then
  MSG="Update $APPNAME to $VNAME"
else
  MSG="New app: $APPNAME"
fi
auto COMMITMSG "Commit message" "$MSG"

# The merge request text: fdroiddata's own template, with the boxes this
# wizard has actually checked ticked, and the RFP linked.
mr_description() {
  local tpl="App inclusion.md" line
  [ "$IS_UPDATE" = 1 ] && tpl="App update.md"
  if [ "$IS_UPDATE" = 1 ]; then
    printf 'Update %s to %s (versionCode %s).\n\n' "$APPNAME" "$VNAME" "$VCODES"
  else
    printf 'New app: **%s** — %s\n\n' "$APPNAME" "${RFP_SUMMARY:-$(fastlane_text short_description.txt 2>/dev/null | sed -n 1p || true)}"
    printf 'Submitted by the app'"'"'s author.\n\n'
  fi
  [ -n "$RFP_REF" ] && printf 'Closes %s\n\n' "$RFP_REF"
  git -C "$FDROIDDATA" show "$BASE:.gitlab/merge_request_templates/$tpl" 2>/dev/null \
    | while IFS= read -r line; do
        case "$line" in
          "* [ ] Metadata must be put in"*|"* [ ] Metadata must use LF"*|"* [ ] Please only submit one app"*|\
          "* [ ] The \`commit\` field should be the full hash"*|"* [ ] An AuthorName must be added"*)
            line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] Metadata must be a valid YAML file"*)
            [ "$RUNNER" != none ] && [ -z "${VALID_FAIL:-}" ] && line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] Releases are tagged and auto update is enabled"*)
            [ "${AUM:-None}" != None ] && line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] Setup abi split"*)
            [ "$ABISPLIT" = 1 ] && line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] The upstream app source code repo contains the app metadata"*)
            fastlane_text short_description.txt >/dev/null 2>&1 && line="* [x] ${line#\* \[ \] }" ;;
        esac
        printf '%s\n' "$line"
      done
}

if [ "$DRYRUN" = 1 ]; then
  warn "dry run — not committing, pushing or opening a merge request"
  note "so 'fdroid checkupdates --auto' was not run either: it needs the commit,"
  note "and CI fails the job on any diff it would produce"
  note "$FDROIDDATA (branch $BRANCH)"
  exit 0
fi
if ! go "Commit and push to $FORKURL ($BRANCH)?"; then
  say "Nothing pushed. The branch and file are ready at:"
  note "$FDROIDDATA (branch $BRANCH)"
  exit 0
fi
# A fresh clone may have no identity of its own; use the app repo's.
ID_ARGS=()
if [ -z "$(git -C "$FDROIDDATA" config user.email 2>/dev/null || true)" ]; then
  ID_ARGS=(-c "user.name=$(git -C "$REPO" config user.name 2>/dev/null || echo "${AUTHORNAME:-fdroid-submit}")"
           -c "user.email=$(git -C "$REPO" config user.email 2>/dev/null || echo "${AUTHOREMAIL:-nobody@example.com}")")
fi
git -C "$FDROIDDATA" "${ID_ARGS[@]}" commit -q -m "$COMMITMSG"

# fdroiddata's CI runs `fdroid checkupdates --auto` on the branch and then fails
# the job on any diff it produced: whatever that command writes — AutoName, read
# out of the app's AndroidManifest, or a build for a newer tag — has to be in the
# file already. Nothing else tells you this; lint and the schema are both happy
# without it. It refuses to run on a metadata repo with uncommitted changes, so
# it belongs here, just after the commit, and what it writes is folded into that
# same commit to keep the merge request to one clean change. It clones the app
# repo, so give it a moment.
if [ "$RUNNER" != none ]; then
  #  * without --allow-dirty it refuses to run at all when the clone has any
  #    change or untracked file, and says only "Build metadata git repo has
  #    uncommited changes!". We pass it, so leftovers no longer block the check.
  # Three traps here, none of them yours:
  #  * fdroiddata's committed config.yml is F-Droid's own production config, with
  #    serverwebroot and the signing keys as {env: …} placeholders. Their CI sets
  #    those; your clone cannot, so checkupdates logs an ERROR about the blank
  #    serverwebroot while doing its actual work perfectly well. Give it a
  #    throwaway sink and it runs without complaining.
  #  * with -v it exits non-zero if any ERROR was logged, which turns that
  #    harmless complaint into a failed run. CI passes -v because there the
  #    variables are set and nothing is logged. We drop it and read the log.
  #  * without --allow-dirty it refuses to run at all if the clone holds any
  #    change or untracked file, saying only "Build metadata git repo has
  #    uncommited changes!". We pass it.
  say "fdroid checkupdates --auto $APPID (the CI check that compares diffs)"
  # rsync will not create nested directories, and it deploys into repo/status/:
  # make the whole path or it fails and logs an error for every status file.
  mkdir -p "$WORK/deploy-sink/repo/status"
  if serverwebroot="$WORK/deploy-sink" \
     frun checkupdates --auto --allow-dirty "$APPID" > "$WORK/checkupdates.log" 2>&1; then
    # it writes the file with the local fdroid's layout: put CI's back first
    rcp ciwrap "$FDROIDDATA/metadata/$APPID.yml" >/dev/null || true
    CU_ERRORS="$(grep -c 'ERROR' "$WORK/checkupdates.log" || true)"
    if [ "${CU_ERRORS:-0}" -gt 0 ]; then
      warn "checkupdates logged $CU_ERRORS error(s) — usually fdroiddata's config.yml"
      warn "wanting F-Droid's own deploy environment, which only their CI has:"
      grep 'ERROR' "$WORK/checkupdates.log" | head -3 | sed 's/^/       /'
      note "harmless here, but it means this check may not have been complete"
    fi
    if git -C "$FDROIDDATA" diff --quiet -- "metadata/$APPID.yml"; then
      ok "checkupdates has nothing to add"
    else
      note "checkupdates filled in what CI expects:"
      git -C "$FDROIDDATA" --no-pager diff -- "metadata/$APPID.yml" \
        | sed -n 's/^\([+-][^+-]\)/     \1/p'
      git -C "$FDROIDDATA" add "metadata/$APPID.yml"
      git -C "$FDROIDDATA" "${ID_ARGS[@]}" commit -q --amend --no-edit
      ok "folded into the commit — CI fails on any diff this command produces"
    fi
  else
    warn "checkupdates could not run:"
    tail -5 "$WORK/checkupdates.log" | sed 's/^/     /'
    note "CI runs it too, and fails the job on any diff it would produce"
    note "AutoName is already in the file, so this is only a second opinion —"
    note "what it would still catch is a newer tag than the one being submitted"
    if ! go "Push anyway?"; then
      KEEP_WORK=1
      die "the log is in $WORK/checkupdates.log"
    fi
  fi
fi

# fdroiddata is a very large repo and the first push to a fresh fork can send a
# lot of history. Dropping -q is the whole trick: git then reports its own
# progress on a terminal. Foreground on purpose, so an SSH key passphrase or a
# host-key prompt can still reach you.
say "pushing $BRANCH to your fork — the slowest step here."
note "fdroiddata is huge; the first push to a new fork can take a few minutes."
note "git's own progress follows; leave it be until it finishes."
PUSH_T0=$SECONDS
# A re-run for the same app/version replaces the branch it pushed before.
if ! git -C "$FDROIDDATA" push -f -u origin "$BRANCH"; then
  warn "could not push to $FORKURL"
  note "check with: ssh -T git@gitlab.com   (it should greet @$GLUSER), then re-run"
  die "push failed"
fi
ok "pushed $BRANCH ($((SECONDS - PUSH_T0))s)"
# Everything the merge request needs later, so `-p` can open it on its own —
# including the description, which is built from things only this run knows.
remember ST_BRANCH "$BRANCH"
remember ST_STATUS pushed
remember ST_UPBRANCH "$UPBRANCH"
remember ST_COMMITMSG "$COMMITMSG"
remember ST_APPNAME "$APPNAME"
remember ST_RFP_REF "${RFP_REF:-}"
if [ -n "$TASK_FILE" ]; then
  mr_description > "${TASK_FILE%.conf}.mr.md" 2>/dev/null || true
fi

# A re-run pushes the same branch again, and GitLab updates any open merge
# request from it by itself. Creating a second one is impossible and reporting
# a failure would be wrong, so look first.
MR_URL=""
MR_OPEN="$(existing_mr || true)"
if [ -n "$MR_OPEN" ]; then
  MR_URL="$MR_OPEN"
  ok "a merge request from $BRANCH is already open — the push above updated it"
  ok "$MR_URL"
  remember ST_MR "$MR_URL"; remember ST_STATUS submitted
  note "CI re-runs on the new commit"
  if [ -n "$TASK_FILE" ]; then
    mr_description > "${TASK_FILE%.conf}.mr.md" 2>/dev/null || true
    sync_mr_description "$MR_URL" "${TASK_FILE%.conf}.mr.md"
  fi
elif glab_ready && go "Open the merge request on fdroid/fdroiddata?"; then
  mr_description > "$WORK/mr.md"
  MR_OUT="$(glab_fd mr create -R fdroid/fdroiddata -H "$(fork_path "$FORKURL")" \
              -s "$BRANCH" -b "$UPBRANCH" -t "$COMMITMSG" \
              -d "$(cat "$WORK/mr.md")" --allow-collaboration -y 2>&1 || true)"
  MR_URL="$(printf '%s\n' "$MR_OUT" | grep -Eo 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1 || true)"
  if [ -n "$MR_URL" ]; then
    ok "merge request: $MR_URL"
    remember ST_MR "$MR_URL"; remember ST_STATUS submitted
  else
    warn "glab did not open the merge request:"
    printf '%s\n' "$MR_OUT" | tail -5 | sed 's/^/       /'
    note "to retry by hand: cd $FDROIDDATA && glab mr create -R fdroid/fdroiddata \\"
    note "     -H $(fork_path "$FORKURL") -s $BRANCH -b $UPBRANCH -t \"$COMMITMSG\""
    note "the link below does the same thing in a browser"
  fi
fi
if [ -z "$MR_URL" ]; then
  MRURL="https://gitlab.com/$GLUSER/fdroiddata/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BRANCH&merge_request%5Btarget_branch%5D=$UPBRANCH"
  [ -n "$RFP_REF" ] && MRURL="$MRURL&merge_request%5Bdescription%5D=$(urlencode "Closes $RFP_REF")"
  say "${B}Open the merge request:${R} $MRURL"
  note "target fdroid/fdroiddata, branch $UPBRANCH, title \"$COMMITMSG\""
fi
[ -n "$RFP_REF" ] && note "it links the RFP issue ($RFP_REF)"
note "expect roughly 24-48 hours from merge until the app appears in F-Droid"
}

wizard_fdroid "$@"
