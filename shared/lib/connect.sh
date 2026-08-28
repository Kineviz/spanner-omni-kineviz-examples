#!/usr/bin/env bash
# connect.sh — install, run and register the Kineviz database proxy.
#
# Sourced, never executed. `./gxr connect up <slug>` is the entry point.
#
# A no-op on the normal path — gxr sets the same options before it sources this
# file. It is here anyway, and near the top where a reader and CI both look for
# it: the guarantee that a failure aborts rather than being stepped over belongs
# to the file that makes it, not to whoever happened to source it.
set -euo pipefail

# WHY THIS EXISTS
#
# Kineviz has no native Spanner Omni connector. The route that works is
# graphxr-database-proxy with a small driver swap, and doing that by hand is
# six steps (clone, venv, install, copy driver, edit factory, run, register).
# Six steps is where a demo dies. This is those six steps, idempotent.
#
# Everything lands in .connect/ at the repo root, which is gitignored. Nothing
# here touches the Spanner Omni deployment.

: "${PROXY_REPO:=https://github.com/Kineviz/graphxr-database-proxy}"

# Pinned, for the same reason OMNI_VERSION is pinned. This is the commit
# connect/proxy/spanner_omni_driver.py was written against and tested on.
: "${PROXY_REF:=cfdcadf1ea0e542259069d031a95648e214e0605}"

CONNECT_DIR="$REPO_ROOT/.connect"
PROXY_DIR="$CONNECT_DIR/proxy"
PROXY_VENV="$PROXY_DIR/.venv"
PROXY_PID="$CONNECT_DIR/proxy.pid"
PROXY_LOG="$CONNECT_DIR/proxy.log"

proxy_base_url() { printf 'http://127.0.0.1:%s' "${PROXY_PORT:-9080}"; }
proxy_api_url()  { printf '%s/api/spanner/%s' "$(proxy_base_url)" "${PROXY_PROJECT:?}"; }

# The pid of a proxy started from THIS repo's .connect/proxy, found by its
# command line rather than by the pidfile. Needed because `rm -rf .connect`
# deletes the pidfile and orphans a running process — after which `connect down`
# has nothing to stop and `connect up` correctly refuses the busy port, leaving
# someone stuck with no obvious way out.
#
# Matching on $PROXY_DIR is what makes killing it safe: it can only ever match a
# process launched from this checkout, never someone else's proxy on the port.
proxy_orphan_pid() {
  pgrep -f "$PROXY_DIR/.venv/bin/python" 2>/dev/null | head -1
}

proxy_running() {
  [ -f "$PROXY_PID" ] || return 1
  kill -0 "$(cat "$PROXY_PID")" 2>/dev/null
}

# --- install ----------------------------------------------------------------

proxy_install() {
  require_cli git python3

  if [ ! -d "$PROXY_DIR/.git" ]; then
    info "cloning the database proxy into .connect/proxy (pinned at ${PROXY_REF:0:7})"
    mkdir -p "$CONNECT_DIR"
    git clone --quiet "$PROXY_REPO" "$PROXY_DIR" \
      || die "Could not clone $PROXY_REPO." \
             "Check network access, or clone it yourself into .connect/proxy and re-run."
  fi
  git -C "$PROXY_DIR" fetch --quiet origin 2>/dev/null || true
  git -C "$PROXY_DIR" checkout --quiet "$PROXY_REF" 2>/dev/null \
    || die "Could not check out the pinned proxy commit $PROXY_REF." \
           "Update PROXY_REF in shared/lib/connect.sh only deliberately — the Omni driver is written against it."
  ok "proxy source at ${PROXY_REF:0:7}"

  if [ ! -x "$PROXY_VENV/bin/python" ]; then
    info "creating a virtualenv for the proxy"
    python3 -m venv "$PROXY_VENV" \
      || die "Could not create a virtualenv at .connect/proxy/.venv." \
             "Check that python3 ships venv: python3 -m venv --help"
  fi

  # ALWAYS reinstall requirements, cheap when satisfied. The proxy's driver
  # registry imports every driver at module load, so a requirement missing for
  # a driver you do not use still breaks the one you do: without httpx, the
  # RocketGraph import fails and takes the Spanner route down with it.
  info "installing proxy requirements"
  "$PROXY_VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  "$PROXY_VENV/bin/python" -m pip install --quiet -r "$PROXY_DIR/requirements.txt" \
    || die "Installing the proxy's requirements failed." \
           "Read the error above. See .connect/proxy/requirements.txt"

  # google-cloud-spanner is a proxy requirement, but the Omni driver needs a
  # floor the proxy itself does not declare.
  "$PROXY_VENV/bin/python" -m pip install --quiet 'google-cloud-spanner>=3.65.0' \
    || die "Could not install google-cloud-spanner>=3.65.0." \
           "The Omni driver needs it for the plain-text endpoint options."
  ok "requirements installed"

  proxy_apply_driver
}

# Copy the Omni driver in and register it. Idempotent: re-running is a no-op.
proxy_apply_driver() {
  local drivers="$PROXY_DIR/src/graphxr_database_proxy/drivers"
  [ -d "$drivers" ] || die "The proxy checkout has no drivers/ directory." \
    "Remove .connect/proxy and re-run './gxr connect up' to reinstall it."

  cp "$REPO_ROOT/connect/proxy/spanner_omni_driver.py" "$drivers/spanner_omni_driver.py" \
    || die "Could not copy the Omni driver into the proxy." "Check permissions on .connect/proxy."

  python3 - "$drivers/factory.py" <<'PY' || die "Could not register the Omni driver in factory.py." \
      "Edit it by hand: import SpannerOmniDriver and map DatabaseType.SPANNER to it."
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "spanner_omni_driver" not in s:
    s = s.replace("from .spanner import SpannerDriver",
                  "from .spanner import SpannerDriver\nfrom .spanner_omni_driver import SpannerOmniDriver", 1)
s = s.replace("DatabaseType.SPANNER: SpannerDriver,",
              "DatabaseType.SPANNER: SpannerOmniDriver,   # was SpannerDriver", 1)
p.write_text(s)
if "SpannerOmniDriver" not in s:
    raise SystemExit("factory.py did not contain the expected SpannerDriver registration")
PY
  ok "Omni driver applied (DatabaseType.SPANNER -> SpannerOmniDriver)"
}

# --- run --------------------------------------------------------------------

# Is anything listening on the proxy port? Python rather than lsof/ss, which
# differ across macOS and Linux and are not always installed.
port_in_use() {
  python3 -c '
import socket, sys
s = socket.socket()
s.settimeout(0.5)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
' "${PROXY_PORT:-9080}" 2>/dev/null
}

# Fail before doing any work if the port is taken by something we cannot
# manage. Called first by `connect up` so a busy port does not cost a clone and
# a pip install before it is noticed.
proxy_port_available() {
  proxy_running && return 0          # ours, already up: nothing to check
  port_in_use || return 0            # free

  local orphan; orphan=$(proxy_orphan_pid)
  if [ -n "$orphan" ]; then
    die "Port ${PROXY_PORT:-9080} is held by a proxy this repo started (pid $orphan), but its pidfile is gone." \
        "Stop it with './gxr connect down' — that now finds it by its command line — then re-run."
  fi
  die "Port ${PROXY_PORT:-9080} is already in use, and not by a proxy this repo started." \
      "Stop whatever is on it, or set PROXY_PORT to a free port in the demo's .env. To find it: lsof -nP -iTCP:${PROXY_PORT:-9080} -sTCP:LISTEN"
}

proxy_start() {
  if proxy_running; then
    ok "proxy already running on $(proxy_base_url) (pid $(cat "$PROXY_PID"))"
    return 0
  fi

  # Refuse to adopt a stranger. Without this check the readiness poll below
  # would see SOMETHING answering on the port, call it success, and hand back a
  # URL served by a process we do not control — while the one we just launched
  # died of "address already in use". That failure is silent, and the symptom
  # surfaces much later as a confusing error from an unrelated request.
  proxy_port_available

  # 127.0.0.1, never 0.0.0.0. This fronts a deployment with no TLS and no
  # authentication; anyone who can reach it owns every database on it.
  info "starting the proxy on $(proxy_base_url)"
  # `exec`, and the `&` outside the parentheses, so the pid we record is the
  # PROXY's. Without exec, bash forks a subshell to run the `cd && ...` compound,
  # `$!` names that subshell, and the python it launches gets the next pid — so
  # `connect down` killed a wrapper and left the real proxy holding port 9080.
  ( cd "$PROXY_DIR" && PYTHONPATH=. exec nohup "$PROXY_VENV/bin/python" -m uvicorn \
      src.graphxr_database_proxy.main:app --host 127.0.0.1 --port "${PROXY_PORT:-9080}" \
      >"$PROXY_LOG" 2>&1 ) & echo $! >"$PROXY_PID"

  local _attempt
  for _attempt in $(seq 1 40); do
    # Our process first: a dead child plus a live port means something else is
    # answering, and calling that success is the bug this ordering avoids.
    proxy_running || break
    if curl -fsS -o /dev/null "$(proxy_base_url)/docs" 2>/dev/null; then
      ok "proxy responding on $(proxy_base_url)"
      return 0
    fi
    sleep 0.5
  done
  unset _attempt

  local tail_out; tail_out=$(tail -20 "$PROXY_LOG" 2>/dev/null || true)
  rm -f "$PROXY_PID"
  case "$tail_out" in
    *"No module named"*)
      die "The proxy failed to start: a Python module is missing. $(printf '%s' "$tail_out" | grep -o "No module named '[^']*'" | head -1)" \
          "Reinstall its requirements: rm -rf .connect/proxy/.venv && ./gxr connect up <slug>" ;;
    *"Address already in use"*)
      die "Port ${PROXY_PORT:-9080} is already in use." \
          "Something else is on it. Change PROXY_PORT in the demo's .env, or stop the other process." ;;
    *)
      printf '%s\n' "$tail_out" >&2
      die "The proxy did not come up on $(proxy_base_url)." "See the log: .connect/proxy.log" ;;
  esac
}

proxy_stop() {
  if ! proxy_running; then
    local orphan; orphan=$(proxy_orphan_pid)
    if [ -n "$orphan" ]; then
      kill "$orphan" 2>/dev/null || true
      rm -f "$PROXY_PID"
      ok "stopped an orphaned proxy (pid $orphan) — its pidfile was gone"
      return 0
    fi
    info "proxy is not running"
    rm -f "$PROXY_PID"
    return 0
  fi
  local pid; pid=$(cat "$PROXY_PID")
  kill "$pid" 2>/dev/null || true
  rm -f "$PROXY_PID"

  # Verify rather than assume. Two things have gone wrong here in practice: a
  # pidfile written by an older version names a wrapper rather than the proxy,
  # and a proxy stuck in an uninterruptible call ignores SIGTERM outright. Either
  # way the port stays held and the next `connect up` refuses to start, with the
  # cause several steps back. So confirm the port is free, then escalate.
  local waited=0
  while [ "$waited" -lt 10 ] && port_in_use "${PROXY_PORT:-9080}"; do
    sleep 1; waited=$((waited + 1))
  done
  if port_in_use "${PROXY_PORT:-9080}"; then
    local orphan; orphan=$(proxy_orphan_pid)
    if [ -n "$orphan" ]; then
      kill -9 "$orphan" 2>/dev/null || true
      sleep 1
      ok "proxy stopped — it ignored SIGTERM, so pid $orphan was killed outright"
      return 0
    fi
    warn "port ${PROXY_PORT:-9080} is still held by something this repo did not start"
    dim "find it with: lsof -nP -iTCP:${PROXY_PORT:-9080} -sTCP:LISTEN"
    return 0
  fi
  ok "proxy stopped (the Spanner Omni deployment was not touched)"
}

# --- register ---------------------------------------------------------------

# Create the proxy project that maps a name to this database. Idempotent: an
# existing project of the same name is left alone rather than replaced.
proxy_register() {
  local url; url="$(proxy_base_url)"
  local body
  body=$(python3 - <<PY
import json
print(json.dumps({
  "name": "${PROXY_PROJECT}",
  "database_type": "spanner",
  "database_config": {
    "type": "spanner",
    "host": "${OMNI_HOST}",
    "port": ${OMNI_PORT},
    "database_id": "${OMNI_DATABASE}",
    "graph_name": "${OMNI_GRAPH}",
    # project_id and instance_id are ignored by the Omni driver — a Spanner
    # Omni deployment has exactly one of each, both named "default" — but the
    # proxy's model still expects the fields.
    "project_id": "default",
    "instance_id": "default",
    "auth_type": "oauth2"
  }
}))
PY
)
  local code
  code=$(curl -sS -o "$CONNECT_DIR/register.out" -w '%{http_code}' \
    -X POST "$url/api/project/create" \
    -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo "000")

  # Idempotency is decided by the BODY, not the status code: the proxy wraps
  # its own 400 in a generic handler and re-raises it as a 500, so a project
  # that already exists arrives as "500: 400: ... already exists".
  if grep -q 'already exists' "$CONNECT_DIR/register.out" 2>/dev/null; then
    ok "project '${PROXY_PROJECT}' already registered"
    return 0
  fi

  case "$code" in
    2*) ok "registered project '${PROXY_PROJECT}' -> ${OMNI_DATABASE} / ${OMNI_GRAPH}" ;;
    401|403)
      die "The proxy requires an admin token." \
          "ADMIN_PASSWORD is set in the proxy's environment. Unset it for local use, or create the project in the web UI at $url" ;;
    *)
      printf '%s\n' "$(cat "$CONNECT_DIR/register.out" 2>/dev/null)" >&2
      die "Could not register the project with the proxy (HTTP $code)." \
          "Check that the proxy is up: curl $url/docs" ;;
  esac
}

# Prove the whole chain works before telling anyone it does: the proxy can
# reach Spanner Omni, and the graph really is schemaless.
proxy_check() {
  local url; url="$(proxy_base_url)/api/spanner/${PROXY_PROJECT}"
  local out
  # /test is a POST — it is an action, not a resource. A GET returns 405.
  out=$(curl -fsS -X POST "$url/test" 2>/dev/null) || die \
    "The proxy could not reach Spanner Omni." \
    "Is the deployment running? './gxr omni status'. Then check .connect/proxy.log"
  case "$out" in
    *'"success":true'*) ok "proxy -> Spanner Omni connection verified" ;;
    *) printf '%s\n' "$out" >&2
       die "The proxy reached the endpoint but the connection test failed." \
           "See the response above and .connect/proxy.log" ;;
  esac

  # The schema panel in Kineviz is built from this. On a schemaless graph it
  # must come back with the DATA labels; a single "GraphNode" category means
  # the proxy fell through to static introspection and Kineviz would show one
  # undifferentiated blob.
  local cats
  cats=$(curl -fsS "$url/graphSchema" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
names = [c.get("name") for c in (d.get("data") or {}).get("categories", [])]
print(",".join(n for n in names if n))
' 2>/dev/null || true)

  case "$cats" in
    "") warn "the proxy returned no graph schema — Kineviz will show an empty schema panel."
        dim "see .connect/proxy.log; the schemaless path returns HTTP 200 even when it fails" ;;
    GraphNode|GraphNode,GraphEdge)
        warn "the schema came back as the TABLE names, not the data labels."
        dim "the proxy did not take its schemaless path. Check that sql/01_schema.ddl still declares DYNAMIC LABEL." ;;
    *)  ok "schema discovered from data: $cats" ;;
  esac
}
