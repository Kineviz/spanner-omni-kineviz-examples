#!/usr/bin/env bash
# stream.sh — replay the PaySim transactions into Spanner Omni through Kafka.
#
# Sourced, never executed. `./gxr stream up <slug>` is the entry point.
#
# A no-op on the normal path — gxr sets the same options before it sources this
# file. It is here anyway, and near the top where a reader and CI both look for
# it: the guarantee that a failure aborts rather than being stepped over belongs
# to the file that makes it, not to whoever happened to source it.
set -euo pipefail

# WHY THIS EXISTS
#
# `./gxr up` builds the graph in one shot and it never moves again. That is the
# right shape for a demo you query, and the wrong one for a demo you WATCH. This
# replays the same 12,033 transactions through a broker on compressed time, so
# the graph fills while someone is looking at it.
#
# It never touches the actors. Clients, merchants, banks and identifiers stay
# exactly as `up` loaded them — the stream carries transactions, and a transaction
# whose sender does not exist could not be written at all (GraphEdge is
# INTERLEAVE IN PARENT GraphNode). What clears and refills is the fact stream:
# ~12k :transaction nodes and the ~24k edges hanging off them, 88% of the graph.
#
# Nothing here starts, stops or removes the Spanner Omni deployment. The sink
# reaches it on the host, and `stream down` leaves every landed row in place.

# Defaults must mirror the ${VAR:-default} values in streaming/docker-compose.yml.
# Change one in both places or they drift.
#
# The ports and the project name are deliberately NOT the Postgres repo's
# (9092/8082, project `paysim-stream`). Both stacks get run on the same laptop.
: "${STREAM_PROJECT:=paysim-schemaless-stream}"
: "${KAFKA_VERSION:=4.3.1}"          # apache/kafka image tag — pinned, never latest
: "${KAFKA_PORT:=9094}"              # host port for clients on your machine
: "${KAFKA_UI_PORT:=8084}"           # kafbat/kafka-ui, under the `ui` profile
: "${KAFKA_UI_IMAGE:=ghcr.io/kafbat/kafka-ui:v1.5.0}"
: "${KAFKA_TOPIC:=paysim.transactions}"
: "${KAFKA_PARTITIONS:=3}"
: "${KAFKA_GROUP:=paysim-schemaless-sink}"
: "${STREAM_HOUR_SECONDS:=0.167}"    # wall seconds per simulated hour (30 sim-days ≈ 2 min)
: "${STREAM_RATE:=}"                 # set to a number for flat tx/s instead
: "${STREAM_UI:=on}"                 # include the Kafka web UI container

# gxr sets REPO_ROOT; a demo script sourcing this through common.sh does not, so
# derive it from this file's own location the way omni.sh does. Both land on the
# same directory, and teardown.sh needs stream_down without going through gxr.
STREAM_REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STREAM_DIR="$STREAM_REPO_ROOT/streaming"
STREAM_COMPOSE_FILE="$STREAM_DIR/docker-compose.yml"

# The labels the stream owns. Everything else in the graph belongs to `up` and is
# never touched by anything in this file.
STREAM_EDGE_LABELS="'performs','to_client','to_merchant','to_bank'"
STREAM_NODE_LABEL="transaction"

require_compose() {
  require_cli docker
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (v2) is not available." \
           "Install Docker Desktop, or a docker with the compose plugin."
}

stream_compose() {
  if [ "$STREAM_UI" = "on" ]; then
    docker compose -p "$STREAM_PROJECT" -f "$STREAM_COMPOSE_FILE" --profile ui "$@"
  else
    docker compose -p "$STREAM_PROJECT" -f "$STREAM_COMPOSE_FILE" "$@"
  fi
}

# Run a Kafka admin tool inside the broker container. Bash 3.2 on macOS has no
# arrays worth using here, so this stays positional.
#
# Every caller bootstraps on broker:29092, never localhost:9092: an admin client
# is handed back the ADVERTISED address of whichever listener it reached, and the
# host listener advertises localhost:$KAFKA_PORT — a port nothing listens on
# inside the container. The symptom is a hang ending in "Timed out waiting for a
# node assignment", which reads like a dead broker rather than a wrong address.
stream_kafka_cli() {
  local tool="$1"; shift
  docker exec -i "$(stream_compose ps -q broker)" "/opt/kafka/bin/$tool" "$@"
}

stream_broker_running() {
  local id
  id=$(stream_compose ps -q broker 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  [ "$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)" = "running" ]
}

# How many transactions have landed. This is the number `status` reports and the
# number the Kineviz dashboard's first KPI shows.
stream_landed() {
  omni_sql_scalar "$OMNI_DATABASE" \
    "SELECT COUNT(*) FROM GraphNode WHERE label = '$STREAM_NODE_LABEL'" 2>/dev/null \
    || printf '?'
}

# --- build, or not ------------------------------------------------------------

# A fingerprint of what goes INTO the producer and sink images. Stored on each
# image as the label `gxr.srchash` at build time, so a later run can ask "is this
# image built from the source I have?" locally, without a registry.
#
# The alternative — rebuild every time — is what broke this offline: `--build`
# resolves python:3.12-slim against docker.io before it will even consider the
# cache, and the Dockerfiles pip install, so a from-scratch build needs the
# network twice over.
stream_src_hash() {
  cat "$STREAM_DIR"/producer/* "$STREAM_DIR"/sink/* 2>/dev/null \
    | shasum -a 256 | cut -c1-16
}

stream_image_name() { printf '%s-%s' "$STREAM_PROJECT" "$1"; }

stream_image_hash() {
  docker image inspect --format '{{index .Config.Labels "gxr.srchash"}}' \
    "$(stream_image_name "$1"):latest" 2>/dev/null
}

stream_image_exists() {
  docker image inspect "$(stream_image_name "$1"):latest" >/dev/null 2>&1
}

# Prints one of: current · stale · missing
#
# `stale` covers "built from different source" AND "built before this label
# existed" — an unlabelled image reads as stale, which is the safe direction:
# it asks for a rebuild rather than silently running code nobody can identify.
stream_build_state() {
  local want; want=$(stream_src_hash)
  local svc
  for svc in producer sink; do
    stream_image_exists "$svc" || { printf 'missing'; return; }
    [ "$(stream_image_hash "$svc")" = "$want" ] || { printf 'stale'; return; }
  done
  printf 'current'
}

# --- up ---------------------------------------------------------------------

# Delete the fact stream, leaving the actors alone.
#
# Order is not cosmetic: GraphEdge is INTERLEAVE IN PARENT GraphNode with no
# ON DELETE CASCADE, so deleting a transaction node while its edges still point
# at it is an error. Children first, always.
stream_clear() {
  info "clearing the transaction stream so the replay is visible (--keep to skip)"
  omni_sql "$OMNI_DATABASE" \
    "DELETE FROM GraphEdge WHERE label IN ($STREAM_EDGE_LABELS)" >/dev/null \
    || die "Could not clear the streamed edges." \
           "If this says the deployment is read-only, it has passed the 90-day write window. See docs/PREVIEW_NOTES.md"
  omni_sql "$OMNI_DATABASE" \
    "DELETE FROM GraphNode WHERE label = '$STREAM_NODE_LABEL'" >/dev/null \
    || die "Could not clear the streamed nodes." "See the error above."
  ok "graph is down to its actors — $(stream_landed) transactions"
}

stream_up() {
  local demo_dir="$1" keep="${2:-}"
  require_compose
  omni_require_running

  local data_dir="$demo_dir/data/generated"
  [ -f "$data_dir/transactions.csv" ] || die \
    "No generated data at $data_dir." \
    "Run './gxr up ${demo_dir##*/}' first — the producer replays the generated transactions.csv."

  # Replaying onto a full database is a demo where nothing happens: every row the
  # sink writes is insert_or_update against a key that already holds exactly that
  # value. Clearing first is what makes the replay visible. --keep skips it, which
  # is how you demonstrate the idempotency instead of the movement.
  if [ "$keep" = "--keep" ]; then
    info "keeping what is already landed — the replay will be a no-op by primary key"
  else
    stream_clear
  fi

  # The producer container sees the generated data read-only at /data.
  STREAM_DATA_DIR="$data_dir"
  export STREAM_DATA_DIR

  # Build only when the images do not already match the source. `--build` on
  # every run is what made this need the network: it resolves the base image
  # against docker.io before it will look at the cache, and the Dockerfiles pip
  # install, so a rebuild wants the network twice. With the hashes matching there
  # is nothing to fetch and nothing to build, so the stack starts disconnected.
  local state; state=$(stream_build_state)
  STREAM_SRC_HASH=$(stream_src_hash)
  export STREAM_SRC_HASH

  local build_flag=""
  case "$state" in
    current)
      info "starting the streaming stack (images already built from this source)"
      ;;
    stale|missing)
      [ "$state" = missing ] \
        && info "building the producer and sink images (first run needs the network)" \
        || info "source changed since the images were built — rebuilding"
      build_flag="--build"
      ;;
  esac

  if ! stream_compose up -d $build_flag --quiet-pull; then
    # A failed build with usable images almost always means no network. Say that
    # rather than leaving a BuildKit dump as the last word, and run what we have.
    if [ -n "$build_flag" ] && [ "$state" = stale ]; then
      warn "could not rebuild — starting the images that are already here"
      dim "the running producer/sink are older than $STREAM_DIR; rerun with a network to refresh them"
      stream_compose up -d --quiet-pull \
        || die "docker compose could not start the streaming stack." \
               "Inspect it: docker compose -p $STREAM_PROJECT -f $STREAM_COMPOSE_FILE logs"
    elif [ "$state" = missing ]; then
      die "The producer and sink images do not exist yet and could not be built." \
          "That first build needs a network. With one, run: ./gxr offline prepare"
    else
      die "docker compose could not start the streaming stack." \
          "Inspect it: docker compose -p $STREAM_PROJECT -f $STREAM_COMPOSE_FILE logs"
    fi
  fi

  # `up -d` returns as soon as the containers exist, which is well before Kafka
  # elects itself in KRaft mode. Wait for the broker to answer its own admin CLI
  # before claiming success.
  local waited=0 max=90
  info "waiting for the broker to accept admin requests"
  while [ "$waited" -lt "$max" ]; do
    if stream_kafka_cli kafka-topics.sh --bootstrap-server broker:29092 --list >/dev/null 2>&1; then
      ok "broker ready after ${waited}s"
      if [ -n "$STREAM_RATE" ]; then
        ok "producer replaying flat at ${STREAM_RATE} tx/s into '$KAFKA_TOPIC'"
      elif [ "$STREAM_HOUR_SECONDS" = "0" ]; then
        ok "producer replaying into '$KAFKA_TOPIC' as fast as the broker accepts (no pacing)"
      else
        # Read here, not at source time: PAYSIM_DAYS arrives with load_env, which
        # runs after this file is sourced. The estimate then tracks the dataset
        # instead of a number typed once and left to rot.
        local days="${PAYSIM_DAYS:-30}" eta
        eta=$(awk -v h="$((days * 24))" -v s="$STREAM_HOUR_SECONDS" 'BEGIN{printf "%d", h*s}')
        ok "producer replaying into '$KAFKA_TOPIC' at 1 sim-hour ≈ ${STREAM_HOUR_SECONDS}s (all ${days} days in ~${eta}s)"
      fi
      info "watch it in Kineviz — the dashboard KPIs refresh on their own"
      [ "$STREAM_UI" = "on" ] && info "Kafka UI: http://localhost:${KAFKA_UI_PORT}"
      dim "progress: ./gxr stream status   ·   logs: docker compose -p $STREAM_PROJECT logs -f producer sink"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  die "The Kafka broker did not become ready within ${max}s." \
      "Check: docker compose -p $STREAM_PROJECT -f $STREAM_COMPOSE_FILE logs broker"
}

# --- status -----------------------------------------------------------------

# The verify for this leg: produced vs. lag vs. landed. Three numbers that
# together say whether the pipe is moving, stuck, or done.
#
# On a terminal this WATCHES instead of printing once, because the interesting
# thing about a replay is that the numbers move. Redirect it, ask for --json, or
# pass --once and it goes back to a single snapshot, so scripts and CI see the
# same output they always did.

# Total messages on the topic. Costs ~1.5s — it starts a JVM inside the broker —
# so the live loop calls it sparingly rather than every frame.
stream_produced() {
  stream_kafka_cli kafka-get-offsets.sh \
      --bootstrap-server broker:29092 --topic "$KAFKA_TOPIC" 2>/dev/null \
    | awk -F: '{s+=$NF} END {printf "%d", s}'
}

# How many transactions the replay will deliver in total, read from the file the
# producer is replaying. Free, and it is the honest denominator: the topic's
# offset count grows on every re-run, so using THAT as the total would make a
# second replay read as 200% done.
stream_total() {
  local csv="$1/data/generated/transactions.csv"
  [ -f "$csv" ] || { printf '0'; return; }
  awk 'END {printf "%d", NR - 1}' "$csv"
}

# A bar, e.g. ███████░░░░░░░░. Bash 3.2 on macOS, so no fancy string repeat.
stream_bar() {
  local done_n="$1" total="$2" width="${3:-24}" i filled
  [ "$total" -gt 0 ] 2>/dev/null || { printf '%*s' "$width" ""; return; }
  filled=$(( done_n * width / total ))
  [ "$filled" -gt "$width" ] && filled="$width"
  i=0; while [ "$i" -lt "$filled" ]; do printf '█'; i=$((i + 1)); done
  while [ "$i" -lt "$width" ]; do printf '░'; i=$((i + 1)); done
}

stream_snapshot() {
  printf '\n  containers:\n'
  # Indent with sed, not in the Go template: compose strips leading whitespace
  # from --format, so the literal spaces there are silently dropped.
  stream_compose ps --format '{{.Service}}\t{{.Status}}' 2>/dev/null | sed 's/^/    /' \
    || stream_compose ps | sed 's/^/    /'

  local produced; produced=$(stream_produced) || produced="?"
  printf '\n  topic %s: %s message(s) produced\n' "$KAFKA_TOPIC" "${produced:-?}"

  stream_kafka_cli kafka-consumer-groups.sh --bootstrap-server broker:29092 \
      --describe --group "$KAFKA_GROUP" 2>/dev/null \
    | awk 'NR<=1 || /paysim/' | sed 's/^/    /' || true

  if omni_running; then
    printf '\n  database %s: %s transaction(s) landed\n\n' \
      "$OMNI_DATABASE" "$(stream_landed)"
  else
    printf '\n  database %s: not reachable (is the deployment up? ./gxr omni status)\n\n' \
      "$OMNI_DATABASE"
  fi
}

# Redraw four lines in place until the replay drains or the watcher gives up.
stream_watch() {
  local demo_dir="$1"
  local total; total=$(stream_total "$demo_dir")
  local produced; produced=$(stream_produced)

  # Ctrl-C stops WATCHING, not the replay.
  #
  # Two traps, because one is not enough. The INT trap turns the interrupt into a
  # clean exit from the loop with a message. The EXIT trap puts the cursor back
  # whatever happens — a signal can kill the shell outright without the INT
  # handler ever running, and a terminal left with no cursor is a nasty parting
  # gift for something that was only ever a read-only view.
  local interrupted=0
  trap 'printf "\033[?25h"' EXIT
  trap 'interrupted=1' INT TERM
  printf '\033[?25l'                      # hide the cursor while redrawing

  local first=1 ticks=0 landed=0 prev=-1 rate=0
  local t0 start_landed
  t0=$(date +%s); start_landed=$(stream_landed)
  [ "$start_landed" -eq "$start_landed" ] 2>/dev/null || start_landed=0

  while [ "$interrupted" = 0 ]; do
    landed=$(stream_landed)
    [ "$landed" -eq "$landed" ] 2>/dev/null || landed=0

    local elapsed=$(( $(date +%s) - t0 ))
    [ "$elapsed" -gt 0 ] && rate=$(( (landed - start_landed) / elapsed ))

    # The topic total is expensive, so refresh it every ~15s rather than every
    # frame. It only moves while the producer is running.
    ticks=$((ticks + 1))
    if [ $((ticks % 15)) = 0 ]; then produced=$(stream_produced); fi

    local pct=0
    [ "$total" -gt 0 ] && pct=$(( landed * 100 / total ))

    local eta="—"
    if [ "$rate" -gt 0 ] && [ "$total" -gt "$landed" ]; then
      eta="~$(( (total - landed) / rate ))s left"
    elif [ "$landed" -ge "$total" ] && [ "$total" -gt 0 ]; then
      eta="done"
    fi

    local behind=$((produced - landed))
    [ "$behind" -lt 0 ] && behind=0

    [ "$first" = 1 ] || printf '\033[4A'   # back up over the four lines below
    first=0
    printf '\033[K\n'
    printf '\033[K  %s%s -> Kafka -> Spanner Omni%s   %s\n' \
      "$_c_dim" "$KAFKA_TOPIC" "$_c_reset" \
      "$([ "$landed" -ge "$total" ] && [ "$total" -gt 0 ] && printf 'drained' || printf 'replaying')"
    printf '\033[K  landed   %s  %s / %s  %s%%\n' \
      "$(stream_bar "$landed" "$total")" "$landed" "$total" "$pct"
    printf '\033[K  %s%s tx/s · %s · %s behind the topic%s\n' \
      "$_c_dim" "$rate" "$eta" "$behind" "$_c_reset"

    # Done when everything produced has landed AND the producer has finished.
    # Both halves matter: equal counts mid-replay just means the sink is keeping
    # up, which is the normal state, not the end.
    if [ "$total" -gt 0 ] && [ "$landed" -ge "$total" ] && [ "$behind" = 0 ]; then
      break
    fi
    [ "$landed" = "$prev" ] || prev="$landed"
    sleep 1
  done

  printf '\033[?25h'                      # cursor back
  trap - INT TERM EXIT
  if [ "$interrupted" = 1 ]; then
    printf '\n'
    dim "stopped watching — the replay is still running"
  else
    printf '\n'
    ok "all $total transaction(s) landed"
  fi
}

stream_status() {
  local slug="${1:-paysim-schemaless}" demo_dir="${2:-}" once="${3:-}"
  require_compose

  if ! stream_broker_running; then
    info "streaming stack is not running"
    dim "start it with: ./gxr stream up $slug"
    return 0
  fi

  # A snapshot when nobody is watching: piped output, --json, or --once.
  if [ "$GXR_JSON" = 1 ] || [ "$once" = "--once" ] || [ ! -t 1 ] || [ -z "$demo_dir" ]; then
    stream_snapshot
    return 0
  fi
  stream_watch "$demo_dir"
}

# --- down -------------------------------------------------------------------

# Never touches the database. Landed rows stay landed — that is the difference
# between stopping the pipe and undoing what came through it.
stream_down() {
  require_compose
  if [ "${1:-}" = "--volumes" ]; then
    stream_compose down --remove-orphans --volumes >/dev/null 2>&1 || true
    ok "streaming stack removed, including the broker's data volume"
  else
    stream_compose down --remove-orphans >/dev/null 2>&1 || true
    ok "streaming stack stopped (broker data volume kept)"
    dim "remove it too with: ./gxr stream down --volumes"
  fi
  dim "the graph is untouched — clear the streamed transactions with './gxr stream up'"
}
