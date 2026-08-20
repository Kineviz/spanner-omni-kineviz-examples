#!/usr/bin/env bash
# Spanner Omni deployment helpers.
#
# Sourced by shared/lib/common.sh — do not source this directly.
#
# Spanner Omni is the downloadable Spanner. It runs on your machine, in your
# data centre, or in another cloud, and it speaks the same wire protocol and the
# same GoogleSQL and Graph dialects as managed Spanner. Everything here drives
# one single-server deployment in a container, which is the setup Google
# documents for development:
#   https://docs.cloud.google.com/spanner-omni/setup
#
# Everything goes through the CLI that ships inside the image, so the only hard
# dependencies are Docker and a stdlib Python 3. That is deliberate: a demo you
# have to `pip install` into before you can read it is a demo fewer people run.
# The Spanner Python client is needed for exactly one optional thing —
# connect/export.py — and `./gxr deps` installs it when you want that.
#
# Two identifiers are fixed by Spanner Omni and are not yours to choose: the
# project and the instance are both literally `default`. Client libraries need
# them; the CLI takes no --instance flag at all.

# --- configuration ----------------------------------------------------------
# Every one of these can be overridden from a demo's .env.

: "${OMNI_CONTAINER:=spanneromni}"
: "${OMNI_VOLUME:=spanner}"
: "${OMNI_IMAGE:=us-docker.pkg.dev/spanner-omni/images/spanner-omni}"
: "${OMNI_VERSION:=2026.r1-beta.2}"
: "${OMNI_HOST:=localhost}"
: "${OMNI_PORT:=15000}"
: "${OMNI_CONSOLE_PORT:=15026}"

# Fixed by the product. See the header.
OMNI_PROJECT="default"
OMNI_INSTANCE="default"

# Scratch directory inside the container, for files the CLI has to read from
# the server's own filesystem: DDL files and CSV import folders.
OMNI_WORKDIR="/tmp/kineviz"

omni_endpoint()    { printf '%s:%s' "$OMNI_HOST" "$OMNI_PORT"; }
omni_console_url() { printf 'http://%s:%s' "$OMNI_HOST" "$OMNI_CONSOLE_PORT"; }

# The in-container CLI. Same binary as the standalone download.
OMNI_CLI_PATH="/google/spanner/bin/spanner"

# --- docker -----------------------------------------------------------------

require_docker() {
  command -v docker >/dev/null 2>&1 || die \
    "'docker' not found on PATH." \
    "Install Docker Engine 24.0+ or Docker Desktop: https://docs.docker.com/get-docker/ — nothing has been created yet."
  docker info >/dev/null 2>&1 || die \
    "The Docker daemon is not responding." \
    "Start Docker (on macOS: open -a Docker; on Linux: sudo systemctl start docker), wait for it to report ready, then re-run."
}

omni_container_state() {  # prints running | exited | absent
  local s
  s=$(docker inspect -f '{{.State.Status}}' "$OMNI_CONTAINER" 2>/dev/null) || { echo absent; return; }
  echo "${s:-absent}"
}

omni_running() { [ "$(omni_container_state)" = "running" ]; }

# Host networking is what Google's setup page documents, and it is the right
# answer on Linux. On macOS and Windows the engine runs inside a VM, so
# --network host binds the VM's loopback and the endpoint is unreachable from
# the machine you are sitting at — the container looks perfectly healthy while
# nothing can connect. Publishing the port range works everywhere, so that is
# what we do off Linux.
omni_run_args() {
  if [ "$(uname -s)" = "Linux" ]; then
    printf '%s' "--network host"
  else
    printf '%s' "-p ${OMNI_PORT}-${OMNI_CONSOLE_PORT}:${OMNI_PORT}-${OMNI_CONSOLE_PORT}"
  fi
}

# Start the deployment. Idempotent: an already-running container is left alone,
# a stopped one is restarted, and the named volume is reused so data survives.
omni_start() {
  require_docker

  case "$(omni_container_state)" in
    running)
      ok "Spanner Omni already running (container $OMNI_CONTAINER)"
      return 0 ;;
    exited)
      info "restarting existing container $OMNI_CONTAINER"
      docker start "$OMNI_CONTAINER" >/dev/null \
        || die "Could not restart container $OMNI_CONTAINER." \
               "Inspect it with: docker logs $OMNI_CONTAINER"
      omni_wait_ready
      return 0 ;;
  esac

  # The volume is what makes the data outlive the container. Without it,
  # `docker rm` silently discards every database.
  docker volume inspect "$OMNI_VOLUME" >/dev/null 2>&1 \
    || docker volume create "$OMNI_VOLUME" >/dev/null \
    || die "Could not create Docker volume '$OMNI_VOLUME'." "Check your Docker installation."

  info "starting $OMNI_IMAGE:$OMNI_VERSION (first run pulls ~1 GB)"
  # shellcheck disable=SC2046  # omni_run_args is deliberately word-split
  docker run -d $(omni_run_args) \
    --name "$OMNI_CONTAINER" \
    -v "$OMNI_VOLUME:/spanner" \
    "$OMNI_IMAGE:$OMNI_VERSION" \
    start-single-server >/dev/null \
    || die "Could not start the Spanner Omni container." \
           "Check the image tag ($OMNI_VERSION) and see: docker logs $OMNI_CONTAINER"

  omni_wait_ready
  ok "Spanner Omni running at $(omni_endpoint)"
}

# Poll until the deployment answers an admin call. The container reports itself
# up well before the servers finish electing, so waiting on `docker ps` alone
# hands you a connection refused a second later.
omni_wait_ready() {
  local waited=0 max="${1:-180}"
  info "waiting for the deployment to accept connections"
  while [ "$waited" -lt "$max" ]; do
    if omni_cli databases list >/dev/null 2>&1; then
      ok "deployment ready after ${waited}s"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  die "Spanner Omni did not become ready within ${max}s." \
      "Check the logs: docker logs $OMNI_CONTAINER. On a first run the image pull can dominate; re-run once it completes."
}

omni_stop() {
  require_docker
  if [ "$(omni_container_state)" = absent ]; then
    info "no container named $OMNI_CONTAINER — nothing to stop"
    return 0
  fi
  docker stop "$OMNI_CONTAINER" >/dev/null 2>&1 || true
  ok "stopped $OMNI_CONTAINER (data kept in volume '$OMNI_VOLUME')"
}

# Remove the container. The volume — and therefore every database — goes only
# when explicitly asked, because that is the irreversible half.
omni_destroy() {
  local drop_volume="${1:-no}"
  require_docker
  docker rm -f "$OMNI_CONTAINER" >/dev/null 2>&1 || true
  ok "removed container $OMNI_CONTAINER"
  if [ "$drop_volume" = "yes" ]; then
    docker volume rm "$OMNI_VOLUME" >/dev/null 2>&1 || true
    ok "removed volume $OMNI_VOLUME — all databases are gone"
  else
    info "volume '$OMNI_VOLUME' kept; your databases are still there"
    dim "delete it with: docker volume rm $OMNI_VOLUME"
  fi
}

# --- the Spanner Omni CLI ---------------------------------------------------

# Run the in-container CLI. -i, not -it: no TTY, so this works from a script and
# from CI. The interactive shell is a separate helper below.
omni_cli() {
  docker exec -i "$OMNI_CONTAINER" "$OMNI_CLI_PATH" "$@"
}

# The CLI writes progress with ANSI erase-line sequences, so raw output carries
# ESC[K and stray carriage returns. Strip them, or every grep and every error
# message you print has control characters in it.
omni_clean() {
  sed -e $'s/\033\\[[0-9;]*[A-Za-z]//g' -e $'s/\r//g'
}

# The interactive SQL shell, for a person at a terminal.
omni_shell() {
  local db="$1"
  docker exec -it "$OMNI_CONTAINER" "$OMNI_CLI_PATH" sql --database="$db"
}

omni_require_running() {
  omni_running || die \
    "Spanner Omni is not running (container: $OMNI_CONTAINER)." \
    "Start it with './gxr omni up'. Nothing has been created yet."
}

omni_db_exists() {
  omni_cli databases list 2>/dev/null | omni_clean | awk 'NR>1 {print $1}' | grep -qx "$1"
}

omni_db_create() {
  local db="$1"
  if omni_db_exists "$db"; then
    info "database $db already exists"
    return 0
  fi
  omni_cli databases create "$db" >/dev/null 2>&1 \
    || die "Could not create database '$db'." \
           "Check the deployment is healthy: docker logs $OMNI_CONTAINER"
  ok "created database $db"
}

omni_db_drop() {
  local db="$1"
  if ! omni_db_exists "$db"; then
    info "database $db does not exist — nothing to drop"
    return 0
  fi
  omni_cli databases delete "$db" --quiet >/dev/null 2>&1 \
    || die "Could not drop database '$db'." \
           "Drop it by hand: docker exec -it $OMNI_CONTAINER $OMNI_CLI_PATH databases delete $db --quiet"
  ok "dropped database $db"
}

# --- running statements -----------------------------------------------------

# Make a statement acceptable to `databases execute-sql --sql=`.
#
# Two things that build fails on, both reported as the same unhelpful
# "failed to build statement: invalid statement":
#
#   1. `--` comment lines. Our .gql and .ddl files are heavily commented on
#      purpose — the comments are half the teaching — so they get stripped on
#      the way in rather than us writing bare SQL.
#
#   2. Leading whitespace on the FIRST line. Indented continuation lines are
#      fine; an indented first line is not. That bites every time a query is
#      written as an indented shell heredoc or a quoted multi-line string, which
#      is to say most of the time, and it looks like a syntax error in SQL that
#      is in fact perfectly valid.
omni_strip_comments() {
  sed -e 's/^[[:space:]]*--.*$//' \
    | sed '/^[[:space:]]*$/d' \
    | sed '1s/^[[:space:]]*//'
}

# omni_sql <database> <sql...> — run one query or DML statement.
# Prints the CLI's table output, cleaned. Non-zero on error.
omni_sql() {
  local db="$1"; shift
  local sql; sql=$(printf '%s' "$*" | omni_strip_comments)
  local out
  if ! out=$(omni_cli databases execute-sql "$db" --sql="$sql" 2>&1 | omni_clean); then
    printf '%s\n' "$out"; return 1
  fi
  # The CLI exits 0 and prints ERROR for some failures, so check the text too.
  case "$out" in
    Error:*|*"ERROR: spanner:"*) printf '%s\n' "$out"; return 1 ;;
  esac
  printf '%s\n' "$out"
}

# omni_sql_scalar <database> <sql...> — the single value of a one-row, one-column
# query. The CLI pads columns, so trim rather than cut on a fixed width.
omni_sql_scalar() {
  local out
  out=$(omni_sql "$@") || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out" | awk 'NR==2' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# omni_ddl <database> <local-ddl-file>
#
# `databases ddl update --ddl-file` reads the path on the *server's* filesystem,
# which for a container deployment is inside the container. Copy it in first.
omni_ddl() {
  local db="$1" file="$2"
  [ -f "$file" ] || die "DDL file not found: $file" "Check the path."
  local base; base=$(basename "$file")
  docker exec -i "$OMNI_CONTAINER" mkdir -p "$OMNI_WORKDIR" >/dev/null 2>&1
  docker cp "$file" "$OMNI_CONTAINER:$OMNI_WORKDIR/$base" >/dev/null \
    || die "Could not copy $base into the container." "Check that $OMNI_CONTAINER is running."

  local out
  out=$(omni_cli databases ddl update "$db" --ddl-file="$OMNI_WORKDIR/$base" 2>&1 | omni_clean) || true
  case "$out" in
    *"Duplicate name"*|*"already exists"*)
      # Re-running setup after a partial failure has to converge, and applying
      # the same CREATE twice is the ordinary way there.
      info "schema already applied"
      return 0 ;;
    *Error:*|*ERROR:*)
      printf '%s\n' "$out" >&2
      return 1 ;;
  esac
  return 0
}

# omni_import <database> <local-dir>
#
# Bulk load through Spanner's own CSV import. The directory must hold one
# headerless CSV per table plus a `csv-export.json` manifest — exactly what
# `spanner databases export --format=csv` produces, and what each demo's
# data/generate.py writes.
#
# Import is asynchronous: the CLI returns an operation name and exits. Poll it.
omni_import() {
  local db="$1" dir="$2"
  [ -f "$dir/csv-export.json" ] || die \
    "$dir has no csv-export.json." \
    "Run the demo's data/generate.py first — Spanner's CSV import requires that manifest."

  docker exec -i "$OMNI_CONTAINER" rm -rf "$OMNI_WORKDIR/data" >/dev/null 2>&1
  docker exec -i "$OMNI_CONTAINER" mkdir -p "$OMNI_WORKDIR" >/dev/null 2>&1
  docker cp "$dir" "$OMNI_CONTAINER:$OMNI_WORKDIR/data" >/dev/null \
    || die "Could not copy the data folder into the container." "Check that $OMNI_CONTAINER is running."

  local out op
  out=$(omni_cli databases import "$db" --url="file://$OMNI_WORKDIR/data" --format=csv 2>&1 | omni_clean)
  op=$(printf '%s' "$out" | grep -o '_auto_op_[a-f0-9]*' | head -1)
  [ -n "$op" ] || { printf '%s\n' "$out" >&2; die "Import did not start." "See the output above."; }

  omni_wait_operation "$db" "$op"
}

# omni_wait_operation <database> <operation>
#
# Returns 0 when the operation finishes. Note what it does NOT do: treat the
# operation's own error field as authoritative.
#
# The 2026.r1-beta.2 CSV import reports
#   "A step can generate output only if it's not a cleanup step and it's not the
#    last non-cleanup step of a workflow"
# on a load that in fact wrote every row correctly. It is internal workflow
# bookkeeping leaking out of a preview build. Failing the demo on it would mean
# failing on a load that worked; ignoring errors wholesale would mean missing a
# load that did not. So that one message is downgraded to a warning, anything
# else is fatal, and either way `verify` is what actually decides — it counts
# rows with a real query.
omni_wait_operation() {
  local db="$1" op="$2" waited=0 max="${3:-300}" out
  while [ "$waited" -lt "$max" ]; do
    out=$(omni_cli operations describe --database="$db" "$op" 2>&1 | omni_clean)
    case "$out" in
      *"done:"*"true"*)
        case "$out" in
          *"A step can generate output only if"*)
            warn "the import operation reported a known preview bookkeeping error; verifying by row count instead"
            return 0 ;;
          *"error:"*"code:"*)
            # An empty error block prints as `error:` with nothing under it.
            if printf '%s' "$out" | grep -qE 'message: *"?[^"[:space:]]'; then
              printf '%s\n' "$out" >&2
              return 1
            fi
            return 0 ;;
        esac
        return 0 ;;
    esac
    sleep 3; waited=$((waited + 3))
  done
  die "Operation $op did not finish within ${max}s." \
      "Check it by hand: docker exec -it $OMNI_CONTAINER $OMNI_CLI_PATH operations describe --database=$db $op"
}

# omni_truncate <database> <table...> — clear tables, children first.
# Makes a re-run converge instead of failing on a duplicate primary key.
omni_truncate() {
  local db="$1"; shift
  for t in "$@"; do
    omni_sql "$db" "DELETE FROM $t WHERE TRUE" >/dev/null 2>&1 || true
  done
}

# --- property graph introspection -------------------------------------------

omni_list_graphs() {
  omni_sql "$1" "SELECT property_graph_name FROM information_schema.property_graphs" \
    | awk 'NR>1' | sed 's/[[:space:]]*$//' | sed '/^$/d'
}

# omni_graph_metadata <database> <graph> — the metadata JSON, one line.
# The CLI cannot render a JSON-typed column (it prints "(Unspecified)"), so ask
# for TO_JSON_STRING of it and pick the line that is actually JSON.
omni_graph_metadata() {
  omni_sql "$1" "SELECT TO_JSON_STRING(PROPERTY_GRAPH_METADATA_JSON) AS m
                 FROM information_schema.property_graphs
                 WHERE property_graph_name = '$2'" \
    | sed -n 's/^\({.*}\)[[:space:]]*$/\1/p' | head -1
}

# omni_graph_labels <database> <graph> — prints "NODE: a, b" and "EDGE: x, y".
#
# Labels are what GQL matches on, and they are frequently NOT the table names: a
# table `UsedDevice` may declare `LABEL USED_DEVICE`. Getting this wrong gives
# "Failed to find element label", which reads like a broken graph when only the
# query is wrong.
omni_graph_labels() {
  omni_graph_metadata "$1" "$2" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
d = json.loads(raw)
node = sorted({l for t in d.get("nodeTables", []) for l in t.get("labelNames", [])})
edge = sorted({l for t in d.get("edgeTables", []) for l in t.get("labelNames", [])})
print("NODE: " + ", ".join(node))
print("EDGE: " + ", ".join(edge))
'
}

# --- the Python client (optional) -------------------------------------------
#
# Needed only by connect/export.py. The demos themselves never touch it.

REPO_ROOT_GUESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${OMNI_VENV:=$REPO_ROOT_GUESS/.venv}"

omni_python() {
  if [ -x "$OMNI_VENV/bin/python" ]; then
    "$OMNI_VENV/bin/python" "$@"
  else
    python3 "$@"
  fi
}

omni_client_available() {
  omni_python -c 'import google.cloud.spanner' >/dev/null 2>&1
}
