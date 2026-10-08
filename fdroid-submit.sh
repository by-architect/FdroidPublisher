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
# recipe can be shaped app by app. It runs the checks fdroiddata's pipeline
# runs, with the newest fdroidserver, then pushes a branch and — with glab
# logged in — opens the merge request.
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
TASK_DIR="$CONF_DIR/tasks"     # one task per app: its answers, and how its submissions went
STORE_ID=fdroid
PR_ONLY=0      # -p: pick a finished task and open its merge request
STATUS_ONLY=0  # --status: how each app's submission is doing, then exit
STATUS_APP=""

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
      --status [ID] how each app's submission is doing: F-Droid, the merge
                    request, its pipeline, the reviewers' comments — then exit
      --forget      delete every remembered answer and task, and exit
      --forget-app  forget the task of one application id
      --forget-task forget one task by name (as the task list shows it)

Detects what it can from your app's git checkout and only asks for the rest,
writes metadata/<applicationId>.yml into your fdroiddata fork, runs the
checks fdroiddata's pipeline runs (with the newest fdroidserver, downloaded
on first use), pushes a branch and — with glab logged in — opens the merge
request as a
draft, watches its pipeline, and marks it ready for review once it passes.
Each app is one task, which follows it from the first merge request to
F-Droid and through every update after.
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
    --status)     STATUS_ONLY=1
                  case "${2-}" in ''|-*) ;; *) STATUS_APP="$2"; shift ;; esac ;;
    --forget-task) FORGET_TASK="${2-}"; shift
                  [ -n "$FORGET_TASK" ] || { printf 'which task? --forget-task <name>\n' >&2; exit 2; }
                  rm -f "$TASK_DIR/$FORGET_TASK.conf" "$TASK_DIR/$FORGET_TASK.mr.md" "$TASK_DIR/$FORGET_TASK.log"
                  printf 'forgot task %s\n' "$FORGET_TASK"; exit 0 ;;
    --forget-app) FORGET_APP="${2-}"; shift
                  [ -n "$FORGET_APP" ] || { printf 'which app? --forget-app <applicationId>\n' >&2; exit 2; }
                  rm -f "$TASK_DIR/$STORE_ID-$FORGET_APP".conf "$TASK_DIR/$STORE_ID-$FORGET_APP".mr.md \
                        "$TASK_DIR/$STORE_ID-$FORGET_APP".log
                  printf 'forgot the task for %s\n' "$FORGET_APP"; exit 0 ;;
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
# One task per app. $TASK_DIR/fdroid-<appid>.conf holds every answer the app
# has been given and where its submission stands — the version being sent, the
# tag, the branch, the merge request, its pipeline, the last comment you saw —
# and fdroid-<appid>.log is its timeline: the merge request opened as a draft,
# the pipeline, marked ready, the reviewers' comments, merged, published, then
# the next update. A re-run walks all five sections again — that is the point,
# they check each other — but every question comes back with last time's
# answer as its default, and every finished step is recognised, not redone.
declare -A MEM=()
TASK_FILE=""
task_id() { printf '%s-%s' "$STORE_ID" "${APPID:-unknown}"; }
tlog() {  # tlog <event> — one line in this app's timeline
  { [ "$SAVE" = 1 ] && [ -n "$TASK_FILE" ]; } || return 0
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "${TASK_FILE%.conf}.log"
}

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
state_load() {  # this app's task: load it
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
    printf '# fdroid-submit.sh — task %s (one per app)\n' "$(basename "${TASK_FILE%.conf}")"
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

# Tasks used to be one per version: fdroid-<appid>-<versionCode>.conf. They
# are folded into one per app — the newest answers win, and what each version
# got to starts the app's timeline. The old files are kept in per-version/.
migrate_per_app() {
  local f b vc id ids=""
  for f in "$TASK_DIR/$STORE_ID"-*-[0-9]*.conf; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .conf)"; vc="${b##*-}"
    case "$vc" in *[!0-9]*) continue ;; esac
    id="${b#"$STORE_ID"-}"; id="${id%-*}"
    case " $ids " in *" $id "*) ;; *) ids="$ids $id" ;; esac
  done
  [ -n "$ids" ] || return 0
  mkdir -p "$TASK_DIR/per-version"
  for id in $ids; do
    (
      out="$TASK_DIR/$STORE_ID-$id.conf"; log="$TASK_DIR/$STORE_ID-$id.log"
      declare -A ALL=() REM=()
      if [ -f "$out" ]; then
        # shellcheck disable=SC1090
        . "$out" 2>/dev/null || true
        for k in "${!REM[@]}"; do ALL["$k"]="${REM[$k]}"; done
      fi
      while IFS=$'\t' read -r vc f; do
        REM=()
        # shellcheck disable=SC1090
        . "$f" 2>/dev/null || continue
        for k in "${!REM[@]}"; do [ -n "${REM[$k]}" ] && ALL["$k"]="${REM[$k]}"; done
        printf '%s  %s (%s): %s%s\n' "${REM[ST_RUN]:-?}" "${REM[VNAME]:-?}" "${REM[VCODE]:-$vc}" \
          "${REM[ST_STATUS]:-started}" "${REM[ST_MR]:+ — ${REM[ST_MR]}}" >> "$log"
        if [ -f "${f%.conf}.mr.md" ]; then
          cp "${f%.conf}.mr.md" "${out%.conf}.mr.md"
          mv -f "${f%.conf}.mr.md" "$TASK_DIR/per-version/"
        fi
        mv -f "$f" "$TASK_DIR/per-version/"
      done < <(for f in "$TASK_DIR/$STORE_ID-$id"-[0-9]*.conf; do
                 b="$(basename "$f" .conf)"; printf '%s\t%s\n' "${b##*-}" "$f"
               done | sort -n)
      ALL[ST_VNAME]="${ALL[VNAME]:-}"; ALL[ST_VCODE]="${ALL[VCODE]:-}"
      # an open merge request outlives the version it was opened for
      [ -n "${ALL[ST_MR]:-}" ] && case "${ALL[ST_STATUS]:-}" in started|pushed|'') ALL[ST_STATUS]=submitted ;; esac
      {
        printf '# fdroid-submit.sh — task %s (one per app)\n' "$STORE_ID-$id"
        printf '# delete this file, or run --forget-app %s, to start it afresh\n' "$id"
        for k in "${!ALL[@]}"; do printf 'REM[%s]=%q\n' "$k" "${ALL[$k]}"; done
      } > "$out"
      chmod 600 "$out" 2>/dev/null || true
    )
    note "$id: its tasks, one per version until now, are one task for the app"
  done
}

# task_rows — one line per app, newest first:
#   <file>TAB<appid>TAB<version>TAB<status in words>TAB<when>TAB<status>TAB<branch>
task_rows() {
  local f
  for f in $(ls -t "$TASK_DIR/$STORE_ID"-*.conf 2>/dev/null || true); do
    [ -f "$f" ] || continue
    (
      declare -A REM=()
      # shellcheck disable=SC1090
      . "$f" 2>/dev/null || exit 0
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" \
        "${REM[ST_APPID]:-${REM[APPID]:-?}}" \
        "${REM[ST_VNAME]:-${REM[VNAME]:-?}}+${REM[ST_VCODE]:-${REM[VCODE]:-?}}" \
        "$(status_words "${REM[ST_STATUS]:-started}" "${REM[ST_PIPE]:-}" "${REM[ST_REPLY]:-0}")" \
        "${REM[ST_RUN]:-}" "${REM[ST_STATUS]:-started}" "${REM[ST_BRANCH]:-}"
    )
  done
}

# pick_task [with-branch] — show the apps' tasks and load the chosen one.
# Selecting one makes its answers the defaults for this run; with a filter,
# only apps with a branch on the fork are offered. Returns 1 when nothing was
# picked — "n" is a new app, whose repo is then asked for.
pick_task() {
  local want="${1-}" rows=() row n=0 f appid ver st when choice
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$want" in
      '') ;;
      *) [ -n "$(printf '%s' "$row" | cut -f7)" ] || continue ;;
    esac
    rows+=("$row")
  done <<EOF
$(task_rows)
EOF
  [ "${#rows[@]}" -gt 0 ] || return 1
  step "Your apps"
  for row in "${rows[@]}"; do
    n=$((n + 1))
    appid="$(printf '%s' "$row" | cut -f2)"
    ver="$(printf '%s' "$row" | cut -f3)"
    st="$(printf '%s' "$row" | cut -f4)"
    when="$(printf '%s' "$row" | cut -f5)"
    printf '     %2d) %-30s %-11s %s  %s%s%s\n' "$n" "$appid" "$ver" "$st" "$DIM" "$when" "$R"
  done
  [ -z "$want" ] && printf '     %2s) %s\n' "n" "another app — a new task, its repo asked for"
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
  return 0
}

# ------------------------------------------------------------------- fdroid CLI
# The checks run on fdroidserver's newest code — what fdroiddata's pipeline
# runs — so they find what the pipeline would, and nothing it would not: an
# older release trips over other apps' newer recipes and lays files out its own
# way. It is a git checkout in a folder of your choosing (or one you have
# already, cloned for something else), brought up to date on each run. Its
# Python libraries come from this system or — when they are missing there —
# from an installed fdroid, which carries them all. If it still does not run
# here, the local checks are skipped: the merge request's pipeline runs every
# one of them anyway.
RUNNER=""
FDROIDSERVER_DIR=""
FDROID_PY=""       # a python with the checkout's libraries, for fdroiddata's tools/
FD_SCANNER_OK=0    # its scanner loads too: APKs can be scanned, `fdroid build` can run
FDROIDSERVER_GIT="https://gitlab.com/fdroid/fdroidserver.git"
FDROIDSERVER_MIRROR="https://github.com/f-droid/fdroidserver.git"
# Where it is downloaded to by default: the tools/ folder of this wizard's own
# project, when the wizard lives in a <project>/branches/<branch> layout — the
# tools a project uses live next to it there — else ~/Opt/fdroidserver.
SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TOOLS_DIR=""
if [ "$(basename "$(dirname "$SELF_DIR")")" = branches ]; then
  TOOLS_DIR="$(dirname "$(dirname "$SELF_DIR")")/tools"
fi
FD_DEFAULT="$HOME/Opt/fdroidserver"
[ -z "$TOOLS_DIR" ] || FD_DEFAULT="$TOOLS_DIR/fdroidserver"

fd_is_checkout() { [ -f "$1/fdroid" ] && [ -d "$1/fdroidserver" ]; }
fd_candidates() {  # checkouts this machine may have already, the likeliest first
  local d
  for d in "${FDROIDSERVER:-}" "${SAVED_FDROIDSERVER:-}" "$FD_DEFAULT" \
           "$HOME/Opt/fdroidserver" "$HOME/opt/fdroidserver" "$HOME/fdroidserver" \
           "$HOME/src/fdroidserver" "$HOME/Projects/fdroidserver" "$HOME"/Projects/*/tools/fdroidserver \
           "$HOME"/Projects/*/fdroidserver "$HOME"/Projects/*/referanced-repo*/fdroidserver \
           "$HOME"/Projects/*/branches/*/referanced-repo*/fdroidserver; do
    if [ -n "$d" ]; then printf '%s\n' "${d/#\~/$HOME}"; fi
  done
}
fd_git() {  # git for fdroidserver's own public repo: never a password or passphrase
            # prompt, and https stays https even when your git config reroutes it to ssh
  local t="" envs=(GIT_TERMINAL_PROMPT=0 "GIT_SSH_COMMAND=ssh -o BatchMode=yes")
  have timeout && t="timeout 300"
  [ -n "$GIT_CFG_OFF" ] && envs+=(GIT_CONFIG_GLOBAL=/dev/null)
  # shellcheck disable=SC2086
  env "${envs[@]}" $t git "$@"
}
fd_update() {  # fd_update <checkout> — fast-forward it to master, when that is safe
  local ck="$1" br
  git -C "$ck" rev-parse --git-dir >/dev/null 2>&1 || return 0   # not a git checkout: as it is
  br="$(git -C "$ck" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  case "$br" in
    master|main) ;;
    *) note "$ck is on ${br:-a detached commit}, not master — used as it is"; return 0 ;;
  esac
  if [ -n "$(git -C "$ck" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
    note "$ck holds changes of yours — not updated, used as it is"; return 0
  fi
  say "bringing fdroidserver in $ck up to date…"
  fd_git -C "$ck" pull -q --ff-only >/dev/null 2>&1 \
    || note "could not update it (offline?) — using it as it is"
}
fd_download() {  # fd_download <new folder> — a shallow clone of fdroidserver's master
  local ck="$1" url
  if [ -e "$ck" ] && [ -n "$(ls -A "$ck" 2>/dev/null || true)" ]; then
    warn "$ck is not empty — choose a new folder"; return 1
  fi
  mkdir -p "$(dirname "$ck")" || return 1
  say "downloading fdroidserver into $ck (about 30 MB)…"
  for url in "$FDROIDSERVER_GIT" "$FDROIDSERVER_MIRROR"; do
    fd_git clone -q --depth 1 "$url" "$ck" 2>/dev/null && return 0
    rm -rf "$ck"    # it was new or empty: what is there now is the failed download
    note "could not download it from $url"
  done
  return 1
}

# fd_pythons — "python TAB library folders" pairs that may run the checkout:
# this system's python3, then the interpreter of an installed fdroid with the
# folders it adds (a Nix wrapper lists them; a pip or venv one needs none).
fd_pythons() {
  local w real wrapped py dirs
  have python3 && printf '%s\t[]\n' "$(command -v python3)"
  have fdroid || return 0
  w="$(command -v fdroid)"; real="$(readlink -f "$w")"
  wrapped="$(dirname "$real")/.fdroid-wrapped"
  if [ -f "$wrapped" ]; then
    py="$(head -1 "$wrapped" | sed 's/^#!//')"
    # the file package's magic.py shadows python-magic, and does not even load
    dirs="$(grep -o "\[\('/nix/store/[^']*site-packages',\?\)*\]" "$wrapped" | head -1 \
            | sed -E "s#'/nix/store/[^']*-file-[0-9][^']*',?##g")"
    if [ -n "$py" ]; then printf '%s\t%s\n' "$py" "${dirs:-[]}"; fi
  else
    py="$(head -1 "$real" | sed -n 's/^#!//p' | awk '{print $1}')"
    case "$py" in */python*) printf '%s\t[]\n' "$py" ;; esac
  fi
  return 0
}

fd_make() {  # fd_make <checkout> <python> <folders> — the two launchers, then a test
  local ck="$1" py="$2" dirs="$3"
  cat > "$WORK/fdroid-py" <<FDPY
#!$py
# written by fdroid-submit.sh: python with fdroidserver's checkout first
import runpy, site, sys
for p in $dirs:
    site.addsitedir(p)
sys.path.insert(0, '$ck')
try:
    import magic
except Exception:
    # no python-magic that loads: the scanner's one call, through \`file\`
    sys.path.insert(1, '$WORK/pyshim')
    sys.modules.pop('magic', None)
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
FDPY
  # fdroidserver's scanner needs python-magic for one thing, magic.from_file —
  # and the one Nix's fdroid carries does not even load. The file command is
  # the same libmagic, so it stands in when there is nothing better.
  mkdir -p "$WORK/pyshim"
  cat > "$WORK/pyshim/magic.py" <<'FDMAGIC'
"""magic.from_file through the file command, for fdroidserver's scanner —
written by fdroid-submit.sh where python-magic is missing or broken"""
import subprocess


def from_file(path, mime=False):
    cmd = ['file', '--brief'] + (['--mime-type'] if mime else []) + ['--', str(path)]
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
FDMAGIC
  cat > "$WORK/fdroid-latest" <<FDBIN
#!/bin/sh
exec '$WORK/fdroid-py' '$ck/fdroid' "\$@"
FDBIN
  chmod +x "$WORK/fdroid-py" "$WORK/fdroid-latest"
  cat > "$WORK/fd-test.py" <<'FDTEST'
import sys
import fdroidserver, fdroidserver.common, fdroidserver.metadata, fdroidserver.lint
import fdroidserver.rewritemeta, fdroidserver.checkupdates, yaml, ruamel.yaml
if not fdroidserver.__file__.startswith(sys.argv[1]):
    sys.exit('an installed fdroidserver came first: ' + fdroidserver.__file__)
try:
    import fdroidserver.scanner
    print('scanner')
except Exception:
    pass
FDTEST
  "$WORK/fdroid-py" "$WORK/fd-test.py" "$ck" > "$WORK/fd-test.out" 2>&1
}

find_fdroid() {  # sets RUNNER=latest when the newest fdroidserver runs here
  local d ck="" py dirs
  make_git_shim
  while IFS= read -r d; do
    if fd_is_checkout "$d"; then ck="$d"; break; fi
  done < <(fd_candidates)
  if [ -n "$ck" ]; then
    fd_update "$ck"
  fi
  while [ -z "$ck" ]; do
    printf '\n'
    say "The checks in stage 4 run on fdroidserver's newest code — the code fdroiddata's"
    say "pipeline runs — so they find what the pipeline would. It is not on this machine."
    say "  1) download it (about 30 MB), into a folder you choose"
    say "  2) use a copy you have already — give its folder"
    say "  3) skip the local checks — the merge request's pipeline runs them all"
    ask FD_SETUP "Which" "1"
    case "$FD_SETUP" in
      1) ask FDROIDSERVER "Download it into" "$FD_DEFAULT"
         d="${FDROIDSERVER/#\~/$HOME}"; case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
         if fd_is_checkout "$d"; then ck="$d"; fd_update "$ck"
         elif fd_download "$d"; then ck="$d"
         else warn "the download did not work"; fi ;;
      2) ask FDROIDSERVER "Folder of your fdroidserver copy" ""
         d="${FDROIDSERVER/#\~/$HOME}"; case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
         if fd_is_checkout "$d"; then ck="$d"; fd_update "$ck"
         else warn "$d does not hold fdroidserver (an fdroid script and an fdroidserver/ folder)"; fi ;;
      3) note "local checks skipped — the merge request's pipeline runs them"; return 1 ;;
      *) warn "1, 2 or 3" ;;
    esac
    if [ -z "$ck" ] && [ "$ASSUME_YES" = 1 ]; then return 1; fi
  done
  while IFS=$'\t' read -r py dirs; do
    [ -n "$py" ] || continue
    if fd_make "$ck" "$py" "$dirs"; then
      RUNNER=latest; FDROIDSERVER_DIR="$ck"; FDROID_PY="$WORK/fdroid-py"
      if grep -qx 'scanner' "$WORK/fd-test.out" && have file; then FD_SCANNER_OK=1; fi
      ok "fdroidserver $(git -C "$ck" log -1 --format='%h, %cs' 2>/dev/null || echo '(newest)'), at $ck"
      save_answers
      return 0
    fi
  done < <(fd_pythons)
  warn "the newest fdroidserver does not run on this machine — Python libraries it needs are missing:"
  tail -n 2 "$WORK/fd-test.out" | sed 's/^/       /'
  note "local checks skipped — the merge request's pipeline runs them all"
  return 1
}

detect_runner() {
  find_fdroid && return 0
  RUNNER=none
  return 0
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
    credential.helper=/bin/true) a='credential.helper=$t' ;;
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

# fd_in <command…> — run it inside $FDROIDDATA, with the git fixes above. The
# shim goes on PATH, but PATH alone is not enough: a packaged fdroid (nix,
# pipx) is a wrapper that prepends its own store paths, so the real git wins
# and the shim is never called. The same fixes go in as environment variables
# too, which no wrapper reorders. fdroidserver sets GIT_ASKPASS and GIT_SSH
# itself, but not GIT_SSH_COMMAND (which outranks GIT_SSH) and not
# GIT_CONFIG_GLOBAL, so these two still land.
fd_in() {
  local envs=()
  # gradlew-fdroid downloads gradle into its own folder, which a packaged copy
  # (Nix: /etc/profiles…) cannot write to; give it one that it can
  if [ -z "${GRADLE_VERSION_DIR:-}" ]; then
    envs+=("GRADLE_VERSION_DIR=${TOOLS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fdroid-submit}/gradle-versions")
  fi
  [ -n "$GIT_CFG_OFF" ] && envs+=("GIT_CONFIG_GLOBAL=/dev/null")
  [ -n "$GIT_REAL_FALSE" ] && envs+=("GIT_SSH_COMMAND=$GIT_REAL_FALSE")
  ( cd "$FDROIDDATA" && PATH="${GIT_SHIM:+$GIT_SHIM:}$PATH" \
    env "${envs[@]+"${envs[@]}"}" "$@" )
}
frun() {  # frun <fdroid args…> — the newest fdroid, inside $FDROIDDATA
  if [ "$RUNNER" != latest ]; then warn "skipped: fdroid $*"; return 0; fi
  fd_in "$WORK/fdroid-latest" "$@"
}
fpy() {  # fpy <script> [args…] — one of fdroiddata's tools/, with fdroidserver's libraries
  [ -n "$FDROID_PY" ] || return 1
  fd_in "$FDROID_PY" "$@"
}

# ------------------------------------------------------- GitLab, and the fork
# Definitions only, kept up here because `-p` below needs them before the main
# flow has run: where the fork lives, how to ask GitLab things, and how to see
# whether a branch already has a merge request.
GL_API="${GITLAB_API_ROOT:-https://gitlab.com/api/v4}"
FDROIDDATA_UPSTREAM="${FDROIDDATA_UPSTREAM:-https://gitlab.com/fdroid/fdroiddata.git}"
glab_ready() { have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; }

glab_fd() {
  # glab reads the current folder's git remotes even with -R; an app repo on
  # GitHub makes it give up, so run it in fdroiddata, or a folder with none
  if [ -d "${FDROIDDATA:-}/.git" ]; then
    ( cd "$FDROIDDATA" && glab "$@" )
  else
    ( cd "$WORK" && glab "$@" )
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

# ------------------------------------------------- following a submission
# Where an app's submission stands, live: f-droid.org says which versions are
# out, fdroiddata's master which are merged, GitLab how the merge request is
# doing — draft or ready, its labels, its pipeline and that pipeline's jobs,
# and what the reviewers wrote. Reading comments needs a login (glab, or
# $GITLAB_TOKEN); everything else is public.
cat > "$WORK/gl.py" <<'PYGL'
import datetime, json, shlex, sys


def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def ago(iso):
    if not iso:
        return ''
    try:
        t = datetime.datetime.fromisoformat(iso.replace('Z', '+00:00'))
    except ValueError:
        return iso
    s = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
    for n, unit in ((86400, 'day'), (3600, 'hour'), (60, 'minute')):
        if s >= n:
            k = int(s // n)
            return '%d %s%s ago' % (k, unit, '' if k == 1 else 's')
    return 'just now'


def cmd_mr(path):
    """shell assignments M_* for one merge request"""
    m = load(path)
    if not isinstance(m, dict) or 'iid' not in m:
        print('M_OK=0')
        return
    hp = m.get('head_pipeline') or {}
    v = {
        'M_OK': 1, 'M_IID': m.get('iid'), 'M_STATE': m.get('state'),
        'M_DRAFT': 1 if (m.get('draft') or m.get('work_in_progress')) else 0,
        'M_TITLE': m.get('title'), 'M_URL': m.get('web_url'),
        'M_LABELS': ','.join(m.get('labels') or []),
        'M_BRANCH': m.get('source_branch'), 'M_SRC_PID': m.get('source_project_id'),
        'M_SHA': m.get('sha'), 'M_MERGED': ago(m.get('merged_at')),
        'M_PIPE_ID': hp.get('id'), 'M_PIPE_STATUS': hp.get('status'),
        'M_PIPE_URL': hp.get('web_url'), 'M_PIPE_PID': hp.get('project_id'),
        'M_PIPE_SHA': hp.get('sha'), 'M_PIPE_WHEN': ago(hp.get('updated_at') or hp.get('created_at')),
    }
    for k, x in v.items():
        print('%s=%s' % (k, shlex.quote('' if x is None else str(x))))


def cmd_mrs(path, appid, me):
    """'<iid> <url>' of the open merge request from this app's branch"""
    d = load(path)
    for m in d if isinstance(d, list) else []:
        branch = m.get('source_branch') or ''
        who = (m.get('author') or {}).get('username')
        if (branch == appid or branch.startswith(appid + '-')) and (not me or who == me):
            print(m.get('iid'), m.get('web_url'))
            return


def cmd_jobs(path):
    """a tally, then '<status> TAB <name> TAB <url> TAB <id>' per job"""
    d = load(path)
    if not isinstance(d, list):
        return
    tally = {}
    for j in d:
        tally[j.get('status')] = tally.get(j.get('status'), 0) + 1
    print('TALLY\t' + ', '.join('%d %s' % (n, s) for s, n in sorted(tally.items())))
    for j in d:
        print('\t'.join(str(j.get(k) or '') for k in ('status', 'name', 'web_url', 'id')))


def cmd_notes(path, since, me):
    """what people other than you wrote after note <since>; on a first look only
    the newest two. TOP: the newest note id. REPLY 1: the last word is theirs
    (your own comments and pushes count as yours)."""
    d = load(path)
    if not isinstance(d, list):
        print('ERR')
        return
    since = int(since or 0)
    top, mine, theirs, new = since, '', '', []
    for n in d:
        nid = int(n.get('id') or 0)
        who = (n.get('author') or {}).get('username') or '?'
        when = n.get('created_at') or ''
        top = max(top, nid)
        if who == me:
            mine = max(mine, when)
        elif not n.get('system'):
            theirs = max(theirs, when)
            if nid > since:
                body = ' '.join((n.get('body') or '').split())
                new.append('NOTE\t%d\t%s\t%s\t%s' % (nid, who, ago(when), body[:160]))
    print('TOP\t%d' % top)
    print('REPLY\t%d' % (1 if theirs and theirs > mine else 0))
    if not since and len(new) > 2:
        print('OLDER\t%d' % (len(new) - 2))
        new = new[-2:]
    print('\n'.join(new))


def cmd_pkg(path):
    """the versions f-droid.org publishes, newest first: name TAB code"""
    d = load(path)
    if isinstance(d, dict):
        for x in d.get('packages') or []:
            print('%s\t%s' % (x.get('versionName'), x.get('versionCode')))


def cmd_ago(iso):
    print(ago(iso))


cmds = {'mr': cmd_mr, 'mrs': cmd_mrs, 'jobs': cmd_jobs, 'notes': cmd_notes,
        'pkg': cmd_pkg, 'ago': cmd_ago}
cmds[sys.argv[1]](*sys.argv[2:])
PYGL
glpy() { python3 "$WORK/gl.py" "$@"; }

GLAB_OK=""
glab_ok() {  # glab_ready, asked once a run: it is a network call
  [ -n "$GLAB_OK" ] || { if glab_ready; then GLAB_OK=1; else GLAB_OK=0; fi; }
  [ "$GLAB_OK" = 1 ]
}
gl_get() {  # gl_get <api path> — logged in when possible, anonymously otherwise
  local out=""
  if glab_ok; then out="$(cd "$WORK" && glab api "$1" 2>/dev/null || true)"
  elif [ -n "${GITLAB_TOKEN:-}" ]; then
    out="$(curl -s --max-time 20 -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GL_API/$1" || true)"
  fi
  [ -n "$out" ] || out="$(curl -s --max-time 20 "$GL_API/$1" || true)"
  # nothing at all: GitLab is out of reach (a file, so pipes and $(…) see it too)
  [ -n "$out" ] || : > "$WORK/gl.unreachable"
  printf '%s' "$out"
}
vnames() {  # stdin: a metadata file — its build entries' versionNames
  sed -nE "s/^[[:space:]]*-?[[:space:]]*versionName:[[:space:]]*['\"]?([^'\"]+)['\"]?[[:space:]]*\$/\\1/p"
}
# fdroid_versions <appid> — FD_PUB: what F-Droid has out, newest first (name TAB
# code); FD_OK=0 when f-droid.org gave no answer, so nothing is concluded from it
FD_PUB=""; FD_OK=1
fdroid_versions() {
  local code
  FD_PUB=""
  code="$(curl -s --max-time 20 -o "$WORK/pkg.json" -w '%{http_code}' "https://f-droid.org/api/v1/packages/$1" 2>/dev/null || true)"
  case "$code" in
    200) FD_OK=1; FD_PUB="$(glpy pkg "$WORK/pkg.json")" ;;
    404) FD_OK=1 ;;
    *)   FD_OK=0 ;;
  esac
}
# fdroiddata_versions <appid> — FD_MASTER: the versions merged into fdroiddata's
# master; FDD_OK=0 when GitLab gave no answer
FD_MASTER=""; FDD_OK=1
fdroiddata_versions() {
  local code
  FD_MASTER=""
  code="$(curl -s --max-time 20 -o "$WORK/master.yml" -w '%{http_code}' \
            "https://gitlab.com/fdroid/fdroiddata/-/raw/master/metadata/$1.yml" 2>/dev/null || true)"
  case "$code" in
    200) FDD_OK=1; FD_MASTER="$(vnames < "$WORK/master.yml")" ;;
    404) FDD_OK=1 ;;
    *)   FDD_OK=0 ;;
  esac
}
mr_load() {  # mr_load <iid> — M_* for that merge request on fdroid/fdroiddata
  gl_get "projects/fdroid%2Ffdroiddata/merge_requests/$1" > "$WORK/mr.json"
  eval "$(glpy mr "$WORK/mr.json")"
}
mr_versions() {  # mr_versions <appid> — the versionNames on the loaded merge request's branch
  gl_get "projects/$M_SRC_PID/repository/files/metadata%2F$1.yml/raw?ref=$(urlencode "$M_BRANCH")" | vnames
}
find_open_mr() {  # find_open_mr <appid> — '<iid> <url>' of your open merge request for it
  local me="${GLUSER:-${SAVED_GLUSER:-}}"
  if [ -n "$me" ]; then
    gl_get "projects/fdroid%2Ffdroiddata/merge_requests?state=opened&author_username=$me&per_page=100" > "$WORK/mrs.json"
  else
    gl_get "projects/fdroid%2Ffdroiddata/merge_requests?state=opened&source_branch=$1" > "$WORK/mrs.json"
  fi
  glpy mrs "$WORK/mrs.json" "$1" "$me"
}
pipe_words() {  # pipe_words <GitLab pipeline status> — in a word
  case "$1" in
    success) printf 'passed' ;;
    failed) printf 'failed' ;;
    running|pending|created|preparing|waiting_for_resource|scheduled) printf 'running' ;;
    canceled|canceling) printf 'canceled' ;;
    skipped|manual) printf '%s' "$1" ;;
    '') printf 'none yet' ;;
    *) printf '%s' "$1" ;;
  esac
}
pipe_failed_jobs() {  # the loaded merge request's failed jobs, with links
  [ -n "$M_PIPE_PID" ] && [ -n "$M_PIPE_ID" ] || return 0
  gl_get "projects/$M_PIPE_PID/pipelines/$M_PIPE_ID/jobs?per_page=100" > "$WORK/jobs.json"
  glpy jobs "$WORK/jobs.json" | awk -F'\t' '$1 == "failed" { printf "       ✗ %s  %s\n", $2, $3 }'
}
open_url() {  # open_url <url> — in the default browser; false when there is none
  case "$(uname -s)" in Darwin) open "$1" >/dev/null 2>&1 & return 0 ;; esac
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && have xdg-open || return 1
  xdg-open "$1" >/dev/null 2>&1 &
}
status_words() {  # status_words <status> [pipeline] [reply] — for the task list and the timeline
  local s="$1" p="${2-}" r="${3-0}" w
  case "$s" in
    started)   w="started" ;;
    pushed)    w="pushed, no merge request yet" ;;
    submitted) w="merge request open" ;;
    draft)     w="draft" ;;
    review)    w="in review" ;;
    merged)    w="merged, waiting for F-Droid's build" ;;
    published) w="published" ;;
    closed)    w="merge request closed" ;;
    *)         w="$s" ;;
  esac
  case "$s" in
    draft|review|submitted)
      [ -n "$p" ] && w="$w · pipeline $p"
      [ "$r" = 1 ] && w="$w · reviewer replied" ;;
  esac
  printf '%s' "$w"
}

# app_status — this app's submission right now: printed, remembered, and what
# changed since last time added to its timeline.
app_status() {
  local appid vname vcode url iid me since kind a b c d st pipe="" reply=0 pub line top=""
  appid="$(recall ST_APPID)"; [ -n "$appid" ] || appid="$(recall APPID)"
  vname="$(recall ST_VNAME)"; [ -n "$vname" ] || vname="$(recall VNAME)"
  vcode="$(recall ST_VCODE)"; [ -n "$vcode" ] || vcode="$(recall VCODE)"
  me="$(recall GLUSER)"; me="${me:-${SAVED_GLUSER:-}}"
  step "$appid — ${vname:-?}${vcode:+ ($vcode)}"
  [ -n "$(recall REPO)" ] && note "repo: $(recall REPO)"
  st="$(recall ST_STATUS)"; st="${st:-started}"

  fdroid_versions "$appid"; pub="$FD_PUB"
  if [ "$FD_OK" = 0 ]; then
    warn "could not reach f-droid.org — whether it is out was not checked"
  elif [ -n "$vname" ] && printf '%s\n' "$pub" | cut -f1 | grep -qxF -- "$vname"; then
    ok "$vname is out in F-Droid"; st=published
  elif [ -n "$pub" ]; then
    note "F-Droid has $(printf '%s\n' "$pub" | head -1 | cut -f1); ${vname:-this version} is not out yet"
  else
    note "not in F-Droid yet"
  fi

  url="$(recall ST_MR)"
  if [ -z "$url" ]; then
    line="$(find_open_mr "$appid" || true)"
    if [ -n "$line" ]; then url="${line#* }"; remember ST_MR "$url"; tlog "found merge request $url"; fi
  fi
  iid="${url##*/}"
  if [ -n "$url" ]; then
    mr_load "$iid"
    if [ "${M_OK:-0}" != 1 ]; then
      # nothing new is known: keep what was, rather than log a change that wasn't
      warn "could not reach GitLab for merge request !$iid — as it stood last time:"
      pipe="$(recall ST_PIPE)"; reply="$(recall ST_REPLY)"; reply="${reply:-0}"
      note "$(status_words "$st" "$pipe" "$reply") — $url"
    else
      case "$M_STATE" in
        merged) ok "merge request !$iid was merged $M_MERGED"; [ "$st" = published ] || st=merged ;;
        closed) warn "merge request !$iid was closed without merging"; st=closed ;;
        *) if [ "$M_DRAFT" = 1 ]; then say "merge request !$iid is a draft — reviewers wait until it is ready"; st=draft
           else ok "merge request !$iid is ready for review"; st=review; fi ;;
      esac
      note "$M_URL"
      [ -n "$M_LABELS" ] && note "labels: ${M_LABELS//,/, }"
      if [ "$M_STATE" = opened ]; then
        pipe="$(pipe_words "$M_PIPE_STATUS")"
        case "$pipe" in
          passed)  ok "pipeline #$M_PIPE_ID passed $M_PIPE_WHEN" ;;
          failed)  warn "pipeline #$M_PIPE_ID failed $M_PIPE_WHEN"; pipe_failed_jobs ;;
          running) say "pipeline #$M_PIPE_ID is running"; runners_check ;;
          *)       note "pipeline: $pipe" ;;
        esac
        [ -n "$M_PIPE_URL" ] && note "$M_PIPE_URL"
      fi
      # what reviewers wrote since you last looked
      since="$(recall ST_SEEN_NOTE)"
      gl_get "projects/fdroid%2Ffdroiddata/merge_requests/$iid/notes?sort=asc&per_page=100" > "$WORK/notes.json"
      while IFS=$'\t' read -r kind a b c d; do
        case "$kind" in
          ERR)   note "log in with glab to see the reviewers' comments (glab auth login)" ;;
          TOP)   top="$a" ;;
          REPLY) reply="$a" ;;
          OLDER) note "$a earlier comments — all of them are on the merge request" ;;
          NOTE)  say "${B}$b${R}, $c: $d"
                 note "  $M_URL#note_$a"
                 [ -n "$since" ] && tlog "comment by $b: $(printf '%s' "$d" | cut -c1-90) — $M_URL#note_$a" ;;
        esac
      done < <(glpy notes "$WORK/notes.json" "${since:-0}" "$me")
      [ -n "$top" ] && [ "$top" != 0 ] && remember ST_SEEN_NOTE "$top"
      [ "$reply" = 1 ] && [ "$M_STATE" = opened ] && warn "the last word is a reviewer's — they are waiting for you"
    fi
  elif [ -n "$(recall ST_BRANCH)" ]; then
    note "branch $(recall ST_BRANCH) is on your fork, with no merge request yet (-p opens one)"
  fi

  if [ "$st" != "$(recall ST_STATUS)" ] || [ "$pipe" != "$(recall ST_PIPE)" ]; then
    tlog "$(status_words "$st" "$pipe")${url:+ — !$iid}"
  fi
  remember ST_STATUS "$st"; remember ST_PIPE "$pipe"; remember ST_REPLY "$reply"
  if [ -s "${TASK_FILE%.conf}.log" ]; then
    say "${B}Timeline${R}"
    tail -n 8 "${TASK_FILE%.conf}.log" | sed 's/^/     /'
  fi
}

mr_mark() {  # mr_mark ready|draft — flip the merge request between draft and ready
  local url iid
  url="$(recall ST_MR)"; iid="${url##*/}"
  [ -n "$iid" ] || return 0
  if ! glab_ok; then
    warn "glab is not logged in — mark it $1 on GitLab: $url"
    return 0
  fi
  FDROIDDATA="${FDROIDDATA:-$(recall FDROIDDATA)}"
  if glab_fd mr update "$iid" -R fdroid/fdroiddata "--$1" >/dev/null 2>&1; then
    if [ "$1" = ready ]; then
      ok "merge request !$iid is ready for review"; tlog "marked ready for review"; remember ST_STATUS review
    else
      ok "merge request !$iid is a draft again"; tlog "marked as a draft"; remember ST_STATUS draft
    fi
  else
    warn "glab could not mark it $1 — do it on GitLab: $url"
  fi
}

# runners_check — a pipeline that never starts. Merge request pipelines run in
# your fork, on GitLab's shared ("instance") runners; with those switched off
# for the fork, every job waits for a runner forever. Says so, and offers to
# switch them back on. Reading the setting needs a login (glab).
RUNNERS_SAID=""
runners_check() {
  local on json path
  [ -n "${M_PIPE_PID:-}" ] && [ -z "$RUNNERS_SAID" ] && glab_ok || return 0
  json="$(gl_get "projects/$M_PIPE_PID")"
  on="$(printf '%s' "$json" | json_bool shared_runners_enabled)"
  path="$(printf '%s' "$json" | json_str path_with_namespace)"
  [ "$on" = false ] || return 0
  RUNNERS_SAID=1
  warn "your fork has GitLab's shared runners switched off — no job of this pipeline can start"
  note "merge request pipelines run in your fork, on GitLab's instance runners"
  note "the setting: https://gitlab.com/${path:-<you>/fdroiddata}/-/settings/ci_cd (Runners → Instance runners)"
  if go "Switch the instance runners on for your fork?"; then
    if glab_fd api --method PUT "projects/$M_PIPE_PID" -f shared_runners_enabled=true >/dev/null 2>&1; then
      ok "instance runners on — the waiting jobs start as soon as a runner takes them"
      tlog "switched the fork's instance runners on"
    else
      warn "GitLab refused — switch them on in the settings page above"
      note "a new GitLab account may first have to verify itself (phone or card) to use them"
    fi
  fi
}
json_bool() {  # json_bool <key> — true/false of the first "key": true|false in the JSON on stdin
  grep -Eo "\"$1\"[[:space:]]*:[[:space:]]*(true|false)" | sed -n 1p | sed -E 's/.*:[[:space:]]*//'
}

# watch_pipeline [sha] — follow the merge request's pipeline (the one for that
# commit, when given) until it ends. Enter stops watching; the pipeline runs on.
watch_pipeline() {
  local url iid want="${1-}" st last="" tally rc t0=$SECONDS
  url="$(recall ST_MR)"; iid="${url##*/}"
  [ -n "$iid" ] || return 0
  say "watching the pipeline — minutes to an hour; Enter stops watching (it runs on)"
  while :; do
    mr_load "$iid"
    st="$(pipe_words "$M_PIPE_STATUS")"
    [ -n "$want" ] && [ "${M_PIPE_SHA:-}" != "$want" ] && st="waiting for GitLab to start it"
    tally=""
    if [ -n "$M_PIPE_ID" ] && [ -n "$M_PIPE_PID" ] && [ "$st" = running ]; then
      gl_get "projects/$M_PIPE_PID/pipelines/$M_PIPE_ID/jobs?per_page=100" > "$WORK/jobs.json"
      tally="$(glpy jobs "$WORK/jobs.json" | sed -n 's/^TALLY\t//p')"
    fi
    if [ "$st $tally" != "$last" ]; then
      printf '   %s  pipeline%s: %s%s\n' "$(date +%H:%M)" "${M_PIPE_ID:+ #$M_PIPE_ID}" "$st" "${tally:+ — $tally}"
      last="$st $tally"
    fi
    case "$st" in passed|failed|canceled|skipped) break ;; esac
    [ "$st" = running ] && [ $((SECONDS - t0)) -gt 120 ] && runners_check
    if [ $((SECONDS - t0)) -gt 7200 ]; then
      note "still running after two hours — stopped watching; --status shows it later"; return 1
    fi
    if read -r -t 30 _; then
      note "stopped watching — the pipeline runs on; --status shows it later"; return 1
    else
      rc=$?; [ "$rc" -gt 128 ] || sleep 30     # no terminal to read from: just wait
    fi
  done
  remember ST_PIPE "$st"
  case "$st" in
    passed)
      ok "the pipeline passed"; tlog "pipeline #$M_PIPE_ID passed — $M_PIPE_URL"
      if [ "$M_DRAFT" = 1 ] && confirm "Mark the merge request ready for review now?" y; then mr_mark ready; fi ;;
    failed)
      warn "the pipeline failed"; tlog "pipeline #$M_PIPE_ID failed — $M_PIPE_URL"
      pipe_failed_jobs ;;
    *) note "the pipeline ended: $st" ;;
  esac
  return 0
}

failed_log() {  # the end of the first failed job's log
  local id name url
  [ -n "${M_PIPE_PID:-}" ] && [ -n "${M_PIPE_ID:-}" ] || { note "no pipeline to look at"; return 0; }
  gl_get "projects/$M_PIPE_PID/pipelines/$M_PIPE_ID/jobs?per_page=100" > "$WORK/jobs.json"
  IFS=$'\t' read -r _ name url id < <(glpy jobs "$WORK/jobs.json" | awk -F'\t' '$1 == "failed"' | head -1) || true
  [ -n "${id:-}" ] || { note "no job failed in pipeline #$M_PIPE_ID"; return 0; }
  say "the end of $name — $url"
  # without colours, and without the time and stream GitLab puts before each line
  gl_get "projects/$M_PIPE_PID/jobs/$id/trace" | sed -E 's/\x1b\[[0-9;]*[mK]//g' \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z [0-9A-Fa-f]{2}[OE]\+? ?//' | tail -n 40 | sed 's/^/     /'
}

repo_version() {  # repo_version <repo> — "name+code" as the repo says today
  local r="$1" p g n c
  for p in "$r/pubspec.yaml" "$r"/*/pubspec.yaml "$r"/*/*/pubspec.yaml; do
    [ -f "$p" ] && grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
    sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" "$p" | sed -n 1p
    return 0
  done
  for g in "$r/$(recall SUBDIR)/build.gradle.kts" "$r/$(recall SUBDIR)/build.gradle"; do
    [ -f "$g" ] || continue
    n="$(sed -nE "s/.*versionName[[:space:]]*=?[[:space:]]*[\"']([^\"']+)[\"'].*/\\1/p" "$g" | sed -n 1p)"
    c="$(sed -nE 's/.*versionCode[[:space:]]*=?[[:space:]]*([0-9]+).*/\1/p' "$g" | sed -n 1p)"
    [ -n "$n" ] && printf '%s+%s' "$n" "$c"
    return 0
  done
}

# status_menu — what this app's submission can do next. Returns to let the
# wizard run (edit the recipe, send a version); q leaves.
WANT_BUMP=0
status_menu() {
  local ch def rv rn
  while :; do
    rv="$(repo_version "$(recall REPO)" 2>/dev/null || true)"; rn="${rv%%+*}"
    printf '\n'; say "${B}What next?${R}"
    def=c
    if [ "$(recall ST_PIPE)" = running ]; then say "  w) watch the pipeline until it ends"; def=w; fi
    if [ "$(recall ST_STATUS)" = draft ] && [ "$(recall ST_PIPE)" = passed ]; then
      say "  r) mark the merge request ready for review"; def=r
    fi
    [ "$(recall ST_STATUS)" = review ] && say "  d) mark it as a draft again"
    [ "$(recall ST_PIPE)" = failed ] && say "  l) the end of the failed job's log"
    [ -n "$(recall ST_MR)" ] && say "  o) open the merge request in the browser"
    if [ -n "$rn" ] && [ "$rn" != "$(recall ST_VNAME)" ] \
       && [ "$(printf '%s\n%s\n' "$rn" "$(recall ST_VNAME)" | sort -V | tail -1)" = "$rn" ]; then
      say "  u) send $rn — your repo has a newer version"; def=u
    fi
    case "$(recall ST_STATUS)" in
      published|merged) say "  n) release a new version: bump it in your repo"; [ "$def" = c ] && def=n ;;
    esac
    say "  c) continue: edit the recipe and push it again"
    say "  q) quit"
    printf '   %sChoice%s [%s]: ' "$B" "$R" "$def" >&2
    readline ch; ch="${ch:-$def}"
    case "$ch" in
      w|W) watch_pipeline || true; app_status ;;
      r|R) mr_mark ready; app_status ;;
      d|D) mr_mark draft; app_status ;;
      l|L) failed_log ;;
      o|O) open_url "$(recall ST_MR)" || say "$(recall ST_MR)" ;;
      u|U|c|C) return 0 ;;
      n|N) WANT_BUMP=1; return 0 ;;
      q|Q) exit 0 ;;
      *) warn "one of the letters above" ;;
    esac
  done
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
                -d "$(cat "$body")" --allow-collaboration --draft -y 2>&1 || true)"
    MR_URL="$(printf '%s\n' "$MR_OUT" | grep -Eo 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1 || true)"
    if [ -n "$MR_URL" ]; then
      ok "merge request, as a draft until its pipeline passes: $MR_URL"
      remember ST_MR "$MR_URL"; remember ST_STATUS draft
      tlog "merge request !${MR_URL##*/} opened as a draft"
      note "follow it, and mark it ready once the pipeline passes: fdroid-submit.sh --status $APPID"
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
  migrate_per_app
  step "Apps with a branch on your fork"
  note "no merge request yet: one is opened — one open: its description is renewed"
  if ! pick_task with-branch; then
    say "nothing opened: no task with a pushed branch was picked."
    note "tasks live in $TASK_DIR"
    exit 0
  fi
  open_mr_for_task
  exit 0
fi

# --status: each app's submission as it stands, nothing else
if [ "$STATUS_ONLY" = 1 ]; then
  migrate_tasks
  migrate_per_app
  N_APPS=0
  for f in $(ls -t "$TASK_DIR/$STORE_ID"-*.conf 2>/dev/null || true); do
    id="$(basename "$f" .conf)"; id="${id#"$STORE_ID"-}"
    [ -z "$STATUS_APP" ] || [ "$id" = "$STATUS_APP" ] || continue
    MEM=(); TASK_FILE="$f"; read_task "$f"
    app_status
    N_APPS=$((N_APPS + 1))
  done
  [ "$N_APPS" -gt 0 ] || say "no task${STATUS_APP:+ for $STATUS_APP} yet — a first run of the wizard makes one"
  exit 0
fi

# =============================================================== 0. orientation
cat <<BANNER

  ${B}F-Droid submission wizard${R}

  Five stages:
    1. your app repo      — what F-Droid needs to know, plus the usual pitfalls
    2. fdroiddata fork    — clone it, branch off current upstream master
    3. metadata           — write (or extend) metadata/<appid>.yml
    4. checks             — what fdroiddata's pipeline checks, run here first
    5. push               — branch pushed, merge request opened

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything except the final push"

[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
# New app or version update is decided later, from upstream fdroiddata itself.
IS_UPDATE=0

migrate_tasks
migrate_per_app
# Pick up an app's task, if there is one: where its submission stands is shown
# first — the merge request, the pipeline, the reviewers, F-Droid — then what
# can happen next; its answers become this run's defaults.
if [ "$PR_ONLY" = 0 ] && [ "$ASSUME_YES" = 0 ] && [ -d "$TASK_DIR" ]; then
  if pick_task; then
    app_status
    status_menu
  fi
fi

detect_runner

# ============================================================== 1. the app repo
step "1/5  Your app repository"

# The app repo: --repo; the task's own, when continuing one; otherwise asked —
# a new task is a new app, so last time's repo is no answer for it — with the
# git repo you run this in (unless it is this script's own) as the default.
SELF_REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ "$HERE_REPO" = "$SELF_REPO" ] && HERE_REPO=""
REPO_GUESS="$HERE_REPO"
[ "$ASSUME_YES" = 1 ] && REPO_GUESS="${REPO_GUESS:-${SAVED_REPO:-}}"
while :; do
  if [ -n "$REPO_ARG" ]; then REPO="$REPO_ARG"
  elif [ -n "$TASK_FILE" ] && [ -n "$(recall REPO)" ]; then auto REPO "App repository" "$(recall REPO)"
  else
    [ -z "$REPO_GUESS" ] && note "the app's git checkout, e.g. ~/Projects/MyApp — run this inside it to skip the question"
    ask REPO "App repository" "$REPO_GUESS"
  fi
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

# The app's task: one for every version it ever sends, so it can only be named
# now that the application id is known.
state_load
remember ST_RUN "$(date '+%Y-%m-%d %H:%M')"

# --- where this version stands: out in F-Droid already, merged into
# fdroiddata, waiting in your merge request — or new. A version F-Droid has
# cannot go out again; a newer one is an update; one in your merge request is
# followed there.
STOOD=new; BUMP_OFFER=1
stands_check() {
  local pub master iid="" line mrv="" latest ch
  say "where $VNAME stands…"
  rm -f "$WORK/gl.unreachable"
  fdroid_versions "$APPID"; pub="$FD_PUB"
  fdroiddata_versions "$APPID"; master="$FD_MASTER"
  if [ -n "$(recall ST_MR)" ]; then
    iid="$(recall ST_MR)"; iid="${iid##*/}"; mr_load "$iid"
    [ "${M_OK:-0}" = 1 ] && [ "$M_STATE" = opened ] || iid=""
  fi
  if [ -z "$iid" ]; then
    line="$(find_open_mr "$APPID" || true)"
    if [ -n "$line" ]; then iid="${line%% *}"; mr_load "$iid"; remember ST_MR "${line#* }"; fi
  fi
  [ -n "$iid" ] && [ "${M_OK:-0}" = 1 ] && mrv="$(mr_versions "$APPID" || true)"
  latest="$(printf '%s\n' "$pub" | head -1 | cut -f1)"
  # what could not be looked at is said, not guessed
  [ "$FD_OK" = 0 ] && warn "could not reach f-droid.org — whether $VNAME is already out was not checked"
  { [ "$FDD_OK" = 0 ] || [ -f "$WORK/gl.unreachable" ]; } && \
    warn "could not reach GitLab — fdroiddata and your merge requests were not checked"
  if printf '%s\n' "$pub" | cut -f1 | grep -qxF -- "$VNAME"; then
    warn "$APPID $VNAME is already out in F-Droid — it cannot be sent again"
    STOOD=published
  elif printf '%s\n' "$master" | grep -qxF -- "$VNAME"; then
    warn "$VNAME is merged into fdroiddata already — F-Droid's build server publishes it within a day or two"
    STOOD=merged
  elif [ -n "$mrv" ] && printf '%s\n' "$mrv" | grep -qxF -- "$VNAME"; then
    ok "$VNAME is in your merge request !$iid already — $M_URL"
    STOOD=in-mr
  elif [ -n "$pub$master" ]; then
    ok "F-Droid has ${latest:-$(printf '%s\n' "$master" | tail -1)}; $VNAME is new — an update"
    STOOD=update
  else
    if [ -n "$iid" ]; then ok "your merge request !$iid is open, for $(printf '%s' "$mrv" | tr '\n' ' ')— $VNAME goes into it"
    elif [ "$FD_OK" = 0 ] || [ "$FDD_OK" = 0 ] || [ -f "$WORK/gl.unreachable" ]; then
      note "taking $APPID as a new app — that could not be checked"
    else ok "$APPID is not in F-Droid yet — a new app"; fi
    STOOD=new
  fi
  case "$STOOD" in
    published|merged)
      [ "$ASSUME_YES" = 1 ] && die "$VNAME is already $STOOD — bump the version in your repo first"
      say "  n) release a new version: bump it in your repo"
      say "  s) stop here"
      ask STAND_CH "Which" "n"
      case "$STAND_CH" in n|N*) WANT_BUMP=1 ;; *) exit 0 ;; esac ;;
    in-mr)
      [ "$ASSUME_YES" = 1 ] && return 0
      say "  c) continue: update the recipe in that merge request"
      say "  n) release a newer version: bump it in your repo"
      say "  s) stop here — --status follows the merge request"
      ask STAND_CH "Which" "c"
      # carrying on with what the merge request holds: commits made after the
      # tag (a description fix, say) are no call for a new version
      case "$STAND_CH" in n|N*) WANT_BUMP=1 ;; s|S*) exit 0 ;; *) BUMP_OFFER=0 ;; esac ;;
    update)
      confirm "Send $VNAME to F-Droid as an update?" y || exit 0 ;;
  esac
}
[ "$WANT_BUMP" = 1 ] || stands_check

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

BUMP=0
if [ "$WANT_BUMP" = 1 ]; then
  [ -n "$VER_FILE" ] || die "the version is not in a pubspec.yaml or gradle file this wizard can edit — bump it by hand, commit, and run again"
  if [ "$DRYRUN" = 1 ]; then warn "dry run — not bumping the version"; else BUMP=1; fi
elif [ "$BUMP_OFFER" = 1 ] && [ "$CUR_TAGGED" = 1 ] && [ "$AHEAD" -gt 0 ] && [ -n "$VER_FILE" ] && [ "$DRYRUN" = 0 ]; then
  warn "$AHEAD commit(s) since $LASTTAG, but ${VER_FILE#"$REPO"/} still says $VNAME+$VCODE"
  note "that version is already tagged, so those commits cannot be released as it"
  confirm "Bump the version and make the release commit?" n && BUMP=1
fi
if [ "$BUMP" = 1 ]; then
  if :; then
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

# --- this run's version, in the app's one task. A new version starts its own
# build entry: the previous one's line answers are no defaults for it. A
# finished submission — merged, published, closed — becomes history, and this
# version gets a merge request of its own; an open one carries it instead.
LAST_VCODE="$(recall ST_VCODE)"
if [ -n "$LAST_VCODE" ] && [ "$LAST_VCODE" != "$VCODE" ]; then
  tlog "version $(recall ST_VNAME) ($LAST_VCODE) → $VNAME ($VCODE)"
  for k in "${!MEM[@]}"; do
    case "$k" in Y_b_*|Y_top_CurrentVersion|Y_top_CurrentVersionCode|Y_BASE|ST_TAG|ST_RELEASE) unset "MEM[$k]" ;; esac
  done
  case "$(recall ST_STATUS)" in
    merged|published|closed)
      tlog "a new submission: $VNAME"
      for k in ST_MR ST_BRANCH ST_STATUS ST_PIPE ST_REPLY ST_SEEN_NOTE ST_COMMITMSG; do unset "MEM[$k]"; done ;;
  esac
  state_save
fi
remember ST_VNAME "$VNAME"; remember ST_VCODE "$VCODE"
[ -n "$(recall ST_STATUS)" ] || remember ST_STATUS started
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

# --- URLs from the git remote
WEB_GUESS=""
case "$ORIGIN" in
  git@*)     WEB_GUESS="https://$(echo "$ORIGIN" | sed 's/^git@//; s/:/\//; s/\.git$//')" ;;
  ssh://*)   WEB_GUESS="https://$(echo "$ORIGIN" | sed 's,^ssh://\(git@\)\?,,; s,:[0-9]*/,/,; s/\.git$//')" ;;
  https://*) WEB_GUESS="${ORIGIN%.git}" ;;
esac
[ -n "$WEB_GUESS" ] || warn "no usable 'origin' remote — you will have to type the URLs"

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

# ----------------------------------------------------- 1b. common MR blockers
# Every check this run makes — the pitfalls below, then in stage 4 the ones
# fdroiddata's pipeline runs — and how it went, for the summary before the push.
#   passed[: note]   warn: what to look at   failed: why   skipped: why
declare -A CHK=()
CHK_NAMES=()
chk() {  # chk <check> <outcome>
  [ -v "CHK[$1]" ] || CHK_NAMES+=("$1")
  CHK["$1"]="$2"
}
chk_with() {  # chk_with <outcome prefix> — the checks whose outcome starts so, comma separated
  local k out=""
  for k in ${CHK_NAMES[@]+"${CHK_NAMES[@]}"}; do
    case "${CHK[$k]}" in "$1"*) out="${out:+$out, }$k" ;; esac
  done
  printf '%s' "$out"
}
chk_summary() {
  local k v
  for k in ${CHK_NAMES[@]+"${CHK_NAMES[@]}"}; do
    v="${CHK[$k]}"
    case "$v" in
      passed)   ok "$k" ;;
      passed:*) ok "$k — ${v#passed: }" ;;
      warn:*)   warn "$k — ${v#warn: }" ;;
      failed:*) printf '   %s✗ %s — %s%s\n' "$RED" "$k" "${v#failed: }" "$R" ;;
      *)        note "– $k — ${v#skipped: }" ;;
    esac
  done
}

step "Pitfall check"
BLOCKERS=0

# F-Droid builds only from source anyone can clone — and reviewers read it.
# Asked of the forge's API anonymously: a private repo answers 404 there.
public_check() {
  local path api="" code
  case "$WEB_GUESS" in
    https://github.com/*)   path="${WEB_GUESS#https://github.com/}"; api="https://api.github.com/repos/$path" ;;
    https://gitlab.com/*)   path="${WEB_GUESS#https://gitlab.com/}"
                            api="https://gitlab.com/api/v4/projects/$(printf '%s' "$path" | sed 's#/#%2F#g')" ;;
    https://codeberg.org/*) path="${WEB_GUESS#https://codeberg.org/}"; api="https://codeberg.org/api/v1/repos/$path" ;;
    *) return 0 ;;
  esac
  have curl || return 0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$api" 2>/dev/null || true)"
  case "$code" in
    200) ok "the source is public: $WEB_GUESS" ;;
    404) warn "$WEB_GUESS is not public — F-Droid builds only from source anyone can clone"
         note "make the repository public before submitting; its tags and releases come with it"
         BLOCKERS=$((BLOCKERS+1)) ;;
    *)   note "could not check whether $WEB_GUESS is public (HTTP ${code:-none})" ;;
  esac
}
public_check
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

# fdroiddata's build job fails an app whose gradle files fetch from a plain
# http:// repository (its tools/audit-gradle.py): anyone on the way could hand
# the build a different library.
mapfile -t GRADLE_FILES < <(git -C "$REPO" ls-files -- '*.gradle' '*.gradle.kts' 2>/dev/null || true)
HTTP_REPOS="$(python3 - "$REPO" ${GRADLE_FILES[@]+"${GRADLE_FILES[@]}"} <<'PYHTTP' 2>/dev/null || true
import re, sys
root = sys.argv[1]
pat = re.compile(r'repositories\s*\{[^}]*?(http://[^\s"\')]+)', re.S)
for f in sys.argv[2:]:
    try:
        data = open(root + '/' + f, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    for m in pat.finditer(data):
        print('%s: %s' % (f, m.group(1)))
PYHTTP
)"
if [ -n "$HTTP_REPOS" ]; then
  warn "gradle fetches libraries over plain http:// — fdroiddata's build job fails on it:"
  printf '%s\n' "$HTTP_REPOS" | head -5 | sed 's/^/       /'
  note "switch them to https://, then commit and tag again"
  BLOCKERS=$((BLOCKERS+1))
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

# What fdroiddata's "check source code" job reports to the reviewers about the
# listing, read from the tag F-Droid builds: en-US needs a summary and a
# description, every text has a length limit, and locale folders need names
# F-Droid knows.
fastlane_report() {  # fastlane_report <ref> <…/fastlane/metadata/android> — "level TAB message" lines
  python3 - "$REPO" "$1" "$2" "$VCODE" "$((10 * VCODE + 1))" "$((10 * VCODE + 2))" "$((10 * VCODE + 3))" <<'PYFL'
import re, subprocess, sys
repo, ref, base = sys.argv[1:4]
codes = sys.argv[4:]
LIMITS = {'title.txt': 50, 'short_description.txt': 80, 'full_description.txt': 4000, 'video.txt': 256}
LOCALE = re.compile(r'[a-z]{2,3}(-([A-Z][a-zA-Z]+|\d+|[a-z]+))*')
MARKDOWN = re.compile(r'(^#{1,6}\s|\*\*[^*\n]+\*\*|__[^_\n]+__|\[[^\]\n]+\]\([^)\n]+\)|`[^`\n]+`)', re.M)


def git(*a):
    return subprocess.run(['git', '-C', repo] + list(a), capture_output=True).stdout.decode('utf-8', 'replace')


def text(loc, f):
    return git('show', '%s:%s/%s/%s' % (ref, base, loc, f)).strip()


locales = {}
for n in git('ls-tree', '-r', '--name-only', ref, '--', base + '/').split('\n'):
    parts = n[len(base) + 1:].split('/') if n else []
    if len(parts) >= 2:
        locales.setdefault(parts[0], []).append('/'.join(parts[1:]))
en = locales.get('en-US', [])
for f, what in (('short_description.txt', 'summary'), ('full_description.txt', 'description')):
    if f not in en or not text('en-US', f):
        print('crit\ten-US has no %s — F-Droid shows no %s without it' % (f, what))
for loc in sorted(locales):
    if not LOCALE.fullmatch(loc):
        fix = next((loc.replace(a, b) for a, b in (('_', '-'), ('-r', '-'), ('_r', '-'))
                    if LOCALE.fullmatch(loc.replace(a, b))), '')
        print('warn\t%s is not a locale name F-Droid takes%s' % (loc, ' — %s?' % fix if fix else ''))
    for f in locales[loc]:
        limit = LIMITS.get(f)
        if f.startswith('changelogs/') and f[len('changelogs/'):-len('.txt')] in codes:
            limit = 500
        if limit:
            n = len(text(loc, f))
            if n > limit:
                print('warn\t%s/%s is %d characters — F-Droid cuts it at %d' % (loc, f, n, limit))
    if 'full_description.txt' in locales[loc] and MARKDOWN.search(text(loc, 'full_description.txt')):
        print('note\t%s/full_description.txt looks like Markdown — F-Droid shows it as text (simple HTML works)' % loc)
PYFL
}
FL_REF="$TAG"
git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 || FL_REF=HEAD
FL_DIR=""
for d in fastlane/metadata/android ${FLUTTER_DIR:+"$FLUTTER_DIR/fastlane/metadata/android"}; do
  [ "${d#./}" = "$d" ] || continue
  if [ -n "$(git -C "$REPO" ls-tree --name-only "$FL_REF" -- "$d/" 2>/dev/null || true)" ]; then FL_DIR="$d"; break; fi
done
if [ -n "$FL_DIR" ]; then
  FL_CRIT=0; FL_WARN=0
  while IFS=$'\t' read -r lvl msg; do
    case "$lvl" in
      crit) warn "$msg"; FL_CRIT=$((FL_CRIT + 1)) ;;
      warn) warn "$msg"; FL_WARN=$((FL_WARN + 1)) ;;
      note) note "$msg" ;;
    esac
  done < <(fastlane_report "$FL_REF" "$FL_DIR" 2>/dev/null || true)
  if [ "$FL_CRIT" -gt 0 ]; then
    chk "check source code (the listing)" "failed: $FL_CRIT thing(s) missing from $FL_DIR at $FL_REF"
    BLOCKERS=$((BLOCKERS+1))
  elif [ "$FL_WARN" -gt 0 ]; then
    chk "check source code (the listing)" "warn: $FL_WARN thing(s) to look at in $FL_DIR"
  else
    ok "the listing in $FL_DIR has what F-Droid needs"
    chk "check source code (the listing)" "passed: $FL_DIR at $FL_REF"
  fi
elif [ -d "$REPO/$SUBDIR/src/main/play" ]; then
  chk "check source code (the listing)" "skipped: a Triple-T listing — the pipeline reads it itself"
else
  chk "check source code (the listing)" "failed: no fastlane listing in $FL_REF"
fi

if [ "$BLOCKERS" = 0 ]; then chk "pitfall check (your app repo)" passed
else chk "pitfall check (your app repo)" "warn: $BLOCKERS thing(s) reviewers usually ask about, listed under Pitfall check"; fi
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
# Your git config may send GitLab over ssh (url.…insteadOf, or an ssh remote).
# ssh then needs gitlab.com's host key in ~/.ssh/known_hosts; without it, ssh
# asks — or, with no terminal to ask in, fails every fetch and push. The key is
# fetched and compared with the fingerprint GitLab publishes before anything
# is added (docs.gitlab.com: "SSH host keys fingerprints").
GITLAB_ED25519="SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8"
gitlab_ssh_check() {
  local url out fp line
  url="$(git -C "$FDROIDDATA" ls-remote --get-url upstream 2>/dev/null || true)"
  case "$url" in ssh://*gitlab.com*|git@gitlab.com:*) ;; *) return 0 ;; esac
  have ssh || return 0
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=15 -T git@gitlab.com 2>&1 || true)"
  case "$out" in *"Host key verification failed"*) ;; *) return 0 ;; esac
  warn "your git reaches gitlab.com over ssh, and ssh does not know gitlab.com's host key"
  { have ssh-keyscan && have ssh-keygen; } || { note "add it with: ssh -T git@gitlab.com (answer yes)"; return 0; }
  line="$(ssh-keyscan -t ed25519 gitlab.com 2>/dev/null | grep -v '^#' | sed -n 1p || true)"
  fp="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)"
  if [ "$fp" != "$GITLAB_ED25519" ]; then
    warn "the key gitlab.com offers ($fp) is not the one GitLab publishes — not adding it"
    return 0
  fi
  note "gitlab.com's key matches the one GitLab publishes: $fp"
  if go "Add it to ~/.ssh/known_hosts?"; then
    mkdir -p "$HOME/.ssh"; printf '%s\n' "$line" >> "$HOME/.ssh/known_hosts"
    ok "added — ssh to gitlab.com works now"
  fi
}
gitlab_ssh_check
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
        # the version your unmerged recipe already builds: keep the commit it
        # builds — a fix made after the tag (the listing, say) stays in
        same = (kind in ('fork', 'app') and os.environ.get('FDS_KEEP_COMMIT') == '1'
                and all(e.get(k, ('s', ''))[1] == g.get(k, ('s', ''))[1]
                        for k in ('versionName', 'versionCode')))
        for k in version + tuple(keep):
            if k == 'commit' and same and 'commit' in e:
                continue
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
fdef top Summary s "avoid it: the pipeline fails on it — F-Droid reads fastlane's short_description.txt"
fdef top Description b "avoid it: F-Droid reads fastlane's full_description.txt from your repo"
fdef top RequiresRoot s "true if the app needs root on the phone"
fdef top RepoType s "git, almost always"
fdef top Repo s "the address F-Droid clones the source from"
fdef top Binaries s "the address of your signed APK on a release page, for reproducible builds (%v: the version)"
fdef top AllowedAPKSigningKeys l "the SHA-256 fingerprint of the key you sign releases with"
fdef top MaintainerNotes b "notes for F-Droid's maintainers: why the recipe is the way it is"
fdef top ArchivePolicy s "how many old versions stay available (a number)"
fdef top AutoUpdateMode s "Version: F-Droid adds new versions by itself · None: you send a merge request"
fdef top UpdateCheckMode s "how new versions are found: Tags, Tags <regex>, RepoManifest, HTTP, Static or None"
fdef top UpdateCheckIgnore s "a regex of versions the update check skips"
fdef top VercodeOperation l "one APK per CPU type: each one's versionCode from the app's, e.g. 10 * %c + 1"
fdef top UpdateCheckName s "the application id the update check looks for, when the source has several"
fdef top UpdateCheckData s "where the update check reads version numbers, when build.gradle does not hold them"
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
    commit)
      if [ -n "$v" ] && [ -n "${COMMIT:-}" ] && [ "$v" != "$COMMIT" ] && [ "$v" != "$TAG" ]; then
        note "that is not your tag $TAG (${COMMIT:0:12}) but $(git -C "$REPO" log -1 --format='%h — %s' "$v" 2>/dev/null || printf '%s' "$v")"
        note "Enter keeps it; to build the tag instead, give the tag's hash: $COMMIT"
      fi ;;
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

# How often a field is wanted, for the add menus: 1 often, 2 sometimes, and
# everything else rarely — old build systems, lines asked about elsewhere, and
# what reviewers ask to avoid.
declare -A FTIER=()
for k in MaintainerNotes Name WebSite Translation Donate Liberapay OpenCollective Bitcoin Litecoin \
         AuthorEmail AuthorWebSite IssueTracker Changelog; do FTIER["top:$k"]=1; done
for k in ArchivePolicy UpdateCheckIgnore UpdateCheckName UpdateCheckData VercodeOperation \
         AntiFeatures AutoName RequiresRoot; do FTIER["top:$k"]=2; done
for k in gradle subdir submodules prebuild build rm srclibs sudo init ndk output scandelete \
         gradleprops; do FTIER["build:$k"]=1; done
for k in preassemble patch timeout postbuild binary antifeatures; do FTIER["build:$k"]=2; done

# The fields the recipe does not have yet, each with what it is for — the ones
# most often wanted first — any of them a number away.
yadd() {  # yadd top|build <label>
  local scope="$1" label="$2" names=() k i ch pre="top/" list t tier
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$scope" = build ] && pre="b/1/"
  while :; do
    names=()
    list="$FTOP"; [ "$scope" = build ] && list="$FBUILD"
    for t in 1 2 3; do
      for k in $list; do
        [ -f "$RR/$pre$k" ] && continue
        case "$scope:$k" in top:Builds|build:versionName|build:versionCode) continue ;; esac
        if [ "${FTIER[$scope:$k]:-3}" = "$t" ]; then names+=("$k"); fi
      done
    done
    printf '\n'; say "${B}$label${R} — a number or a field name; Enter when done"
    if [ "$scope" = build ]; then
      note "anything else the build needs — most builds need nothing more"
    else
      note "anything else the recipe should hold — most apps need nothing more"
    fi
    i=1; tier=0
    for k in ${names[@]+"${names[@]}"}; do
      t="${FTIER[$scope:$k]:-3}"
      if [ "$t" != "$tier" ]; then
        tier="$t"
        case "$t" in
          1) say "  often added:" ;;
          2) say "  sometimes needed:" ;;
          *) say "  rarely needed — old build systems, or what reviewers ask to avoid:" ;;
        esac
      fi
      printf '   %3d) %-18s %s%s%s\n' "$i" "$k" "$DIM" "${FHELP[$scope:$k]:-}" "$R"
      i=$((i + 1))
    done
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
  [ -n "$FL_GUESS" ] || note "the Flutter release F-Droid builds with — the one you build and test with (flutter --version)"
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
    say "A Flutter APK carries the app's engine once for every CPU type phones use —"
    say "armeabi-v7a (older phones), arm64-v8a (most phones), x86_64 (emulators,"
    say "Chromebooks) — so one APK for all of them is big. F-Droid's reviewers ask"
    say "Flutter apps for one APK per CPU type instead: each phone downloads only its"
    say "own. The recipe then has three build entries, numbered 10 × versionCode + 1,"
    say "2 and 3; and if you publish your own signed APKs, this wizard can build all"
    say "three for you."
    if ! confirm "Build one APK per CPU type?" y; then
      ABISPLIT=0
      warn "one APK for every CPU type: F-Droid's reviewers ask Flutter apps to split it — expect that request"
    fi
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
# a tag moved in this run is a new build: the recipe's own commit goes with it
FDS_KEEP_COMMIT=1; [ "$TAG_MOVED" = 1 ] && FDS_KEEP_COMMIT=0
FDS_KEEP_COMMIT="$FDS_KEEP_COMMIT" rcp template "$RG" "$RD" "$BASE_KIND" "$RT" "$VCODE"
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
# With a reproducible build F-Droid builds the app, checks the result is the
# APK you signed, and ships yours. So it needs your APK on the release page —
# Binaries: — and the fingerprint of your key — AllowedAPKSigningKeys:. Both
# are worked out from what is there where they can be: the release's own
# files, an APK built right here, the keystore your build already uses.

# pick <var> <default> <choice>… — a numbered menu; <var> gets the number. A
# choice can carry a second line (after a newline), shown dimmed below it.
pick() {
  local __var="$1" __def="$2" __i=1 __c __n
  shift 2
  __n=$#
  for __c in "$@"; do
    printf '     %d) %s\n' "$__i" "${__c%%$'\n'*}"
    case "$__c" in *$'\n'*) printf '        %s%s%s\n' "$DIM" "${__c#*$'\n'}" "$R" ;; esac
    __i=$((__i + 1))
  done
  while :; do
    ask "$__var" "Which" "$__def"
    case "${!__var}" in
      ''|*[!0-9]*) ;;
      *) if [ "${!__var}" -ge 1 ] && [ "${!__var}" -le "$__n" ]; then return 0; fi ;;
    esac
    [ "$ASSUME_YES" = 1 ] && die "--yes: '${!__var}' is not one of the choices — run once without --yes"
    warn "a number from 1 to $__n"
  done
}

tag_pattern() {  # the tag with the version as %v: v1.2.3 -> v%v
  case "$TAG" in
    *"$VNAME"*) printf '%s' "${TAG//"$VNAME"/%v}" ;;
    *) printf '%s' "$TAG" ;;
  esac
}
apk_abi() {  # apk_abi <file name> — the CPU type it is for, if it says
  printf '%s' "$1" | grep -oE 'armeabi-v7a|arm64-v8a|x86_64|x86' | sed -n 1p || true
}
apk_pattern() {  # apk_pattern <file name> — with %v, %c and %abi where they go
  local s="$1" a
  a="$(apk_abi "$s")"
  [ -z "$a" ] || s="${s//"$a"/%abi}"
  s="${s//"$VNAME"/%v}"
  printf '%s' "$s" | sed -E "s/(^|[^0-9])$VCODE([^0-9]|\$)/\\1%c\\2/g"
}
release_assets() {  # release_assets <tag> — the files on the forge's release for it
  local path json=""
  case "$WEB_GUESS" in
    https://github.com/*)
      path="${WEB_GUESS#https://github.com/}"
      if [ "$FORGE_CLI" = gh ]; then
        json="$(cd "$REPO" && gh api "repos/$path/releases/tags/$1" 2>/dev/null || true)"
      else
        json="$(curl -s --max-time 20 "https://api.github.com/repos/$path/releases/tags/$1" 2>/dev/null || true)"
      fi ;;
    https://codeberg.org/*)
      path="${WEB_GUESS#https://codeberg.org/}"
      json="$(curl -s --max-time 20 "https://codeberg.org/api/v1/repos/$path/releases/tags/$1" 2>/dev/null || true)" ;;
    *) return 0 ;;
  esac
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
for a in (d.get("assets") or []) if isinstance(d, dict) else []:
    print(a.get("name") or "")
' 2>/dev/null || true
}
binary_there() {  # binary_there <url> — say whether the APK can be downloaded
  local code
  code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || true)"
  case "$code" in
    200) ok "found the APK: $1" ;;
    404) warn "no APK at $1"
         note "upload the signed APK to the release, or fix the address — F-Droid needs to download it" ;;
    *)   note "could not check $1 (HTTP ${code:-none})" ;;
  esac
  return 0
}

# What an APK says about itself.
apk_cert() {  # apk_cert <apk> — its signing certificate's SHA-256, as F-Droid writes it
  local as="" cand out=""
  if have apksigner; then as="apksigner"
  elif [ -n "${ANDROID_HOME:-}" ]; then
    cand="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
    if [ -n "$cand" ] && [ -f "$cand/lib/apksigner.jar" ]; then as="java -jar $cand/lib/apksigner.jar"; fi
  fi
  if [ -n "$as" ]; then
    # shellcheck disable=SC2086
    out="$($as verify --print-certs "$1" 2>/dev/null | awk '/certificate SHA-256 digest/ {print $NF; exit}' || true)"
  fi
  # keytool ships with any JDK and reads the APK's signature block too
  if [ -z "$out" ] && have keytool; then
    out="$(keytool -printcert -jarfile "$1" 2>/dev/null | awk '/SHA256:/ {print $2; exit}' || true)"
  fi
  printf '%s' "$out" | tr -d ': ' | tr 'A-F' 'a-f'
}
apk_is_debug() {  # true when the APK is signed with Android's debug key
  { apksigner verify --print-certs "$1" 2>/dev/null || keytool -printcert -jarfile "$1" 2>/dev/null || true; } \
    | grep -q 'CN=Android Debug'
}
apk_vcode() {  # apk_vcode <apk> — its versionCode, when aapt2 is at hand
  local a
  a="$(command -v aapt2 2>/dev/null || ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$a" ] || return 0
  "$a" dump badging "$1" 2>/dev/null | sed -nE "s/.*versionCode='([0-9]+)'.*/\1/p" | sed -n 1p || true
}
sigclean() { printf '%s' "$1" | tr -d ': ' | tr 'A-F' 'a-f'; }
sigok() { printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'; }

check_reference_apk() {  # check_reference_apk <apk> [built] — what F-Droid's checks will say about it
  local blk
  [ -f "$1" ] || return 0
  reference_apk_blocks "$1" | while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    warn "the APK carries an extra signing block: $blk"
    note "F-Droid's scanner refuses it — the \"check apk\" job fails once"
    note "everything else has passed. Switch it off in the gradle file:"
    note "  android { dependenciesInfo { includeInApk = false; includeInBundle = false } }"
    note "that changes the APK, so it needs a new version and new binaries"
  done
  reference_apk_reproducible "$1" "$APPID" && return 0
  # built here just now, at your request: say what the recipe needs, and go on
  if [ "${2-}" = built ]; then
    note "add those lines when the build entry is asked about, below"
    return 0
  fi
  confirm "Submit with reproducible builds anyway?" n || \
    die "build the APK you publish at F-Droid's path first, then re-run"
}

# --- build the release APKs here: signed with your key the way your project
# signs releases, and one per CPU type when the recipe has one build entry per
# CPU type. BUILT_APKS lists what came out; BUILT_SHA is their key.
BUILT_APKS=""; BUILT_SHA=""; REF_BUILD=0
can_build_here() {  # flutter for a Flutter app, the project's gradle wrapper otherwise
  if [ -n "$FLUTTER_DIR" ]; then have flutter; else [ -x "$REPO/gradlew" ]; fi
}
build_release_apks() {
  local flags task mod fl fv log="$WORK/apk-build.log" out f s vc want n abi keep fdir="$REPO"
  BUILT_APKS=""; BUILT_SHA=""
  [ "${FLUTTER_DIR:-.}" = . ] || fdir="$REPO/$FLUTTER_DIR"
  if [ "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)" != "$COMMIT" ]; then
    warn "your checkout is not at $TAG — F-Droid builds $TAG, so the APK has to come from it"
    note "check it out first (git -C $REPO checkout $TAG), or build it yourself"
    return 1
  fi
  if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
    warn "you have uncommitted changes: they would go into this APK, but not into F-Droid's"
    confirm "Build anyway?" n || return 1
  fi
  : > "$WORK/build.stamp"
  if [ -n "$FLUTTER_DIR" ]; then
    fv="$(flutter --version --machine 2>/dev/null \
          | sed -nE 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | sed -n 1p || true)"
    if [ -n "$fv" ] && [ -n "${FLUTTERREF:-}" ] && [ "$fv" != "$FLUTTERREF" ]; then
      warn "your flutter is $fv; the recipe builds with $FLUTTERREF — the APKs would not match F-Droid's"
      confirm "Build with $fv anyway?" n || return 1
    fi
    flags="--release"
    [ "$K" -gt 1 ] && flags="$flags --split-per-abi"
    [ -n "${GRADLEFLAVOUR:-}" ] && flags="$flags --flavor $GRADLEFLAVOUR"
    if [ "$fdir" = "$REPO" ]; then say "flutter build apk $flags — a few minutes, quiet until it ends"
    else say "flutter build apk $flags — in $FLUTTER_DIR/; a few minutes, quiet until it ends"; fi
    note "its output goes to $log"
    # shellcheck disable=SC2086
    if ! ( cd "$fdir" && flutter pub get && flutter build apk $flags ) > "$log" 2>&1; then
      warn "the build failed:"; tail -n 15 "$log" | sed 's/^/       /'; KEEP_WORK=1; return 1
    fi
    out="$fdir/build/app/outputs/flutter-apk"
  else
    mod=":${SUBDIR//\//:}"; [ "$SUBDIR" = . ] && mod=""
    fl=""
    case "${GRADLE_DEF:-yes}" in
      yes) ;;
      *) fl="$(printf '%s' "${GRADLE_DEF:0:1}" | tr '[:lower:]' '[:upper:]')${GRADLE_DEF:1}" ;;
    esac
    task="$mod:assemble${fl}Release"
    say "./gradlew $task — a few minutes, quiet until it ends"
    note "its output goes to $log"
    if ! ( cd "$REPO" && ./gradlew --console=plain "$task" ) > "$log" 2>&1; then
      warn "the build failed:"; tail -n 15 "$log" | sed 's/^/       /'; KEEP_WORK=1; return 1
    fi
    out="$REPO/$SUBDIR/build/outputs/apk"; [ "$SUBDIR" != . ] || out="$REPO/build/outputs/apk"
  fi
  BUILT_APKS="$(find "$out" -name '*.apk' -newer "$WORK/build.stamp" 2>/dev/null | sort || true)"
  # as many as the recipe has build entries: one per CPU type, or one for all
  if [ "$K" -gt 1 ]; then
    keep="$(printf '%s\n' "$BUILT_APKS" | grep -E 'armeabi-v7a|arm64-v8a|x86_64' || true)"
  else
    keep="$(printf '%s\n' "$BUILT_APKS" | grep -vE 'armeabi-v7a|arm64-v8a|x86_64|x86' | sed -n 1p || true)"
  fi
  BUILT_APKS="$keep"
  [ -n "$BUILT_APKS" ] || { warn "the build left no fitting APK in ${out#"$REPO"/}"; return 1; }
  if [ -z "$(apk_cert "$(printf '%s\n' "$BUILT_APKS" | sed -n 1p)")" ]; then
    warn "the build is unsigned: your build files do not sign releases on this machine"
    sign_built_apks || { note "sign it yourself and put it on the release"; return 1; }
  fi
  ok "built:"
  while IFS= read -r f; do
    s="$(apk_cert "$f")"; vc="$(apk_vcode "$f")"
    note "  ${f#"$REPO"/}${vc:+  (versionCode $vc)}"
    if [ -z "$s" ]; then
      warn "it is not signed — your release signing is not set up on this machine"
      note "(the keystore your build.gradle reads, often through android/key.properties)"
      return 1
    fi
    if apk_is_debug "$f"; then warn "it is signed with Android's debug key, not a release key"; return 1; fi
    [ -n "$BUILT_SHA" ] || BUILT_SHA="$s"
    [ "$s" = "$BUILT_SHA" ] || { warn "the APKs are signed with different keys"; return 1; }
  done <<< "$BUILT_APKS"
  # each one has to carry its build entry's versionCode
  for n in $(seq 1 "$K"); do
    want="$(fv "$RT/b/$n/versionCode")"; abi=""
    [ "$K" -gt 1 ] && abi="$(entry_label "$n")"
    if [ -n "$abi" ]; then f="$(printf '%s\n' "$BUILT_APKS" | grep -F -- "-$abi-" | sed -n 1p || true)"
    else f="$(printf '%s\n' "$BUILT_APKS" | sed -n 1p)"; fi
    if [ -z "$f" ]; then warn "no APK for ${abi:-the build entry} came out"; continue; fi
    vc="$(apk_vcode "$f")"
    if [ -n "$vc" ] && [ "$vc" != "$want" ]; then
      warn "${f##*/} has versionCode $vc, the recipe $want — see the per-CPU numbering above"
    fi
  done
  check_reference_apk "$(printf '%s\n' "$BUILT_APKS" | sed -n 1p)" built
  return 0
}

# app_builds_dir — the builds/ folder of the app's project, when its repo lives
# in a <project>/branches/<branch> layout: signed builds are kept there, where
# they are easy to find
app_project_dir() {  # <project> of a repo in a <project>/branches/<branch> layout
  local parent
  parent="$(dirname "$REPO")"
  if [ "$(basename "$parent")" = branches ]; then dirname "$parent"; fi
}
app_builds_dir() {
  local p; p="$(app_project_dir)"
  if [ -n "$p" ]; then printf '%s/builds' "$p"; fi
}

# app_keystores — release keystores this app may be signed with: the one a
# key.properties names, and any in the project's secrets/ folder
app_keystores() {
  local kp store p f
  while IFS= read -r kp; do
    [ -n "$kp" ] || continue
    store="$(sed -nE 's/^[[:space:]]*storeFile[[:space:]]*=[[:space:]]*//p' "$kp" | sed -n 1p | tr -d '\r')"
    store="${store/#\~/$HOME}"
    for f in "$store" "$(dirname "$kp")/app/$store" "$(dirname "$kp")/$store"; do
      case "$f" in /*) if [ -f "$f" ]; then printf '%s\n' "$f"; break; fi ;; esac
    done
  done < <(key_props)
  p="$(app_project_dir)"
  if [ -n "$p" ] && [ -d "$p/secrets" ]; then
    find "$p/secrets" -maxdepth 2 -type f \( -name '*.jks' -o -name '*.keystore' -o -name '*.p12' \) 2>/dev/null
  fi
}

# kp_value <key.properties> <key> — one value from a properties file
kp_value() { sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | sed -n 1p | tr -d '\r'; }
kp_store() {  # kp_store <key.properties> — the keystore it names, as a full path
  local kp="$1" store f
  store="$(kp_value "$kp" storeFile)"; store="${store/#\~/$HOME}"
  [ -n "$store" ] || return 0
  for f in "$store" "$(dirname "$kp")/app/$store" "$(dirname "$kp")/$store" "$REPO/$SUBDIR/$store"; do
    case "$f" in /*) if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi ;; esac
  done
}

# choose_keystore — SIGN_KS, SIGN_ALIAS, SIGN_PW, SIGN_KPW: your release key,
# picked once a run. A key.properties that names the keystore — your build's,
# or one in the project's secrets/ folder — gives the passwords; otherwise
# they are asked for, used for this run only, and never written anywhere.
SIGN_KS=""; SIGN_ALIAS=""; SIGN_PW=""; SIGN_KPW=""
choose_keystore() {
  local stores=() ks kp alias=""
  [ -z "$SIGN_KS" ] || return 0
  while IFS= read -r ks; do
    if [ -n "$ks" ]; then stores+=("$ks"); fi
  done < <(app_keystores | awk '!seen[$0]++')
  stores+=("another keystore — give its path")
  say "Your release keystore — the key your APKs are signed with:"
  pick SIGN_KS_N 1 "${stores[@]}"
  ks="${stores[$((SIGN_KS_N - 1))]}"
  if [ "$SIGN_KS_N" = "${#stores[@]}" ]; then
    ask KEYSTORE "Path to your release keystore" ""
    ks="${KEYSTORE/#\~/$HOME}"
  fi
  [ -f "$ks" ] || { warn "no such file: $ks"; return 1; }
  while IFS= read -r kp; do
    if [ -n "$kp" ] && [ "$(kp_store "$kp")" = "$ks" ]; then
      SIGN_PW="$(kp_value "$kp" storePassword)"; SIGN_KPW="$(kp_value "$kp" keyPassword)"
      alias="$(kp_value "$kp" keyAlias)"
      [ -z "$SIGN_PW" ] || note "its passwords come from ${kp/#$HOME/~}"
      break
    fi
  done < <(key_props)
  if [ -z "$SIGN_PW" ]; then
    printf '   %sPassword of %s%s (not shown, not kept): ' "$B" "${ks##*/}" "$R" >&2
    IFS= read -rs SIGN_PW || true; printf '\n' >&2
  fi
  SIGN_KPW="${SIGN_KPW:-$SIGN_PW}"
  [ -n "$alias" ] || alias="$(FD_KS_PASS="$SIGN_PW" keytool -list -keystore "$ks" -storepass:env FD_KS_PASS 2>/dev/null \
                              | awk -F', ' '/PrivateKeyEntry/ {print $1; exit}')"
  [ -n "$alias" ] || { warn "could not open ${ks##*/} — a wrong password?"; SIGN_PW=""; return 1; }
  SIGN_KS="$ks"; SIGN_ALIAS="$alias"
}

# apksigner_cmd — APKSIGNER: an apksigner that can sign without re-aligning
# (--alignment-preserved, build-tools 35 and later)
APKSIGNER=()
apksigner_cmd() {
  local j
  [ "${#APKSIGNER[@]}" = 0 ] || return 0
  if have apksigner && apksigner sign --help 2>&1 | grep -q 'alignment-preserved'; then APKSIGNER=(apksigner); return 0; fi
  for j in $(ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}"/build-tools/*/lib/apksigner.jar 2>/dev/null | sort -rV); do
    if java -jar "$j" sign --help 2>&1 | grep -q 'alignment-preserved'; then APKSIGNER=(java -jar "$j"); return 0; fi
  done
  warn "no apksigner that can sign without re-aligning (Android build-tools 35 or later)"
  return 1
}
apk_minsdk() {  # apk_minsdk <apk> — its minSdkVersion, when aapt2 is at hand
  local a
  a="$(command -v aapt2 2>/dev/null || ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$a" ] || return 0
  "$a" dump badging "$1" 2>/dev/null | sed -nE "s/^(min)?[sS]dkVersion:'([0-9]+)'.*/\2/p" | sed -n 1p || true
}

# sign_apk <unsigned> <out> — signed with your release key the way
# fdroidserver can check: F-Droid builds the APK itself and copies your
# signature onto it without moving a byte, so the signed APK must keep the
# unsigned one's layout. apksigner re-aligns by default (zipalign does too),
# and the v1 signature it adds marks its entries in a way fdroidserver does
# not repeat: so --alignment-preserved, and no v1 from Android 7 (minSdk 24) on.
sign_apk() {
  local src="$1" out="$2" min v1=true
  choose_keystore || return 1
  apksigner_cmd || return 1
  min="$(apk_minsdk "$src")"
  if [ -n "$min" ] && [ "$min" -ge 24 ]; then v1=false; fi
  mkdir -p "$(dirname "$out")"
  if ! FD_KS_PASS="$SIGN_PW" FD_KEY_PASS="$SIGN_KPW" "${APKSIGNER[@]}" sign --ks "$SIGN_KS" --ks-key-alias "$SIGN_ALIAS" \
       --ks-pass env:FD_KS_PASS --key-pass env:FD_KEY_PASS --alignment-preserved true \
       --v1-signing-enabled "$v1" --out "$out" "$src" >"$WORK/sign.log" 2>&1; then
    warn "apksigner could not sign ${src##*/}:"; tail -n 3 "$WORK/sign.log" | sed 's/^/       /'
    return 1
  fi
  rm -f "$out.idsig"
}

# ref_matches <signed> <unsigned> — fdroidserver's own check, as the pipeline
# runs it: your signature copied onto F-Droid's build has to verify
cat > "$WORK/verify-ref.py" <<'PYVERIFY'
import logging, sys, tempfile
from fdroidserver import common
logging.basicConfig(level=logging.ERROR)
common.config = {}
common.fill_config_defaults(common.config)
err = common.verify_apks(sys.argv[1], sys.argv[2], tempfile.mkdtemp())
if err:
    print(err)
    sys.exit(1)
PYVERIFY
ref_matches() { fpy "$WORK/verify-ref.py" "$1" "$2" > "$WORK/verify-ref.log" 2>&1; }

# sign_built_apks — BUILT_APKS came out unsigned (the project signs releases by
# hand): sign them with your release keystore, as you would yourself. The
# password is asked for, used once and never kept.
sign_built_apks() {
  local f out signed=""
  say "Sign it with your release key here? F-Droid compares its own build with your signed APK."
  while IFS= read -r f; do
    out="$WORK/signed/$(basename "${f%-unsigned.apk}")"; out="${out%.apk}.apk"
    sign_apk "$f" "$out" || return 1
    signed="${signed:+$signed$'\n'}$out"
  done <<< "$BUILT_APKS"
  BUILT_APKS="$signed"
  ok "signed with ${SIGN_KS##*/} ($SIGN_ALIAS)"
}

# upload_release_apks — BUILT_APKS onto release $TAG, named as Binaries says
upload_release_apks() {
  local f abi code n name up=() notes="$WORK/release-notes.md" keep bdir
  rm -rf "$WORK/upload"; mkdir -p "$WORK/upload"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    abi="$(apk_abi "${f##*/}")"; code="$VCODE"
    if [ "$K" -gt 1 ]; then
      for n in $(seq 1 "$K"); do
        if [ "$(entry_label "$n")" = "$abi" ]; then code="$(fv "$RT/b/$n/versionCode")"; fi
      done
    fi
    name="${BINARIES##*/}"; name="${name//%v/$VNAME}"; name="${name//%c/$code}"; name="${name//%abi/$abi}"
    cp "$f" "$WORK/upload/$name"; up+=("$WORK/upload/$name")
    note "  ${f##*/} → $name"
  done <<< "$BUILT_APKS"
  # a copy to keep: in your project's builds/ folder, or left in the scratch folder
  keep="$WORK/upload"; bdir="$(app_builds_dir)"
  if [ -n "$bdir" ] && mkdir -p "$bdir" && cp "${up[@]}" "$bdir/"; then
    keep="$bdir"; ok "the signed APKs are in $bdir"
  fi
  [ "$keep" != "$WORK/upload" ] || KEEP_WORK=1
  case "$BINARIES" in
    "$WEB_GUESS/releases/download/"*) ;;
    *) note "Binaries points elsewhere — put them there yourself; they are in $keep"
       return 0 ;;
  esac
  if [ "$DRYRUN" = 1 ]; then warn "dry run — would put them on release $TAG"; return 0; fi
  if [ "$FORGE_CLI" != gh ]; then
    note "put them on release $TAG yourself ($WEB_GUESS/releases) — they are in $keep"
    return 0
  fi
  if ! release_exists; then
    if ! go "Release $TAG is not on GitHub yet — publish it, with these files?"; then
      note "they are in $keep"; return 0
    fi
    if [ -f "${FL_BASE:-/nonexistent}/changelogs/$VCODE.txt" ]; then cp "$FL_BASE/changelogs/$VCODE.txt" "$notes"
    else printf '%s\n' "$TAG" > "$notes"; fi
    if ( cd "$REPO" && gh release create "$TAG" --title "$TAG" --notes-file "$notes" "${up[@]}" ) >/dev/null 2>&1; then
      ok "release $TAG published, with the APKs"; remember ST_RELEASE "$TAG"
    else
      warn "gh could not publish it — the APKs are in $keep"
    fi
    return 0
  fi
  if ! go "Put them on release $TAG (replacing files of the same name)?"; then
    note "they are in $keep"; return 0
  fi
  if ( cd "$REPO" && gh release upload "$TAG" "${up[@]}" --clobber ) >/dev/null 2>&1; then
    ok "uploaded to release $TAG"
  else
    warn "gh could not upload them — they are in $keep"
  fi
}

# --- the signing key's fingerprint: where it can be read from
local_apks() {  # release APKs in this repo's build folders, newest first
  local d
  for d in ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/build/app/outputs"} "$REPO/$SUBDIR/build/outputs" \
           "$REPO/build" "$REPO/dist" "$REPO/release" "$REPO/releases"; do
    if [ -d "$d" ]; then find "$d" -name '*.apk' -not -iname '*debug*' -not -iname '*unsigned*' -printf '%T@ %p\n' 2>/dev/null; fi
  done | sed 's#/\./#/#g' | sort -rn | awk '{ sub(/^[^ ]+ /, ""); if (!seen[$0]++) print }' | head -4
}
key_props() {  # the properties files naming your release keystore: your build's, and the project's secrets/
  local f sec=""
  sec="$(app_project_dir)"; [ -z "$sec" ] || sec="$sec/secrets"
  for f in "$REPO/android/key.properties" ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/android/key.properties"} \
           "$REPO/key.properties" "$REPO/keystore.properties" "$REPO/signing.properties" \
           "$REPO/$SUBDIR/key.properties" "$REPO/$SUBDIR/keystore.properties" \
           ${sec:+"$sec"/*.properties}; do
    if [ -f "$f" ] && grep -q 'storeFile' "$f" 2>/dev/null; then
      printf '%s/%s\n' "$(cd "$(dirname "$f")" && pwd -P)" "$(basename "$f")"
    fi
  done | awk '!seen[$0]++'
}
keystore_cert() {  # keystore_cert <key.properties> — the key's fingerprint, read with keytool
  local kp="$1" store alias pass base cand
  have keytool || { warn "keytool (it comes with any JDK) is not installed"; return 1; }
  store="$(sed -nE 's/^[[:space:]]*storeFile[[:space:]]*=[[:space:]]*//p' "$kp" | sed -n 1p | tr -d '\r')"
  alias="$(sed -nE 's/^[[:space:]]*keyAlias[[:space:]]*=[[:space:]]*//p' "$kp" | sed -n 1p | tr -d '\r')"
  pass="$(sed -nE 's/^[[:space:]]*storePassword[[:space:]]*=[[:space:]]*//p' "$kp" | sed -n 1p | tr -d '\r')"
  store="${store/#\~/$HOME}"; base="$(dirname "$kp")"
  # gradle reads it relative to the module that uses it: android/app, usually
  for cand in "$store" "$base/app/$store" "$base/$store" "$REPO/$SUBDIR/$store"; do
    case "$cand" in /*) if [ -f "$cand" ]; then store="$cand"; break; fi ;; esac
  done
  [ -f "$store" ] || { warn "the keystore it names is not here: $store"; return 1; }
  if [ -z "$pass" ]; then
    printf '   %sPassword of %s%s (not shown, not kept): ' "$B" "${store##*/}" "$R" >&2
    IFS= read -rs pass || true; printf '\n' >&2
  fi
  FD_KS_PASS="$pass" keytool -list -v -keystore "$store" ${alias:+-alias "$alias"} -storepass:env FD_KS_PASS 2>/dev/null \
    | awk '/SHA256:/ {print $2; exit}' | tr -d ':' | tr 'A-F' 'a-f'
}

# ask_signkey <APK address> <known key> <where it is from> — SIGNKEY, from
# wherever it can be read: the APK on the release, one built here, the keystore.
ask_signkey() {
  local url="$1" known="$2" from="$3" choices=() acts=() a apk kp
  printf '\n'
  say "${B}AllowedAPKSigningKeys${R} — the fingerprint of the key you sign releases with."
  say "F-Droid ships your APK only when it is signed with exactly this key. It is the"
  say "SHA-256 of your signing certificate: 64 characters, 0-9 and a-f. Not a secret."
  if [ -n "$known" ]; then choices+=("keep it — $from"$'\n'"$known"); acts+=(keep); fi
  if [ -n "$url" ] && [ "$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)" = 200 ]; then
    choices+=("read it from the APK on release $TAG"$'\n'"downloads ${url##*/}"); acts+=(url)
  fi
  while IFS= read -r apk; do
    [ -n "$apk" ] || continue
    choices+=("read it from ${apk#"$REPO"/}"$'\n'"built $(date -r "$apk" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')")
    acts+=("apk:$apk")
  done < <(local_apks)
  while IFS= read -r kp; do
    [ -n "$kp" ] || continue
    choices+=("read it from the keystore ${kp#"$REPO"/} names"$'\n'"with the passwords in that file, or it asks; nothing is kept")
    acts+=("ks:$kp")
  done < <(key_props)
  if [ -n "$(app_keystores | head -1)" ]; then
    choices+=("read it from your release keystore"$'\n'"the one in your project's secrets/ folder, or another; asks for its password unless a key.properties has it")
    acts+=(keystore)
  fi
  choices+=("read it from another APK — give its path"); acts+=(path)
  choices+=("type or paste it"); acts+=(type)
  pick SIGN_SRC 1 "${choices[@]}"
  a="${acts[$((SIGN_SRC - 1))]}"
  SIGNKEY=""
  case "$a" in
    keep)  SIGNKEY="$known" ;;
    url)   say "downloading ${url##*/}…"
           if curl -sL --max-time 300 -o "$WORK/release.apk" "$url"; then
             SIGNKEY="$(apk_cert "$WORK/release.apk")"; check_reference_apk "$WORK/release.apk"
           fi ;;
    apk:*) SIGNKEY="$(apk_cert "${a#apk:}")"; check_reference_apk "${a#apk:}" ;;
    ks:*)  SIGNKEY="$(keystore_cert "${a#ks:}" || true)" ;;
    keystore)
           if choose_keystore; then
             SIGNKEY="$(FD_KS_PASS="$SIGN_PW" keytool -list -v -keystore "$SIGN_KS" -alias "$SIGN_ALIAS" \
                          -storepass:env FD_KS_PASS 2>/dev/null | awk '/SHA256:/ {print $2; exit}' | tr -d ':' | tr 'A-F' 'a-f')"
           fi ;;
    path)  ask APKPATH "Path to your signed release APK" ""
           APKPATH="${APKPATH/#\~/$HOME}"
           if [ -f "$APKPATH" ]; then SIGNKEY="$(apk_cert "$APKPATH")"; check_reference_apk "$APKPATH"
           else warn "no such file: $APKPATH"; fi ;;
  esac
  if [ -n "$SIGNKEY" ] && [ "$a" != keep ]; then ok "read it: $SIGNKEY"
  elif [ -z "$SIGNKEY" ] && [ "$a" != type ]; then warn "could not read it from there"; fi
  return 0
}

ask_publishing() {
  local def=1 n abi b assets="" a pat_rel="" pat_usual="" derived choices=() acts=() act bdef url1="" known="" from=""
  { [ -f "$RD/top/Binaries" ] || [ -f "$RD/top/AllowedAPKSigningKeys" ] \
    || ls "$RT"/b/*/binary >/dev/null 2>&1; } && def=2
  printf '\n'; say "${B}Publishing — whose signature your users get${R}"
  say "  1) ${B}F-Droid builds and signs${R} — the simplest"
  say "     F-Droid compiles the app from your source and signs it with its own key."
  say "     Whoever installed your own APK (from GitHub, say) has to uninstall it"
  say "     before F-Droid's will install: the signatures differ."
  say "  2) ${B}Reproducible build${R} — keeps your signature"
  say "     F-Droid compiles it too, checks the result is the same as your signed APK,"
  say "     and ships yours. Users can move between F-Droid and your releases freely."
  say "     It needs your signed APK on a release page, and your key's fingerprint."
  ask MODE "Which?" "$(r="$(recall MODE)"; printf '%s' "${r:-$def}")"
  tdone Binaries AllowedAPKSigningKeys
  if [ "$MODE" != 2 ]; then
    rdel top/Binaries; rdel top/AllowedAPKSigningKeys
    for n in $(seq 1 "$K"); do rm -f "$RT/b/$n/binary" "$RT/b/$n/binary.k"; done
    return 0
  fi

  # --- Binaries: your signed APK on the release page
  printf '\n'
  say "${B}Binaries${R} — the address F-Droid downloads your signed APK from, to compare it"
  say "with its own build. It has placeholders F-Droid fills in for every version:"
  say "  %v the versionName (now $VNAME) · %c the versionCode (now $VCODE)"
  if [ "$K" -gt 1 ]; then
    say "  %abi the CPU type — each of the $K build entries gets its own address"
  fi
  if [ -n "$WEB_GUESS" ]; then
    # named after the project, not the local checkout's folder
    pat_usual="$WEB_GUESS/releases/download/$(tag_pattern)/${WEB_GUESS##*/}-%v"
    [ "$K" -gt 1 ] && pat_usual="$pat_usual-%abi"
    pat_usual="$pat_usual.apk"
    assets="$(release_assets "$TAG" | grep -iE '\.apk$' || true)"
  fi
  if [ -n "$assets" ]; then
    if [ "$K" -gt 1 ]; then a="$(printf '%s\n' "$assets" | grep -E 'armeabi-v7a|arm64-v8a|x86_64' | sed -n 1p || true)"
    else a="$(printf '%s\n' "$assets" | grep -vE 'armeabi-v7a|arm64-v8a|x86_64|x86' | sed -n 1p || true)"; fi
    [ -z "$a" ] || pat_rel="$WEB_GUESS/releases/download/$(tag_pattern)/$(apk_pattern "$a")"
  fi
  if [ -n "$pat_rel" ]; then
    choices+=("the one$([ "$K" -gt 1 ] && echo s) on release $TAG: $(printf '%s' "$assets" | tr '\n' ' ')"$'\n'"$pat_rel")
    acts+=(rel)
  fi
  if can_build_here; then
    if [ "$K" -gt 1 ]; then
      choices+=("build them here the way F-Droid does — one APK per CPU type — sign them with your key, and put them on release $TAG")
    else
      choices+=("build it here the way F-Droid does, sign it with your key, and put it on release $TAG")
    fi
    acts+=(build)
  fi
  if [ -n "$pat_usual" ]; then
    choices+=("you put it on the release yourself, named like this:"$'\n'"$pat_usual"); acts+=(later)
  fi
  choices+=("type the address yourself"); acts+=(type)
  # the release's own files when it has them; building is offered, not assumed
  bdef=1
  for n in "${!acts[@]}"; do
    if [ "${acts[$n]}" = later ]; then bdef=$((n + 1)); fi
  done
  [ "${acts[0]}" = rel ] && bdef=1
  pick BIN_SRC "$bdef" "${choices[@]}"
  act="${acts[$((BIN_SRC - 1))]}"
  case "$act" in
    rel)  derived="$pat_rel" ;;
    *)    derived="$(recall BINARIES)"; [ -n "$derived" ] || derived="$(dflt Binaries "")"
          [ -n "$derived" ] || [ "$act" = type ] || derived="$pat_usual" ;;
  esac
  [ "$act" = type ] || note "Enter keeps it; change it if your file names differ"
  while :; do
    ask BINARIES "Binaries" "$derived"
    case "$BINARIES" in
      https://*) ;;
      *) [ "$ASSUME_YES" = 1 ] && die "Binaries has to be an https:// address"
         warn "it has to be an https:// address"; derived=""; remember BINARIES ""; continue ;;
    esac
    case "$BINARIES" in
      *%v*|*%c*) ;;
      *) warn "without %v (or %c) it names this version only — every update would need a new one" ;;
    esac
    if [ "$K" -gt 1 ]; then
      case "$BINARIES" in *%abi*) ;; *) warn "without %abi all $K CPU types point at the same file" ;; esac
    fi
    break
  done
  if [ "$act" = build ] && [ "$FD_SCANNER_OK" = 1 ] && [ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]; then
    # fdroidserver builds it in stage 4, once the recipe is written: exactly
    # the APK the pipeline builds, so the one you sign is the one it compares
    REF_BUILD=1
    note "it is built in stage 4 by fdroidserver itself — the very APK F-Droid's pipeline builds —"
    note "then signed with your key, checked the way the pipeline checks it, and put on the release"
  elif [ "$act" = build ]; then
    if build_release_apks; then
      known="$BUILT_SHA"; from="from the APK$([ "$K" -gt 1 ] && echo s) just built"
      upload_release_apks
    else
      note "carrying on without a fresh build — put your APK on the release yourself"
    fi
  fi

  # Binaries: is one app-level pattern and only knows %v and %c, so it cannot
  # name per-ABI release assets. fdroidserver takes `build.binary or
  # app.Binaries`, so with a split each entry carries its own binary: line.
  # F-Droid downloads these to compare its build with, so each is checked.
  if [ "$K" -gt 1 ]; then
    rdel top/Binaries
    for n in $(seq 1 "$K"); do
      abi="$(cat "$RT/b/$n/output" "$RT/b/$n/build" 2>/dev/null \
             | grep -oE 'armeabi-v7a|arm64-v8a|x86_64|x86' | sed -n 1p || true)"
      b="$BINARIES"; [ -n "$abi" ] && b="${b//%abi/$abi}"
      printf '%s\n' "$b" > "$RT/b/$n/binary"; echo s > "$RT/b/$n/binary.k"
      b="${b//%v/$VNAME}"; b="${b//%c/$(fv "$RT/b/$n/versionCode")}"
      [ -n "$url1" ] || url1="$b"
      if [ "$act" != build ]; then binary_there "$b"; fi
    done
    ok "each build entry points at its own APK on the release page"
  else
    rset top/Binaries s "$BINARIES"
    b="${BINARIES//%v/$VNAME}"; url1="${b//%c/$VCODE}"
    if [ "$act" != build ]; then binary_there "$url1"; fi
    for n in $(seq 1 "$K"); do rm -f "$RT/b/$n/binary" "$RT/b/$n/binary.k"; done
  fi

  # --- AllowedAPKSigningKeys: 64 hex characters. apksigner and keytool print
  # it in capitals or with colons, which F-Droid does not take: cleaned up
  # here. Anything else is asked again, and a wrong one is never remembered.
  if [ -z "$known" ]; then
    known="$(sigclean "$(sed -n 1p "$RD/top/AllowedAPKSigningKeys" 2>/dev/null || true)")"; from="the one in $BASE_LABEL"
    sigok "$known" || { known="$(sigclean "$(recall SIGNKEY)")"; from="your answer last time"; }
    sigok "$known" || known=""
  fi
  ask_signkey "$url1" "$known" "$from"
  SIGNKEY="$(sigclean "$SIGNKEY")"
  while ! sigok "$SIGNKEY"; do
    [ "$ASSUME_YES" = 1 ] && die "AllowedAPKSigningKeys has to be 64 hex characters"
    [ -z "$SIGNKEY" ] || warn "that is not a SHA-256 fingerprint: it is 64 hex characters (0-9, a-f)"
    note "apksigner verify --print-certs app.apk prints it, on its \"SHA-256 digest\" line"
    remember SIGNKEY ""
    ask SIGNKEY "AllowedAPKSigningKeys" ""
    SIGNKEY="$(sigclean "$SIGNKEY")"
  done
  remember SIGNKEY "$SIGNKEY"
  ok "AllowedAPKSigningKeys: $SIGNKEY"
  rset top/AllowedAPKSigningKeys l "$SIGNKEY"
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
# ychoose <rel> <scope> <default> req|opt <choice>… — a one-line field as a
# menu. Each choice is "value TAB what it means"; an empty value leaves the
# field out. A number picks one; anything else typed is taken as the value.
ychoose() {
  local rel="$1" scope="$2" def req="$4" name="${1##*/}" c v l i=1 n defn="" ch vals=()
  def="$(ymem "$rel" "$3")"; shift 4
  if [ "$ASSUME_YES" = 1 ]; then
    [ -z "$def" ] && [ "$req" = req ] && die "--yes: nothing to answer $name with — run once without --yes"
    [ -n "$def" ] && ok "$name: $def"
    ysave "$rel" s "$def"; return 0
  fi
  yhint "$scope" "$name" "$def"
  for c in "$@"; do
    v="${c%%$'\t'*}"; l="${c#*$'\t'}"
    if [ -z "$v" ]; then printf '     %d) %s\n' "$i" "$l"
    elif [ "${#v}" -le 24 ]; then printf '     %d) %s%s%s — %s\n' "$i" "$B" "$v" "$R" "$l"
    else printf '     %d) %s\n        %s%s%s\n' "$i" "$l" "$DIM" "$v" "$R"; fi
    vals+=("$v")
    if [ -z "$defn" ] && [ "$v" = "$def" ]; then defn="$i"; fi
    i=$((i + 1))
  done
  if [ -n "$def" ] && [ -z "$defn" ]; then
    printf '     %d) %s\n        %s%s%s\n' "$i" "keep the current one" "$DIM" "$def" "$R"
    vals+=("$def"); defn="$i"; i=$((i + 1))
  fi
  printf '     %d) %s\n' "$i" "type your own"
  n="$i"; defn="${defn:-1}"
  while :; do
    printf '   %s%s%s [%s]: ' "$B" "$name" "$R" "$defn" >&2
    readline ch; ch="$(trim "$ch")"; ch="${ch:-$defn}"
    case "$ch" in
      *[!0-9]*) v="$ch" ;;
      *) if [ "$ch" -ge 1 ] && [ "$ch" -lt "$n" ]; then v="${vals[$((ch - 1))]}"
         elif [ "$ch" = "$n" ]; then
           printf '   %s%s%s: ' "$B" "$name" "$R" >&2; readline v; v="$(trim "$v")"
         else warn "a number from 1 to $n"; continue; fi ;;
    esac
    [ "$v" = - ] && v=""
    if [ -z "$v" ]; then
      if [ "$req" = req ]; then warn "$name is needed"; continue; fi
      break
    fi
    ycheck "$scope" "$name" "$v" && break
  done
  ysave "$rel" s "$v"
}

ucm_tagpat() {  # a Tags pattern matching release tags like this one only
  case "$TAG" in
    v[0-9]*) printf '%s' '^v[0-9.]+$' ;;
    [0-9]*)  printf '%s' '^[0-9.]+$' ;;
    *)       printf '%s' '^v?[0-9.]+$' ;;
  esac
}
ucm_default() {  # what this repo suggests for UpdateCheckMode
  local other
  if [ "${MANIFESTS:-0}" -gt 20 ]; then printf 'None'; return 0; fi
  # tags that are not releases (beta-…, nightly) would be taken for one
  other="$(git -C "$REPO" tag -l 2>/dev/null | grep -cvE '^v?[0-9]+(\.[0-9]+)*$' || true)"
  if [ "${other:-0}" -gt 0 ]; then printf 'Tags %s' "$(ucm_tagpat)"; else printf 'Tags'; fi
}

# ucd_options — UpdateCheckData choices read off the repo, "value TAB what it means"
ucd_options() {
  local pub ref lit=""
  ref="$TAG"; git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 || ref=HEAD
  if [ -n "$FLUTTER_DIR" ]; then
    pub="pubspec.yaml"; [ "$FLUTTER_DIR" != "." ] && pub="$FLUTTER_DIR/pubspec.yaml"
    printf '%s|version:\\s.+\\+(\\d+)|.|version:\\s(.+)\\+\t%s\n' "$pub" \
      "both from the version: line of $pub (now $VNAME+$VCODE) — what Flutter apps use"
  fi
  if [ -z "$FLUTTER_DIR" ] && [ "$(gval versionCode)" = "$VCODE" ]; then
    lit=1
    printf '\t%s\n' "none — F-Droid reads them from $GRADLE_REL, where they are plain values"
  fi
  # another file that holds them: gradle.properties, version.properties, a catalog…
  python3 - "$REPO" "$ref" "$VNAME" "$VCODE" "${lit:+$GRADLE_REL}" <<'PYUCD' 2>/dev/null || true
import re, subprocess, sys
repo, ref, vname, vcode, skip = sys.argv[1:6]


def git(*a):
    return subprocess.run(['git', '-C', repo] + list(a), capture_output=True).stdout.decode('utf-8', 'replace')


WANT = re.compile(r'(^|/)(gradle\.properties|[\w.-]*version[\w.-]*\.(properties|toml|json|txt|gradle|kts|ya?ml)'
                  r'|build\.gradle(\.kts)?)$', re.I)
files = [f for f in git('ls-tree', '-r', '--name-only', ref).split('\n')
         if f and f != skip and WANT.search(f) and 'node_modules/' not in f][:300]
KEYC = r'[\w.-]*(?:version_?code|ver_?code|v_?code|build_?number)[\w.-]*'
KEYN = r'[\w.-]*(?:version_?name|ver_?name|v_?name)[\w.-]*'


def hits(text, key, value):
    pat = re.compile(r'^[ \t]*(?:def |val |var |const val )?["\']?(' + key + r')["\']?[ \t]*([=:])[ \t]*(["\']?)'
                     + re.escape(value) + r'(?![\w.])', re.M | re.I)
    return [m.groups() for m in pat.finditer(text)]


def rx(key, sep, q, cap):
    return re.escape(key) + r'\s*' + re.escape(sep) + r'\s*' + re.escape(q) + cap


texts = {f: git('show', '%s:%s' % (ref, f)) for f in files}
seen = set()
for f in files:
    for key, sep, q in hits(texts[f], KEYC, vcode):
        for g in [f] + [x for x in files if x != f]:
            h = hits(texts[g], KEYN, vname)
            if not h:
                continue
            k2, s2, q2 = h[0]
            cap = '([^%s]+)' % q2 if q2 else r'(\S+)'
            val = '%s|%s|%s|%s' % (f, rx(key, sep, q, r'(\d+)'), '.' if g == f else g, rx(k2, s2, q2, cap))
            if val not in seen:
                seen.add(val)
                print('%s\t%s' % (val, 'both from %s' % f if g == f
                                  else 'versionCode from %s, versionName from %s' % (f, g)))
            break
PYUCD
  if [ -z "$lit" ]; then
    printf '\t%s\n' "none — F-Droid reads $GRADLE_REL, which works only where versionCode is a plain number there"
  fi
}

ask_ucd() {
  local cur="" opts=() line
  case "$(fv "$RR/top/UpdateCheckMode")" in
    None|Static)
      # nothing reads it without update checks
      if [ ! -f "$RD/top/UpdateCheckData" ]; then rdel top/UpdateCheckData; return 0; fi ;;
  esac
  printf '\n'
  say "${B}UpdateCheckData${R} — where the check reads a new tag's version numbers."
  say "Without it, F-Droid looks for versionCode and versionName in $GRADLE_REL, which"
  say "works only when they are written there as plain values. Four parts, joined by |:"
  note "  the file with the versionCode | a pattern that finds it |"
  note "  the file with the versionName (. means the same file) | a pattern that finds it"
  if [ -f "$RD/top/UpdateCheckData" ]; then cur="$(fv "$RD/top/UpdateCheckData")"
  elif [ -f "$RG/top/UpdateCheckData" ]; then cur="$(fv "$RG/top/UpdateCheckData")"; fi
  while IFS= read -r line; do
    if [ -n "$line" ]; then opts+=("$line"); fi
  done < <(ucd_options)
  ychoose top/UpdateCheckData top "$cur" opt ${opts[@]+"${opts[@]}"}
}

ask_update_checks() {
  local ucm aum ver k src
  printf '\n'; say "${B}Updates${R} — how F-Droid notices your next versions"
  say "F-Droid's bot looks at your repo about once a day. These lines tell it where to"
  say "find a new version, and whether to add that version to the recipe by itself —"
  say "then a new release needs nothing from you but a pushed tag."
  printf '\n'; say "${B}UpdateCheckMode${R} — where it looks for a new version:"
  ucm="$(dflt UpdateCheckMode "")"; [ -n "$ucm" ] || ucm="$(ucm_default)"
  ychoose top/UpdateCheckMode top "$ucm" req \
    "Tags"$'\t'"the newest git tag — right when every release is tagged (yours: $TAG)" \
    "Tags $(ucm_tagpat)"$'\t'"only tags that look like a release, so beta-…, nightly-… tags are passed over" \
    "RepoManifest"$'\t'"the version in your default branch's build files — for repos that tag nothing" \
    "None"$'\t'"no checking — you send every update yourself"
  ucm="$(fv "$RR/top/UpdateCheckMode")"
  printf '\n'; say "${B}AutoUpdateMode${R} — what it does when it finds one:"
  aum="$(dflt AutoUpdateMode "")"
  case "$ucm" in
    None|Static)
      ychoose top/AutoUpdateMode top "${aum:-None}" req \
        "None"$'\t'"nothing — without update checks there is nothing to act on" ;;
    Tags*)
      ychoose top/AutoUpdateMode top "${aum:-Version}" req \
        "Version"$'\t'"adds the new tag's version to the recipe and builds it — no merge request from you" \
        "None"$'\t'"only notes it; you send a merge request for each update" ;;
    *)
      ver="Version $(tag_pattern)"
      ychoose top/AutoUpdateMode top "${aum:-$ver}" req \
        "$ver"$'\t'"adds the new version and builds the tag $(tag_pattern) names (%v: the version) — no merge request from you" \
        "None"$'\t'"only notes it; you send a merge request for each update" ;;
  esac
  case "$TAG" in
    "$VNAME"|"v$VNAME") ;;
    *) note "your tag '$TAG' is neither '$VNAME' nor 'v$VNAME' — fine with Tags, which builds the tag it"
       note "finds; a pattern has to say where the version goes in your tags" ;;
  esac
  for k in UpdateCheckIgnore VercodeOperation UpdateCheckName; do
    src=""
    if [ -f "$RD/top/$k" ]; then src="$RD/top/$k"; elif [ -f "$RG/top/$k" ]; then src="$RG/top/$k"; fi
    if [ -n "$src" ]; then printf '\n'; yfield "top/$k" top "$(akind top "$k" "$src")" "$(fv "$src")"; fi
  done
  ask_ucd
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

# ================================================================ 4. checks
# The checks fdroiddata's pipeline runs on a merge request, run here first with
# the same fdroidserver, so the pipeline finds nothing new: fdroid lint, fdroid
# rewritemeta, schema validation, git redirect, tools check scripts and
# checkupdates — and fdroid build, where this machine can run it and you ask.
# Whatever cannot run here is said so, and left to the pipeline.
step "4/5  Checks — what fdroiddata's pipeline runs, run here first"

# The pipeline's "tools check scripts" job: two of its scripts concern one
# recipe. A Summary: line fails it (make-summary-translatable.py) — F-Droid
# takes the summary from fastlane — and so does a signing-key alias shared with
# another app, since F-Droid derives the alias from the application id.
summary_check() {
  local f="$FDROIDDATA/metadata/$APPID.yml" ka="" bad=""
  if grep -q '^Summary:' "$f"; then
    warn "the recipe has a Summary: line — fdroiddata's pipeline fails on it"
    note "F-Droid shows short_description.txt from your repo's fastlane instead"
    if confirm "Take the Summary: line out?" y; then
      python3 - "$f" <<'PYSUM'
import sys
p = sys.argv[1]
out, skip = [], False
for l in open(p, encoding='utf-8').read().split('\n'):
    if l.startswith('Summary:'):
        skip = True
        continue
    if skip and l.startswith((' ', '\t')):
        continue
    skip = False
    if not l.strip() and out and not out[-1].strip():
        continue
    out.append(l)
open(p, 'w', encoding='utf-8').write('\n'.join(out))
PYSUM
      remember "$(mkey top/Summary)" -
      ok "took it out"
    else
      bad="a Summary: line"
    fi
  fi
  if [ "$IS_UPDATE" = 0 ]; then
    ka="$(cd "$FDROIDDATA" && python3 - "$APPID" <<'PYKA' 2>/dev/null || true
import glob, hashlib, os, sys
alias = lambda s: hashlib.md5(s.encode()).hexdigest()[:8]
me = sys.argv[1]
for f in sorted(glob.glob('metadata/*.yml')):
    other = os.path.basename(f)[:-4]
    if other != me and alias(other) == alias(me):
        print(other)
PYKA
)"
    if [ -n "$ka" ]; then
      warn "$APPID's signing-key alias is the same as $ka's — the pipeline stops on it"
      note "F-Droid derives each app's key alias from its id: only another application id avoids it"
      bad="${bad:+$bad, }a key alias shared with $ka"
    fi
  fi
  if [ -n "$bad" ]; then chk "tools check scripts" "failed: $bad"; VALID_FAIL="${VALID_FAIL:-} tools"
  else chk "tools check scripts" passed; fi
}

# fdroiddata's pipeline validates every changed recipe against
# schemas/metadata.json before anything else. lint does not, so a recipe lint
# is happy with can still be turned away. The same validator where there is
# one — check-jsonschema, also run through uvx, pipx or nix when it is not
# installed — else the python one.
cat > "$WORK/schema.py" <<'PYSCHEMA'
import json, sys, jsonschema, yaml
schema = json.load(open(sys.argv[1]))
doc = yaml.safe_load(open(sys.argv[2]))
errors = sorted(jsonschema.Draft7Validator(schema).iter_errors(doc), key=lambda e: list(e.path))
for e in errors:
    print("   $." + ".".join(str(p) for p in e.path) + ": " + e.message)
sys.exit(1 if errors else 0)
PYSCHEMA
printf 'import jsonschema, yaml\n' > "$WORK/has-jsonschema.py"
schema_check() {
  local rel="metadata/$APPID.yml" run py t=""
  if [ ! -f "$FDROIDDATA/schemas/metadata.json" ]; then
    chk "schema validation" "skipped: no schemas/metadata.json in the clone"; return 0
  fi
  have timeout && t="timeout 600"
  for run in check-jsonschema "uvx check-jsonschema" "pipx run check-jsonschema" \
             "nix --extra-experimental-features nix-command --extra-experimental-features flakes run nixpkgs#check-jsonschema --"; do
    have "${run%% *}" || continue
    if [ "${run%% *}" = check-jsonschema ]; then say "schema validation — check-jsonschema"
    else
      say "schema validation — check-jsonschema, through ${run%% *}"
      note "(the first time, ${run%% *} fetches it: a minute or two)"
    fi
    # shellcheck disable=SC2086
    if ( cd "$FDROIDDATA" && $t $run --schemafile schemas/metadata.json "$rel" ) > "$WORK/schema.log" 2>&1; then
      chk "schema validation" passed; return 0
    fi
    if grep -qiE 'validation errors|failed validating|is not valid' "$WORK/schema.log"; then
      sed 's/^/     /' "$WORK/schema.log" | tail -n 20
      VALID_FAIL="$VALID_FAIL schema"; chk "schema validation" "failed: see above"; return 0
    fi
    note "it did not run — trying another way"
  done
  for py in "$FDROID_PY" python3; do
    [ -n "$py" ] || continue
    "$py" "$WORK/has-jsonschema.py" >/dev/null 2>&1 || continue
    say "schema validation — python jsonschema"
    if "$py" "$WORK/schema.py" "$FDROIDDATA/schemas/metadata.json" "$FDROIDDATA/$rel" > "$WORK/schema.log" 2>&1; then
      chk "schema validation" passed
    else
      sed 's/^/     /' "$WORK/schema.log"
      VALID_FAIL="$VALID_FAIL schema"; chk "schema validation" "failed: see above"
    fi
    return 0
  done
  note "no JSON schema validator here — pipx install check-jsonschema adds one"
  chk "schema validation" "skipped: no validator here — the pipeline runs it"
}

# The pipeline's "git redirect" job: Repo: has to be the address git lands on,
# not one that redirects there (a renamed or moved repo). Its own tool fixes
# the line; what it changes is kept.
redirect_check() {
  local f="$FDROIDDATA/metadata/$APPID.yml" before new had=0
  if [ ! -f "$FDROIDDATA/tools/rewrite-git-redirects.py" ]; then
    chk "git redirect" "skipped: no tools/rewrite-git-redirects.py in the clone"; return 0
  fi
  say "git redirect — Repo: is where git lands, not an address that redirects"
  [ -e "$FDROIDDATA/codequality.json" ] && had=1
  before="$(cksum < "$f")"
  if fpy tools/rewrite-git-redirects.py "$APPID" > "$WORK/redirect.log" 2>&1; then
    if [ "$before" != "$(cksum < "$f")" ]; then
      new="$(sed -n 's/^Repo:[[:space:]]*//p' "$f" | sed -n 1p)"
      warn "Repo: redirected — it is now the address git lands on: $new"
      remember "$(mkey top/Repo)" "$new"
      chk "git redirect" "passed: Repo: is now $new"
    else
      chk "git redirect" passed
    fi
  else
    tail -n 5 "$WORK/redirect.log" | sed 's/^/     /'
    chk "git redirect" "skipped: the tool did not run here — the pipeline runs it"
  fi
  [ "$had" = 1 ] || rm -f "$FDROIDDATA/codequality.json"
  # it also looks at the srclibs the build uses: not this merge request's to change
  git -C "$FDROIDDATA" checkout -q -- srclibs 2>/dev/null || true
}

# The pipeline's "checkupdates" job runs `fdroid checkupdates --auto` on the
# recipe and fails on any change it makes: AutoName read off the app's
# manifest, a newer tag than the one sent… Run here the same way, whatever it
# changes is kept, so the pipeline finds nothing left to change. It clones the
# app, so give it a moment. Three traps, none of them yours:
#  * fdroiddata's config.yml is F-Droid's production config, with serverwebroot
#    and the signing keys as {env: …} placeholders their pipeline fills in;
#    here checkupdates logs an ERROR about the blank serverwebroot while doing
#    its work perfectly well. A throwaway one keeps it quiet.
#  * with -v it exits non-zero if any ERROR was logged, which turns that
#    harmless complaint into a failure. The log is read instead.
#  * without --allow-dirty it refuses to run while the clone holds a change —
#    and the recipe is one, uncommitted until stage 5.
checkupdates_check() {
  local f="$FDROIDDATA/metadata/$APPID.yml" errs cvb cva
  say "fdroid checkupdates --auto $APPID — what the pipeline's update check would change"
  note "it clones your app: a minute or so"
  cp "$f" "$WORK/pre-checkupdates.yml"
  # rsync will not create nested folders, and it deploys into repo/status/
  mkdir -p "$WORK/deploy-sink/repo/status"
  if serverwebroot="$WORK/deploy-sink" \
     frun checkupdates --auto --allow-dirty "$APPID" > "$WORK/checkupdates.log" 2>&1; then
    # it writes the file with the local fdroid's layout: put the pipeline's back
    rcp ciwrap "$f" >/dev/null || true
    errs="$(grep -c 'ERROR' "$WORK/checkupdates.log" || true)"
    if [ "${errs:-0}" -gt 0 ]; then
      note "it logged $errs error(s) — usually fdroiddata's config.yml wanting F-Droid's own"
      note "deploy setup, which only their pipeline has:"
      grep 'ERROR' "$WORK/checkupdates.log" | head -3 | sed 's/^/       /'
    fi
    if cmp -s "$f" "$WORK/pre-checkupdates.yml"; then
      chk checkupdates "passed: nothing to change"
    else
      note "it changed the recipe the way the pipeline would — kept, so the pipeline finds nothing:"
      diff -u "$WORK/pre-checkupdates.yml" "$f" | sed -n 's/^\([+-][^+-]\)/     \1/p' || true
      cvb="$(sed -n 's/^CurrentVersionCode:[[:space:]]*//p' "$WORK/pre-checkupdates.yml")"
      cva="$(sed -n 's/^CurrentVersionCode:[[:space:]]*//p' "$f")"
      if [ "$cvb" != "$cva" ]; then
        warn "it found a newer version than $VNAME tagged in your repo, and added it"
      fi
      chk checkupdates "passed: it filled in what the pipeline expects"
    fi
  else
    warn "checkupdates could not run:"
    tail -n 5 "$WORK/checkupdates.log" | sed 's/^/     /'
    chk checkupdates "skipped: it could not run here — the pipeline runs it"
  fi
}

has_binaries() { ls "$RR"/b/*/binary >/dev/null 2>&1 || [ -s "$RR/top/Binaries" ]; }

# entry_ref <n> — "versionName TAB versionCode TAB the address of your APK" for build entry n
entry_ref() {
  local vn vc u
  vn="$(fv "$RR/b/$1/versionName")"; vc="$(fv "$RR/b/$1/versionCode")"
  u="$(fv "$RR/b/$1/binary")"; [ -n "$u" ] || u="$(fv "$RR/top/Binaries")"
  u="${u//%v/$vn}"; u="${u//%c/$vc}"
  printf '%s\t%s\t%s\n' "$vn" "$vc" "$u"
}
ver_tag() {  # ver_tag <versionName> — the release tag of that version, named like this one's
  local p; p="$(tag_pattern)"
  printf '%s' "${p//%v/$1}"
}

# The pipeline's "fdroid build" job, run here the same way: fdroid build
# --test, one build entry at a time. With your own signed APKs it is the check
# that decides — F-Droid builds each version from source, downloads your APK
# from its binary: address, copies your signature onto its own build and ships
# your APK only if that verifies. When your APK is missing, or is signed in a
# way that cannot be carried over, it is made from F-Droid's very build: signed
# with your key keeping the layout (see sign_apk), checked the way the pipeline
# checks it, kept in your project's builds/ folder and put on the release.
build_entry() {  # build_entry <versionCode> <log> — true when fdroid build passed
  mkdir -p "$WORK/deploy-sink/repo/status"
  rm -f "$FDROIDDATA/tmp/${APPID}_$1.apk"
  serverwebroot="$WORK/deploy-sink" frun build --test --no-tarball --stop -v "$APPID:$1" > "$2" 2>&1 || true
  grep -q 'Successfully built' "$2" && ! grep -qE '[0-9]+ builds? failed|Could not build app' "$2"
}
local_builds() {
  local n vn vc url log unsigned failed=0 made=0 total=0 why
  for n in $(seq 1 "$K"); do
    IFS=$'\t' read -r vn vc url < <(entry_ref "$n")
    total=$((total + 1)); log="$WORK/build-$vc.log"
    if has_binaries; then say "fdroid build $APPID:$vc ($vn) — as the pipeline builds it, then compared with your APK"
    else say "fdroid build $APPID:$vc ($vn) — as the pipeline builds it"; fi
    note "a few minutes; its output goes to $log"
    if build_entry "$vc" "$log"; then
      if has_binaries; then ok "$vn: F-Droid's build and your APK at ${url##*/} are the same APK"
      else ok "$vn builds"; fi
      continue
    fi
    unsigned="$FDROIDDATA/tmp/${APPID}_$vc.apk"
    why=""
    if grep -q 'Downloading Binaries from .* failed' "$log"; then why=missing
    elif grep -q 'compared built binary to supplied reference binary but failed' "$log"; then why=differs
    elif grep -q 'supplied reference binary signed with' "$log"; then why=key
    fi
    if [ -z "$why" ] || [ ! -f "$unsigned" ]; then
      warn "$vn did not build — F-Droid's pipeline would fail the same way:"
      grep -E 'ERROR|FAILURE|What went wrong|error:' "$log" | head -8 | sed 's/^/       /'
      note "the whole log: $log"; KEEP_WORK=1
      failed=$((failed + 1)); continue
    fi
    case "$why" in
      missing) warn "$vn builds, but your APK is not at $url" ;;
      differs) warn "$vn builds, but your APK at ${url##*/} is not the APK F-Droid builds"
               note "most often it was re-aligned (zipalign, or apksigner's default) or carries the old v1"
               note "signature: either way fdroidserver cannot carry its signature over to its own build" ;;
      key)     warn "$vn builds, but ${url##*/} is signed with another key than AllowedAPKSigningKeys" ;;
    esac
    if ! make_reference "$vn" "$vc" "$url" "$unsigned"; then failed=$((failed + 1)); continue; fi
    made=$((made + 1))
  done
  if [ "$failed" -gt 0 ]; then chk "fdroid build" "failed: $failed of $total version(s), listed above"
  elif [ "$made" -gt 0 ]; then chk "fdroid build" "passed: $made APK(s) made from F-Droid's own build and checked"
  else chk "fdroid build" "passed: $total version(s) built$(has_binaries && echo ', your APKs match')"; fi
}

declare -A MADE_REF=()   # address -> the APK made for it here this run
# make_reference <versionName> <versionCode> <address> <F-Droid's unsigned build>
make_reference() {
  local vn="$1" vc="$2" url="$3" unsigned="$4" name tag bdir out code
  name="${url##*/}"; tag="$(ver_tag "$vn")"
  if ! confirm "Make $name from F-Droid's own build — signed with your key, checked like the pipeline checks it?" y; then
    return 1
  fi
  bdir="$(app_builds_dir)"; [ -n "$bdir" ] || { bdir="$WORK/builds"; KEEP_WORK=1; }
  out="$bdir/$name"
  sign_apk "$unsigned" "$out" || return 1
  if ! ref_matches "$out" "$unsigned"; then
    warn "fdroidserver does not accept even this one:"; sed 's/^/       /' "$WORK/verify-ref.log" | head -6
    return 1
  fi
  local want got
  got="$(apk_cert "$out")"; want="$(sigclean "$(sed -n 1p "$RR/top/AllowedAPKSigningKeys" 2>/dev/null || true)")"
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    warn "${SIGN_KS##*/} is not the key the recipe allows: it signs with $got,"
    warn "AllowedAPKSigningKeys says $want — F-Droid would turn the APK away"
    rm -f "$out"; SIGN_KS=""; SIGN_PW=""
    return 1
  fi
  MADE_REF["$url"]="$out"
  ok "$name: signed, and fdroidserver accepts it as F-Droid's build — in ${bdir/#$HOME/~}"
  case "$url" in
    "$WEB_GUESS/releases/download/$tag/"*) ;;
    *) note "put it at $url yourself — it is in ${bdir/#$HOME/~}"; return 0 ;;
  esac
  if [ "$DRYRUN" = 1 ]; then warn "dry run — would put it on release $tag"; return 0; fi
  if [ "$FORGE_CLI" != gh ]; then note "put it on release $tag yourself — it is in ${bdir/#$HOME/~}"; return 0; fi
  if ! ( cd "$REPO" && gh release view "$tag" >/dev/null 2>&1 ); then
    go "Release $tag is not on GitHub — publish it, with $name?" || return 0
    local notes="$WORK/notes-$vc.md"
    if [ -f "${FL_BASE:-/nonexistent}/changelogs/$vc.txt" ]; then cp "$FL_BASE/changelogs/$vc.txt" "$notes"; else printf '%s\n' "$tag" > "$notes"; fi
    ( cd "$REPO" && gh release create "$tag" --verify-tag --title "$tag" --notes-file "$notes" "$out" ) >/dev/null 2>&1 \
      || { warn "gh could not publish release $tag"; return 1; }
    ok "release $tag published, with $name"; tlog "release $tag published with $name"
  else
    if [ "$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)" = 200 ]; then
      go "Replace $name on release $tag with this one? (same key; only the packing differs)" || return 0
    fi
    ( cd "$REPO" && gh release upload "$tag" "$out" --clobber ) >/dev/null 2>&1 \
      || { warn "gh could not upload $name"; return 1; }
    ok "uploaded $name to release $tag"; tlog "uploaded $name to release $tag"
  fi
  # what F-Droid will download is what was checked
  code="$(curl -sL --max-time 300 -o "$WORK/check-$vc.apk" -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [ "$code" = 200 ] && cmp -s "$WORK/check-$vc.apk" "$out"; then ok "the release serves exactly that APK"
  else warn "the release did not serve the same file back yet (HTTP ${code:-none}) — check $url"; fi
}

# The pipeline's "check apk" job, for reproducible builds: it scans the APK
# F-Droid would ship — yours, downloaded from the binary: address — with fdroid
# scanner (non-free libraries, trackers, extra signing blocks, debuggable or
# test-only builds), and turns away one signed with Android's debug key. When
# F-Droid signs, it scans what it builds itself: nothing to do here.
apk_scan_check() {
  local n u vc f code i=0 bad=0 away=0 urls=()
  for n in $(seq 1 "$K"); do
    u="$(fv "$RR/b/$n/binary")"; [ -n "$u" ] || u="$(fv "$RR/top/Binaries")"
    [ -n "$u" ] || continue
    vc="$(fv "$RR/b/$n/versionCode")"; u="${u//%v/$(fv "$RR/b/$n/versionName")}"; urls+=("${u//%c/$vc}")
  done
  [ "${#urls[@]}" -gt 0 ] || return 0
  if [ "$FD_SCANNER_OK" = 0 ]; then
    chk "check apk" "skipped: fdroidserver's scanner does not load here — the pipeline scans them"; return 0
  fi
  say "check apk — your ${#urls[@]} release APK(s), scanned the way the pipeline scans them"
  for u in "${urls[@]}"; do
    i=$((i + 1)); f="$WORK/scan-$i-${u##*/}"
    code="$(curl -sL --max-time 300 -o "$f" -w '%{http_code}' "$u" 2>/dev/null || true)"
    # made here in a dry run, not uploaded yet: scan the very file that will be
    if [ "$code" != 200 ] && [ -n "${MADE_REF[$u]:-}" ]; then
      cp "${MADE_REF[$u]}" "$f"; code=200; note "${u##*/}: the APK made here (it goes on the release when you send it)"
    fi
    if [ "$code" != 200 ]; then
      if [ "$code" = 404 ]; then
        warn "${u##*/} is not on the release yet — F-Droid downloads it from $u"; bad=$((bad + 1))
      else
        note "could not download $u (HTTP ${code:-none}) — offline?"; away=$((away + 1))
      fi
      continue
    fi
    if frun scanner --verbose --exit-code "$f" > "$WORK/scan-$i.log" 2>&1; then
      ok "${u##*/}: nothing found"
    else
      warn "${u##*/}: the scanner found problems:"
      grep -E 'ERROR|CRITICAL|Problem|Found class' "$WORK/scan-$i.log" | sed 's/^[0-9-]* [0-9:,]* //' \
        | sort -u | head -8 | sed 's/^/       /'
      bad=$((bad + 1))
    fi
    if apk_is_debug "$f"; then warn "${u##*/} is signed with Android's debug key"; bad=$((bad + 1)); fi
  done
  if [ "$bad" -gt 0 ]; then chk "check apk" "failed: $bad problem(s), listed above"
  elif [ "$away" -gt 0 ]; then chk "check apk" "skipped: the APKs could not be downloaded here — the pipeline scans them"
  else chk "check apk" "passed: ${#urls[@]} APK(s) scanned"; fi
}

# The pipeline's "check source code" job: fdroiddata's own tools/check-fastlane.py,
# when the library it needs is here. Otherwise the listing was checked in the
# Pitfall check, the same way.
fastlane_tool_check() {
  local lvl msg crit=0
  [ -f "$FDROIDDATA/tools/check-fastlane.py" ] || return 0
  printf 'import markdown_it\n' > "$WORK/has-markdown.py"
  "$FDROID_PY" "$WORK/has-markdown.py" >/dev/null 2>&1 || return 0
  say "check source code — the listing, as the reviewers will see it"
  if ! fpy tools/check-fastlane.py "$APPID" > "$WORK/fastlane.json" 2> "$WORK/fastlane.log"; then
    note "it did not run — the listing was checked above, in the Pitfall check"; return 0
  fi
  while IFS=$'\t' read -r lvl msg; do
    case "$lvl" in
      critical) warn "$msg"; crit=$((crit + 1)) ;;
      major)    warn "$msg" ;;
      *)        note "$msg" ;;
    esac
  done < <(python3 -c '
import json, sys
for r in json.load(open(sys.argv[1])):
    print("%s\t%s" % (r.get("severity", ""), r.get("description", "")))
' "$WORK/fastlane.json" 2>/dev/null || true)
  if [ "$crit" -gt 0 ]; then chk "check source code (the listing)" "failed: $crit thing(s) missing, listed above"
  else chk "check source code (the listing)" passed; fi
}

if [ "$RUNNER" = none ]; then
  VALID_FAIL=""
  summary_check
  note "fdroidserver does not run here, so these are left to the merge request's pipeline"
  for c in "fdroid lint" "fdroid rewritemeta" "schema validation" "git redirect" checkupdates "fdroid build"; do
    chk "$c" "skipped: left to the pipeline"
  done
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

  summary_check

  # readmeta takes no app argument: it parses every metadata/*.yml in the
  # clone, so only a complaint that names this app counts.
  say "fdroid readmeta — the recipes in fdroiddata parse"
  if frun readmeta > "$WORK/readmeta.log" 2>&1; then
    chk "fdroid readmeta" passed
  else
    sed 's/^/     /' "$WORK/readmeta.log" | tail -n 20
    if grep -Fq "$APPID" "$WORK/readmeta.log"; then
      VALID_FAIL="$VALID_FAIL readmeta"; chk "fdroid readmeta" "failed: it cannot read metadata/$APPID.yml"
    else
      RM_OTHER="$(grep -oE ' in [A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+' "$WORK/readmeta.log" | sed -n '1s/ in //p' || true)"
      if [ -n "$RM_OTHER" ] && [ -f "$FDROIDDATA/metadata/$RM_OTHER.yml" ] \
         && ! git -C "$FDROIDDATA" ls-files --error-unmatch "metadata/$RM_OTHER.yml" >/dev/null 2>&1; then
        note "it is metadata/$RM_OTHER.yml, left untracked in your clone (an earlier run?) — not part of this merge request"
        note "delete it when you no longer need it: rm $FDROIDDATA/metadata/$RM_OTHER.yml"
      else
        note "another app's recipe trips it, not $APPID — nothing for you to fix"
      fi
      chk "fdroid readmeta" "passed: (another app's recipe trips it, not yours)"
    fi
  fi

  say "fdroid rewritemeta $APPID — laid out the way fdroiddata wants it"
  RW_BEFORE="$(cksum < "$FDROIDDATA/metadata/$APPID.yml")"
  if frun rewritemeta "$APPID" > "$WORK/rewritemeta.log" 2>&1; then
    # the pipeline's rewritemeta (Debian's ruamel.yaml 0.18) gives a word longer
    # than a line a line of its own; a newer local one does not, and the
    # pipeline would then fail on the difference
    rcp ciwrap "$FDROIDDATA/metadata/$APPID.yml" >/dev/null || true
    if [ "$RW_BEFORE" != "$(cksum < "$FDROIDDATA/metadata/$APPID.yml")" ]; then
      chk "fdroid rewritemeta" "passed: laid out the way the pipeline wants it now"
    else
      chk "fdroid rewritemeta" passed
    fi
  else
    sed 's/^/     /' "$WORK/rewritemeta.log" | tail -n 20
    VALID_FAIL="$VALID_FAIL rewritemeta"; chk "fdroid rewritemeta" "failed: see above"
  fi

  say "fdroid lint $APPID"
  if frun lint "$APPID" > "$WORK/lint.log" 2>&1; then
    chk "fdroid lint" passed
    sed 's/^/     /' "$WORK/lint.log" | head -n 10
  else
    sed 's/^/     /' "$WORK/lint.log" | tail -n 25
    VALID_FAIL="$VALID_FAIL lint"; chk "fdroid lint" "failed: see above"
  fi

  schema_check
  redirect_check
  checkupdates_check

  if [ -n "$VALID_FAIL" ]; then
    warn "failed:$VALID_FAIL — fdroiddata's pipeline would stop on this"
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
        *)    if edit_file "$FDROIDDATA/metadata/$APPID.yml"; then VALIDATE_AGAIN=1; fi ;;
      esac
    fi
  fi
  done

  fastlane_tool_check

  # The full build is the best predictor of acceptance, but slow (the Android
  # SDK, the whole toolchain), and outside the loop above: nobody wants it
  # repeated on every edit. Here it runs without --on-server, so the recipe's
  # sudo: lines are skipped (fdroidserver never runs them outside its build
  # server): a recipe that needs them can fail here and pass in the pipeline.
  if [ "$FD_SCANNER_OK" = 0 ]; then
    chk "fdroid build" "skipped: fdroidserver's scanner does not load here — the pipeline builds it"
  elif [ -z "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]; then
    chk "fdroid build" "skipped: no Android SDK here (ANDROID_HOME) — the pipeline builds it"
  elif [ "$RUN_BUILD" = 1 ] || [ "${REF_BUILD:-0}" = 1 ] || {
         if has_binaries; then
           note "with your own signed APKs, the build is the check that decides: F-Droid builds each"
           note "version and ships your APK only if it is the same — a few minutes per version"
           confirm "Build them here the way the pipeline does, and check your APKs against them?" y
         else
           [ "$ASSUME_YES" = 0 ] \
             && note "the full build takes 10 minutes to an hour; sudo: lines are skipped outside F-Droid's build server" \
             && confirm "Run it here too (fdroid build)?" n
         fi; }; then
    local_builds
  else
    chk "fdroid build" "skipped: not run this time (--build runs it here) — the pipeline builds it"
  fi
  apk_scan_check
fi

# --- how it all went, before anything leaves this machine
step "Checks — how it went"
chk_summary
CHK_FAILED="$(chk_with failed)"
CHK_WARNED="$(chk_with warn)"
printf '\n'
if [ -n "$CHK_FAILED" ]; then
  warn "${B}not ready yet${R}${YLW}: fix $CHK_FAILED first — the pipeline or the reviewers would ask for it"
elif [ -n "$CHK_WARNED" ]; then
  ok "every check the pipeline runs passed"
  warn "look at these before sending it — reviewers usually ask: $CHK_WARNED"
else
  ok "${B}Everything is finished, and every check passed — ready for the merge request.${R}"
fi
if [ -n "$(chk_with skipped)" ]; then note "left to the pipeline: $(chk_with skipped)"; fi

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
  warn "dry run — nothing was committed, pushed or opened"
  note "metadata/$APPID.yml is in $FDROIDDATA (branch $BRANCH), as it would be sent"
  if [ -z "$CHK_FAILED" ]; then ok "run it again without --dry-run to send it"; fi
  exit 0
fi
PUSH_DEF=y
if [ -n "${CHK_FAILED:-}" ]; then
  warn "the checks above failed on: $CHK_FAILED — the pipeline will fail the same way"
  PUSH_DEF=n
fi
if { [ "$ASSUME_YES" = 1 ] && [ "$PUSH_DEF" = n ]; } || ! confirm "Commit and push to $FORKURL ($BRANCH)?" "$PUSH_DEF"; then
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
PUSHED_SHA="$(git -C "$FDROIDDATA" rev-parse HEAD)"
tlog "pushed $VNAME ($VCODES) to $BRANCH on your fork"
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
  tlog "merge request !${MR_URL##*/} updated with $VNAME"
  note "CI re-runs on the new commit"
  if [ -n "$TASK_FILE" ]; then
    mr_description > "${TASK_FILE%.conf}.mr.md" 2>/dev/null || true
    sync_mr_description "$MR_URL" "${TASK_FILE%.conf}.mr.md"
  fi
  # a draft while the new pipeline runs, so nobody reviews a half-checked change
  mr_load "${MR_URL##*/}"
  if [ "${M_DRAFT:-0}" = 0 ] && glab_ok && go "Make it a draft until the new pipeline passes?"; then
    mr_mark draft
  fi
elif glab_ready && go "Open the merge request on fdroid/fdroiddata (as a draft until its pipeline passes)?"; then
  mr_description > "$WORK/mr.md"
  MR_OUT="$(glab_fd mr create -R fdroid/fdroiddata -H "$(fork_path "$FORKURL")" \
              -s "$BRANCH" -b "$UPBRANCH" -t "$COMMITMSG" \
              -d "$(cat "$WORK/mr.md")" --allow-collaboration --draft -y 2>&1 || true)"
  MR_URL="$(printf '%s\n' "$MR_OUT" | grep -Eo 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1 || true)"
  if [ -n "$MR_URL" ]; then
    ok "merge request, a draft for now: $MR_URL"
    remember ST_MR "$MR_URL"; remember ST_STATUS draft
    tlog "merge request !${MR_URL##*/} opened as a draft ($VNAME)"
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
  note "tick \"Mark as draft\" — it comes out of draft once its pipeline passes"
fi
[ -n "$RFP_REF" ] && note "it links the RFP issue ($RFP_REF)"

# --- the pipeline, then the reviewers. A draft is not reviewed: it comes out
# of draft once fdroiddata's pipeline has passed on this very commit.
if [ -n "$MR_URL" ]; then
  if go "Watch the pipeline now and mark the merge request ready once it passes?"; then
    watch_pipeline "$PUSHED_SHA" || true
  fi
fi

# --- where it stands now
printf '\n'
case "$(recall ST_STATUS)" in
  review)
    ok "${B}All done: every check passed, and merge request !${MR_URL##*/} is ready for review.${R}"
    note "F-Droid's reviewers take it from here; their comments: fdroid-submit.sh --status $APPID" ;;
  draft|submitted)
    if [ "$(recall ST_PIPE)" = failed ]; then
      warn "merge request !${MR_URL##*/} is open, but its pipeline failed — the failed jobs are above"
      note "fix it and run this again: it pushes to the same merge request"
    else
      ok "${B}Sent: merge request !${MR_URL##*/} is open$([ "$(recall ST_STATUS)" = draft ] && echo ', as a draft until its pipeline passes').${R}"
      note "follow it, and mark it ready once the pipeline passes: fdroid-submit.sh --status $APPID"
    fi ;;
  *)
    ok "${B}Pushed: the branch is ready for its merge request — open it with the link above.${R}" ;;
esac
note "expect roughly 24-48 hours from merge until the app appears in F-Droid"
}

wizard_fdroid "$@"
