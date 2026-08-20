#!/usr/bin/env bash
#
# Offline self-test. Everything checkable without a running deployment.
#
# check_contract.py validates structure; this validates *behaviour* — that
# scripts fail correctly, that documented commands exist, that teardown cannot
# delete more than it created, and that the repo's claims agree with each other.
#
#   ./tools/selftest.sh          human output
#   ./tools/selftest.sh --quiet  only failures
#
# Creates nothing, needs no network, needs no Docker.

set -uo pipefail

# printf '%.2f' honours LC_NUMERIC, so a comma-decimal locale renders 0.00 as
# "0,00" and every cost comparison below fails on a machine that is set up
# perfectly correctly. Pin the numeric locale rather than the developer's.
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

pass=0 fail=0
_g=$'\033[32m'; _r=$'\033[31m'; _d=$'\033[2m'; _0=$'\033[0m'
[ -t 1 ] || { _g=""; _r=""; _d=""; _0=""; }

ok()   { pass=$((pass+1)); [ "$QUIET" = 1 ] || printf '  %s✓%s %s\n' "$_g" "$_0" "$1"; }
bad()  { fail=$((fail+1)); printf '  %s✗%s %s\n' "$_r" "$_0" "$1"; [ -n "${2:-}" ] && printf '      %s%s%s\n' "$_d" "$2" "$_0"; }
grp()  { [ "$QUIET" = 1 ] || printf '\n%s\n' "$1"; }

demos() { find demos -mindepth 1 -maxdepth 1 -type d -not -name '_*' | sort; }

# These tests overwrite each demo's .env, so a real one has to be preserved.
# Back up once, restore on any exit.
BACKUP_DIR=$(mktemp -d)
save_envs() {
  for d in $(demos); do
    [ -f "$d/.env" ] && cp "$d/.env" "$BACKUP_DIR/$(basename "$d").env"
  done
  return 0
}
restore_envs() {
  for d in $(demos); do
    rm -f "$d/.env"
    [ -f "$BACKUP_DIR/$(basename "$d").env" ] && cp "$BACKUP_DIR/$(basename "$d").env" "$d/.env"
  done
  rm -rf "$BACKUP_DIR"
  return 0
}
trap restore_envs EXIT INT TERM
save_envs

# ---------------------------------------------------------------------------
grp "1. Scripts fail correctly when config is missing"
# A script that silently proceeds without config is worse than one that fails.

for d in $(demos); do
  slug=$(basename "$d")
  rm -f "$d/.env"

  out=$("$d/scripts/preflight.sh" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    bad "$slug preflight: exits 0 with no .env" "it should refuse to run"
  elif ! printf '%s' "$out" | grep -q 'REMEDIATION:'; then
    bad "$slug preflight: no REMEDIATION line" "AGENTS.md tells agents to relay it"
  else
    ok "$slug preflight refuses without .env, with remediation"
  fi
  rm -f "$d/.env"
done

# ---------------------------------------------------------------------------
grp "2. .env.example is usable as-is"
# Unlike the cloud repos in this family, there is nothing for a person to fill
# in — no project id, no instance, no credential. A leftover placeholder here
# would mean a demo that fails on a value nobody was told to set.

for d in $(demos); do
  slug=$(basename "$d")
  if grep -qiE '^[A-Z_]+=(your-|<|CHANGE|TODO|xxx)' "$d/.env.example"; then
    bad "$slug .env.example still has a placeholder value" \
        "$(grep -inE '^[A-Z_]+=(your-|<|CHANGE|TODO|xxx)' "$d/.env.example" | head -2 | tr '\n' ' ')"
  else
    ok "$slug .env.example has no placeholders to fill in"
  fi
done

# ---------------------------------------------------------------------------
grp "3. Failures are always machine-readable"
# Agents parse --json. One unescaped newline breaks the contract. With no .env
# every preflight fails, which is exactly the path whose JSON must still parse.

for d in $(demos); do
  slug=$(basename "$d")
  rm -f "$d/.env"
  out=$("$d/scripts/preflight.sh" --json 2>&1)
  if printf '%s\n' "$out" | python3 -c '
import json,sys
n=0
for line in sys.stdin:
    line=line.strip()
    if line:
        json.loads(line); n+=1
sys.exit(0 if n else 1)' 2>/dev/null; then
    ok "$slug --json output parses"
  else
    bad "$slug --json output is not valid JSON" "$(printf '%s' "$out" | head -2)"
  fi
done

# ---------------------------------------------------------------------------
grp "4. SQL and GQL are used verbatim, with nothing left unsubstituted"
# Nothing here templates SQL — the database name is a CLI argument, not part of
# the DDL. A ${VAR} in a .ddl or .gql would therefore reach Spanner literally.

for d in $(demos); do
  slug=$(basename "$d")
  found=""
  for f in "$d"/sql/*.ddl "$d"/sql/*.sql "$d"/queries/*.gql; do
    [ -f "$f" ] || continue
    # Strip -- comments first: these files explain their own conventions, and
    # a comment saying "no \${PLACEHOLDERS} here" is not a placeholder.
    grep -vE '^[[:space:]]*--' "$f" | grep -qE '\$\{[A-Z_]+\}' \
      && found="$found $(basename "$f")"
  done
  if [ -n "$found" ]; then
    bad "$slug: unsubstituted placeholder(s) in:$found" \
        "nothing in this repo templates SQL; the CLI would receive \${VAR} literally"
  else
    ok "$slug SQL/GQL files are literal"
  fi
done

# ---------------------------------------------------------------------------
grp "5. Every GQL file is shaped like a GQL query"
# The CLI rejects a statement whose first line is indented, and rejects `--`
# comment lines. The helpers strip both, but a .gql whose first real line is not
# GRAPH is a different bug: it will not run anywhere.

for d in $(demos); do
  slug=$(basename "$d")
  [ -d "$d/queries" ] || continue
  for f in "$d"/queries/*.gql; do
    [ -f "$f" ] || continue
    first=$(grep -vE '^[[:space:]]*--' "$f" | sed '/^[[:space:]]*$/d' | head -1)
    case "$first" in
      GRAPH\ *) ok "$slug $(basename "$f") starts with GRAPH" ;;
      *) bad "$slug $(basename "$f"): first statement line is not GRAPH" "got: ${first:0:60}" ;;
    esac
  done
done

# ---------------------------------------------------------------------------
grp "6. Every variable a script reads is in .env.example"

for d in $(demos); do
  slug=$(basename "$d")
  req=$(grep -rhoE 'require_env [A-Z_ \\]+' "$d"/scripts/*.sh 2>/dev/null \
        | sed 's/require_env //' | tr ' \\' '\n\n' | grep -E '^[A-Z_]+$' | sort -u)
  missing=""
  for v in $req; do
    grep -qE "^${v}=" "$d/.env.example" || missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    bad "$slug: required but not in .env.example:$missing"
  else
    ok "$slug .env.example covers every require_env"
  fi
done

# ---------------------------------------------------------------------------
grp '7. Every ${VAR} a script expands is defined somewhere'
# Section 6 checks require_env, which is explicit. This catches the other case:
# a variable expanded directly in a script. Under `set -u` an unset one is
# FATAL, so a stale reference kills the step at runtime — typically in handoff,
# after the demo has already been built and verified, which is the most
# expensive possible place to find it.

DEFAULTED=$(grep -ohE '^: "\$\{[A-Z_]+' shared/lib/*.sh 2>/dev/null | sed 's/.*{//' | sort -u)

for d in $(demos); do
  slug=$(basename "$d")
  # A backslash-escaped \${NAME} is a literal string, not an expansion.
  used=$(sed 's/\\\${[A-Z][A-Z0-9_]*}//g' "$d"/scripts/*.sh 2>/dev/null \
         | grep -ohE '\$\{[A-Z][A-Z0-9_]*(:-[^}]*)?\}' \
         | sed 's/[${}]//g; s/:-.*//' | sort -u)
  missing=""
  for v in $used; do
    case "$v" in
      GXR_*|OMNI_*|BASH_SOURCE|PATH|HOME|PWD|SHELL|USER|EOF) continue ;;
    esac
    grep -qE "^${v}=" "$d/.env.example" 2>/dev/null && continue
    printf '%s\n' "$DEFAULTED" | grep -qx "$v" && continue
    grep -qE "^[[:space:]]*(local +)?${v}=" "$d"/scripts/*.sh 2>/dev/null && continue
    missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    bad "$slug: script expands undefined var(s):$missing" \
        "under 'set -u' this aborts the step at runtime"
  else
    ok "$slug scripts expand only defined variables"
  fi
done

# ---------------------------------------------------------------------------
grp "8. Teardown deletes only the demo's database"
# The one irreversible action in the repo, and the highest-stakes rule here:
# the Docker volume holds EVERY database on the deployment, including work that
# has nothing to do with this repo. A demo teardown that removes it destroys
# someone else's data to reclaim a few megabytes.

for d in $(demos); do
  slug=$(basename "$d")
  t="$d/scripts/teardown.sh"
  [ -f "$t" ] || { bad "$slug: no teardown.sh"; continue; }

  scope_ok=1
  if grep -qE 'docker[[:space:]]+volume[[:space:]]+rm' "$t"; then
    bad "$slug teardown: removes the Docker volume" "that destroys every database on the deployment"
    scope_ok=0
  fi
  if grep -qE 'docker[[:space:]]+rm\b' "$t"; then
    bad "$slug teardown: removes the container" "the deployment belongs to the person, not the demo"
    scope_ok=0
  fi
  if grep -qE 'omni_destroy|rm -rf? +/|rm -rf? +\$HOME|rm -rf? +~' "$t"; then
    bad "$slug teardown: unsafe deletion"
    scope_ok=0
  fi
  [ "$scope_ok" = 1 ] && ok "$slug teardown scope is safe"

  # Whatever demo.yaml declares as created must actually be removed.
  if grep -q 'spanner-omni://' "$d/demo.yaml" && ! grep -q 'omni_db_drop' "$t"; then
    bad "$slug teardown: demo.yaml declares a database but teardown does not drop one"
  fi
done

# ---------------------------------------------------------------------------
grp "9. The image tag is pinned"
# A moving tag on a preview image is how this repo silently stops working.

if grep -qE 'spanner-omni:latest|OMNI_VERSION:?=[[:space:]]*latest' shared/lib/omni.sh; then
  bad "shared/lib/omni.sh uses a floating image tag" "pin it, and bump deliberately"
else
  ok "shared/lib/omni.sh pins the image tag"
fi
for d in $(demos); do
  slug=$(basename "$d")
  if grep -qE '^OMNI_VERSION=latest' "$d/.env.example"; then
    bad "$slug .env.example sets OMNI_VERSION=latest"
  else
    ok "$slug pins OMNI_VERSION"
  fi
done

# ---------------------------------------------------------------------------
grp "10. Every file a README links to exists"

LINKFAIL=$(mktemp)
for md in $(git ls-files '*.md' 2>/dev/null); do
  dir=$(dirname "$md")
  grep -oE '\]\(([^)#][^)]*)\)' "$md" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' | while read -r ref; do
    case "$ref" in
      http*|mailto:*\#*|"") continue ;;
      \#*) continue ;;
    esac
    target="${ref%%#*}"
    [ -z "$target" ] && continue
    if [ ! -e "$dir/$target" ]; then
      printf '  %s✗%s %s -> %s\n' "$_r" "$_0" "$md" "$target"
      echo x >> "$LINKFAIL"
    fi
  done
done
if [ -s "$LINKFAIL" ]; then
  fail=$((fail + $(wc -l < "$LINKFAIL")))
else
  ok "all relative links in markdown resolve"
fi
rm -f "$LINKFAIL"

# ---------------------------------------------------------------------------
grp "11. gxr works from the paths the docs use"

if ./gxr list >/dev/null 2>&1; then ok "./gxr list works from repo root"
else bad "./gxr list fails from repo root"; fi

d=$(demos | head -1)
if [ -z "$d" ]; then
  ok "no demos yet — skipping the in-demo path check"
elif (cd "$d" && ../../gxr list >/dev/null 2>&1); then
  ok "../../gxr works from inside a demo dir (as the READMEs instruct)"
else
  bad "../../gxr fails from inside a demo dir" "demo READMEs tell people to run it that way"
fi

# Capture first: with `set -o pipefail`, piping a deliberately-failing command
# into grep reports the pipeline as failed even when grep matched.
out=$(./gxr up __nonexistent__ 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'REMEDIATION:'; then
  ok "gxr rejects an unknown demo with remediation"
else
  bad "gxr does not fail cleanly on an unknown demo" "exit=$rc"
fi

out=$(./gxr omni bogus-subcommand 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'REMEDIATION:'; then
  ok "gxr omni rejects an unknown subcommand with remediation"
else
  bad "gxr omni does not fail cleanly on an unknown subcommand" "exit=$rc"
fi

# ---------------------------------------------------------------------------
grp "12. Cost claims are consistent"
# demo.yaml, the README and the handoff block must agree. People plan around
# these, and here the claim is the stronger one — that nothing is billable.

for d in $(demos); do
  slug=$(basename "$d")
  y=$(sed -n 's/^ *estimate_usd: *//p' "$d/demo.yaml" | head -1)
  [ -z "$y" ] && { bad "$slug: demo.yaml has no cost.estimate_usd"; continue; }
  printed=$(printf '%.2f' "$y")
  if grep -qE "\\\$$printed" "$d/scripts/handoff.sh"; then
    ok "$slug cost agrees between demo.yaml and handoff.sh (\$$printed)"
  else
    bad "$slug: demo.yaml says \$$printed but handoff.sh prints something else" \
        "$(grep -o 'Cost so far[^.]*' "$d/scripts/handoff.sh" | head -1)"
  fi

  # A demo that declares billable resources on a repo whose whole premise is
  # that there are none needs to be deliberate about it.
  if grep -qE '^ *billable_resources: *\[[^]]' "$d/demo.yaml"; then
    bad "$slug declares billable_resources" \
        "Spanner Omni creates nothing metered; if this demo really does, say why in the PR"
  else
    ok "$slug declares no billable resources"
  fi

  if ! grep -q 'local_resources:' "$d/demo.yaml"; then
    bad "$slug: no cost.local_resources" "there is no bill here, so hardware is the honest claim"
  else
    ok "$slug declares what it consumes locally"
  fi
done

# ---------------------------------------------------------------------------
grp "13. The connect story is not oversold"
# Kineviz has no native Spanner Omni connector. A README that implies otherwise
# sends people into a dead end that looks like their mistake.

for md in $(git ls-files '*.md' 2>/dev/null); do
  if grep -qiE 'Database Type:? *`?Spanner Property Graph' "$md"; then
    bad "$md tells people to pick 'Spanner Property Graph' in Kineviz" \
        "that connector cannot reach a Spanner Omni endpoint — link connect/ instead"
  fi
done
ok "no doc promises the native Spanner connector works against Omni"

# ---------------------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '%s%d passed, 0 failed%s\n\n' "$_g" "$pass" "$_0"
  exit 0
fi
printf '%s%d passed, %d FAILED%s\n\n' "$_r" "$pass" "$fail" "$_0"
exit 1
