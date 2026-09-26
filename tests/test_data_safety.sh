#!/usr/bin/env bash
# Soul Stone data-safety tests. Unprivileged, sandboxed in a temp dir: never touches
# /mnt/sdcard, /usr/local/bin or the real $HOME. Run: bash tests/test_data_safety.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORAGE="$ROOT/src/soulstone-storage.sh"
LINK="$ROOT/src/soulstone-link.sh"
SANDBOX="$(mktemp -d /tmp/soulstone-safety.XXXXXX)"
PASS=0; FAIL=0
cleanup() { chmod -R u+rwX "$SANDBOX" 2>/dev/null; case "$SANDBOX" in /tmp/soulstone-safety.*) rm -rf -- "$SANDBOX";; esac; }
trap cleanup EXIT
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

extract_helper() { sed -n '/^# >>> soulstone-safe-migrate/,/^# <<< soulstone-safe-migrate/p' "$1"; }
extract_helper "$STORAGE" > "$SANDBOX/helper.sh"
# shellcheck disable=SC1091
source "$SANDBOX/helper.sh"
logger() { :; }   # keep syslog quiet

fresh() { rm -rf "$SANDBOX/w"; mkdir -p "$SANDBOX/w"/{src,dst,stash}; }

echo "== helper block =="
check "helper identical in storage and link scripts" '[ "$(extract_helper "$STORAGE")" = "$(extract_helper "$LINK")" ] && [ -s "$SANDBOX/helper.sh" ]'

echo "== ss_safe_migrate =="
fresh; mkdir -p "$SANDBOX/w/src/a/b" "$SANDBOX/w/src/emptydir"; echo one > "$SANDBOX/w/src/a/b/f1"; echo two > "$SANDBOX/w/src/f2"
ss_safe_migrate "$SANDBOX/w/src" "$SANDBOX/w/dst" "$SANDBOX/w/stash"; rc=$?
check "moves files, returns 0" '[ $rc -eq 0 ] && [ "$(cat $SANDBOX/w/dst/a/b/f1)" = one ] && [ "$(cat $SANDBOX/w/dst/f2)" = two ]'
check "leaves source directories in place (no pruning)" '[ -d "$SANDBOX/w/src/emptydir" ] && [ -d "$SANDBOX/w/src/a/b" ] && [ -z "$(ss_leftovers "$SANDBOX/w/src")" ]'

fresh; echo NEWER > "$SANDBOX/w/dst/x"; echo older > "$SANDBOX/w/src/x"; touch -d '2020-01-01' "$SANDBOX/w/src/x"
ss_safe_migrate "$SANDBOX/w/src" "$SANDBOX/w/dst" "$SANDBOX/w/stash"; rc=$?
check "older local file never overwrites newer SD file" '[ $rc -eq 0 ] && [ "$(cat $SANDBOX/w/dst/x)" = NEWER ]'
check "older local file preserved in stash" '[ "$(cat $SANDBOX/w/stash/older-local/x)" = older ] && [ ! -e "$SANDBOX/w/src/x" ]'

fresh; echo OLDER_SD > "$SANDBOX/w/dst/y"; touch -d '2020-01-01' "$SANDBOX/w/dst/y"; echo newer_local > "$SANDBOX/w/src/y"
ss_safe_migrate "$SANDBOX/w/src" "$SANDBOX/w/dst" "$SANDBOX/w/stash"; rc=$?
check "newer local wins, replaced SD copy kept in stash" '[ $rc -eq 0 ] && [ "$(cat $SANDBOX/w/dst/y)" = newer_local ] && [ "$(cat $SANDBOX/w/stash/replaced-on-target/y)" = OLDER_SD ]'

fresh; echo keep > "$SANDBOX/w/src/f"
( rsync() { return 11; }; ss_safe_migrate "$SANDBOX/w/src" "$SANDBOX/w/dst" "$SANDBOX/w/stash" 2>/dev/null ); rc=$?
check "rsync failure returns non-zero and keeps the source file" '[ $rc -ne 0 ] && [ "$(cat $SANDBOX/w/src/f)" = keep ]'

fresh; mkdir "$SANDBOX/w/src/ok" "$SANDBOX/w/src/bad"; echo a > "$SANDBOX/w/src/ok/a"; echo b > "$SANDBOX/w/src/bad/b"; echo blocker > "$SANDBOX/w/dst/bad"
ss_safe_migrate "$SANDBOX/w/src" "$SANDBOX/w/dst" "$SANDBOX/w/stash" 2>/dev/null; rc=$?
check "file-vs-directory conflict loses nothing (blocker stashed)" '[ $rc -eq 0 ] && [ "$(cat $SANDBOX/w/dst/bad/b)" = b ] && [ "$(cat $SANDBOX/w/stash/replaced-on-target/bad)" = blocker ]'

fresh; mkdir "$SANDBOX/w/src/ok" "$SANDBOX/w/src/bad"; echo a > "$SANDBOX/w/src/ok/a"; echo b > "$SANDBOX/w/src/bad/b"
( rsync() { command rsync "${@:1:$#-2}" --exclude=bad "${@: -2}"; return 23; }   # moves ok/, then reports an I/O-style error
  ss_safe_migrate "$SANDBOX/w/src" "$SANDBOX/w/dst" "$SANDBOX/w/stash" 2>/dev/null ); rc=$?
check "partial failure: non-zero, unmoved file still in source, moved file safe" '[ $rc -ne 0 ] && [ "$(cat $SANDBOX/w/src/bad/b)" = b ] && [ "$(cat $SANDBOX/w/dst/ok/a)" = a ]'

echo "== ss_valid_name / ss_remove_empty_tree =="
for n in "." ".." ".ssh" "a/b" "" "Soul Stone" 'x|y' '$(id)' 'a;b' '-rf'; do
  # '-rf' is allowed by charset only if it does not start with '-'; the regex requires alnum/_ first
  if ss_valid_name "$n"; then bad "rejects '$n'"; else ok "rejects '$n'"; fi
done
for n in Documents "My Folder" game_saves v1.2-final; do
  if ss_valid_name "$n"; then ok "accepts '$n'"; else bad "accepts '$n'"; fi
done
fresh; mkdir -p "$SANDBOX/w/src/a/b"; ss_remove_empty_tree "$SANDBOX/w/src/a"; rc=$?
check "removes a tree holding only empty dirs" '[ $rc -eq 0 ] && [ ! -e "$SANDBOX/w/src/a" ]'
fresh; mkdir -p "$SANDBOX/w/src/a/b"; echo x > "$SANDBOX/w/src/a/b/file"; ss_remove_empty_tree "$SANDBOX/w/src/a"; rc=$?
check "refuses when a file is inside; file survives" '[ $rc -ne 0 ] && [ -f "$SANDBOX/w/src/a/b/file" ]'

echo "== soulstone-link (sandboxed via sourced functions) =="
link_env() {   # $1 = body to run in a subshell with the sandbox wired in
  ( set +u; source "$LINK"; set +e
    USER_HOME="$SANDBOX/home"; SD_MOUNT="$SANDBOX/sd"; LINKED_BASE="$SD_MOUNT/Linked"
    USER_UID="$(id -u)"; USER_GID="$(id -g)"
    is_sd_healthy() { return 0; }; send_notify() { :; }; logger() { :; }
    set -e; eval "$1" ) 2>&1
}
reset_link() { rm -rf "$SANDBOX/home" "$SANDBOX/sd"; mkdir -p "$SANDBOX/home" "$SANDBOX/sd"; }

reset_link; mkdir -p "$SANDBOX/home/proj/sub"; echo data > "$SANDBOX/home/proj/sub/f"; echo top > "$SANDBOX/home/proj/t"
link_env 'cmd_link "$USER_HOME/proj"' >/dev/null; rc=$?
check "link: directory replaced by symlink, data on SD" '[ $rc -eq 0 ] && [ -L "$SANDBOX/home/proj" ] && [ "$(cat $SANDBOX/sd/Linked/proj/sub/f)" = data ]'
link_env 'cmd_unlink "$USER_HOME/proj"' >/dev/null; rc=$?
check "unlink: real directory restored with identical data" '[ $rc -eq 0 ] && [ -d "$SANDBOX/home/proj" ] && [ ! -L "$SANDBOX/home/proj" ] && [ "$(cat $SANDBOX/home/proj/sub/f)" = data ] && [ "$(cat $SANDBOX/home/proj/t)" = top ]'
check "unlink: SD copy removed after verified restore" '[ ! -e "$SANDBOX/sd/Linked/proj" ]'

reset_link; mkdir -p "$SANDBOX/home/proj"; echo data > "$SANDBOX/home/proj/f"
link_env 'rsync() { return 23; }; cmd_link "$USER_HOME/proj"' >/dev/null; rc=$?
check "link: failed rsync leaves the folder and its data untouched" '[ $rc -ne 0 ] && [ -d "$SANDBOX/home/proj" ] && [ ! -L "$SANDBOX/home/proj" ] && [ "$(cat $SANDBOX/home/proj/f)" = data ]'

reset_link; mkdir -p "$SANDBOX/home/proj"; echo data > "$SANDBOX/home/proj/f"
link_env 'cmd_link "$USER_HOME/proj"' >/dev/null
link_env 'rsync() { return 23; }; cmd_unlink "$USER_HOME/proj"' >/dev/null; rc=$?
check "unlink: failed copy-back keeps link and SD data" '[ $rc -ne 0 ] && [ -L "$SANDBOX/home/proj" ] && [ "$(cat $SANDBOX/sd/Linked/proj/f)" = data ]'

reset_link; mkdir -p "$SANDBOX/home/proj"; echo data > "$SANDBOX/home/proj/f"
link_env 'cmd_link "$USER_HOME/proj"' >/dev/null
link_env 'is_sd_healthy() { return 1; }; cmd_unlink "$USER_HOME/proj"' >/dev/null; rc=$?
check "unlink with SD offline: symlink kept, nothing changed" '[ $rc -ne 0 ] && [ -L "$SANDBOX/home/proj" ] && [ "$(cat $SANDBOX/sd/Linked/proj/f)" = data ]'

reset_link; mkdir -p "$SANDBOX/victim/deep"; echo precious > "$SANDBOX/victim/deep/f"; ln -s "$SANDBOX/victim" "$SANDBOX/home/evil"
link_env 'cmd_unlink "$USER_HOME/evil"' >/dev/null; rc=$?
check "unlink of a symlink pointing outside Linked/: refused, target data intact" '[ $rc -ne 0 ] && [ -L "$SANDBOX/home/evil" ] && [ "$(cat $SANDBOX/victim/deep/f)" = precious ]'
reset_link; mkdir -p "$SANDBOX/home/keep"; echo k > "$SANDBOX/home/keep/f"; ln -s "$SANDBOX/home/keep" "$SANDBOX/home/homelink"
link_env 'cmd_unlink "$USER_HOME/homelink"' >/dev/null; rc=$?
check "unlink of a symlink into \$HOME: refused, data intact" '[ $rc -ne 0 ] && [ "$(cat $SANDBOX/home/keep/f)" = k ]'

reset_link; mkdir -p "$SANDBOX/home/.ssh" "$SANDBOX/home/Documents/Notes/Locked" "$SANDBOX/outside"; echo s > "$SANDBOX/home/.ssh/id"
for t in '$USER_HOME' '$USER_HOME/.ssh' '$USER_HOME/Documents/Notes/Locked' "$SANDBOX/outside" '/' '/etc'; do
  link_env "cmd_link \"$t\"" >/dev/null; rc=$?
  check "link refuses '$t'" "[ $rc -ne 0 ] && [ ! -L \"\$SANDBOX/home/.ssh\" ] && [ -f \"\$SANDBOX/home/.ssh/id\" ]"
done
check "nothing was written to Linked/ by refused links" '[ -z "$(ls -A "$SANDBOX/sd" 2>/dev/null)" ] || [ -z "$(find "$SANDBOX/sd" -type f -print -quit)" ]'

reset_link; echo doc > "$SANDBOX/home/note.txt"; mkdir -p "$SANDBOX/sd/Linked"; echo existing > "$SANDBOX/sd/Linked/note.txt"
link_env 'cmd_link "$USER_HOME/note.txt"' >/dev/null; rc=$?
check "file link refuses to overwrite an existing SD file" '[ $rc -ne 0 ] && [ "$(cat $SANDBOX/sd/Linked/note.txt)" = existing ] && [ "$(cat $SANDBOX/home/note.txt)" = doc ]'
rm -f "$SANDBOX/sd/Linked/note.txt"
link_env 'cmd_link "$USER_HOME/note.txt"' >/dev/null; link_env 'cmd_unlink "$USER_HOME/note.txt"' >/dev/null; rc=$?
check "file link/unlink round trip" '[ $rc -eq 0 ] && [ ! -L "$SANDBOX/home/note.txt" ] && [ "$(cat $SANDBOX/home/note.txt)" = doc ] && [ ! -e "$SANDBOX/sd/Linked/note.txt" ]'

echo "== static guards =="
code() { grep -vE '^[[:space:]]*#' "$@"; }   # ignore comment lines
check "no unchecked rsync (|| true) in storage/link scripts" '! code "$STORAGE" "$LINK" | grep -E "rsync.*\|\| *true"'
check "no 'find ... -delete' outside the shared helper" '[ "$(code "$STORAGE" "$LINK" | grep -- "-delete" | grep -v "find \"\$1\" -depth -type d -empty -delete" | wc -l)" -eq 0 ]'
check "only guarded rm -rf remains (one-file-system, under Linked/)" '[ "$(code "$LINK" "$STORAGE" | grep -E "rm -rf|rm -fr" | grep -vc -- "--one-file-system")" -eq 0 ]'
check "no rm -rf on SD Card / ide_link in storage" '! code "$STORAGE" | grep -E "rm -rf.*(SD Card|ide_link|legacy_portal)"'
check "engine.py no longer embeds a script copy" '! grep -q "remove-source-files" "$ROOT/src/engine.py" && grep -q "src\" / \"soulstone-storage.sh" "$ROOT/src/engine.py"'
check "read-only status/list work unprivileged (no root-only lock)" '[ "$(id -u)" -eq 0 ] || { out="$(bash "$STORAGE" status 2>&1; bash "$STORAGE" list 2>&1)"; ! grep -q "Permission denied" <<<"$out" && grep -q "Soul Stone Status" <<<"$out"; }'
check "storage + link parse (bash -n)" 'bash -n "$STORAGE" && bash -n "$LINK"'

echo; echo "Result: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
