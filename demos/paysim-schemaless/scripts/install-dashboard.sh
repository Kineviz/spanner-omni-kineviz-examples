#!/usr/bin/env bash
# Put the live dashboard into the Kineviz project that is open.
set -euo pipefail
#
# Not part of the demo lifecycle: `./gxr up` never runs this. A dashboard belongs
# to a project, and this repo does not create projects — you do, in Kineviz, when
# you connect to the proxy.
#
# WHAT IT DOES
#
# Exactly what Kineviz does when you press Save on a dashboard. From
# web/libs/Dashboard/dashboardStore.ts:
#
#   1. POST /api/files/<project>/mkdir   -> /dashboards
#   2. POST /api/files/<project>/write   -> /dashboards/<id>.dashboard.json
#      (falling back to /create on 404 — write does not create)
#   3. rewrite /dashboards/_index.json, the manifest the library lists from
#
# `gxr.files.upload` is deliberately NOT used: it goes through multer, which
# ignores the `path` field and drops everything at the project root, where the
# dashboard library will not find it.
#
# HOW IT FINDS THINGS
#
# Both the server and the project are detected, because the project id is
# something you would otherwise have to copy out of the URL.
#
#   the server   Kineviz Desktop persists its port to
#                <userData>/desktop-settings.json (desktop/desktop-settings.js),
#                so that file is read first, then KINEVIZ_DESKTOP_PORT, the
#                desktop default, and finally the ports a dev server uses. The
#                first one that answers the project API wins.
#
#   the project  NOT "the most recently opened", which would install into
#                whatever you happened to look at last. The project list carries
#                each project's connection, so this picks the project actually
#                pointed at THIS demo's proxy. If more than one is, the most
#                recently active of those wins; if none is, it stops and says so
#                rather than guessing.
#
# USAGE
#
#   ./scripts/install-dashboard.sh                    # detect both
#   ./scripts/install-dashboard.sh <projectId>        # force the project
#   ./scripts/install-dashboard.sh --url http://host:port
#
# KINEVIZ_URL in the environment does the same as --url.

source "$(dirname "${BASH_SOURCE[0]}")/../../../shared/lib/common.sh"
eval "$(parse_common_flags "$@")"
# shellcheck disable=SC2034  # read by the logging helpers in common.sh
GXR_STEP=dashboard
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_FILE="$DEMO_DIR/kineviz/paysim-live.dashboard.json"

PROJECT_ID=""
KINEVIZ_URL="${KINEVIZ_URL:-}"
want_url=0
for arg in "$@"; do
  if [ "$want_url" = 1 ]; then KINEVIZ_URL="${arg%/}"; want_url=0; continue; fi
  case "$arg" in
    --json) ;;
    --url)  want_url=1 ;;
    http*)  KINEVIZ_URL="${arg%/}" ;;
    -*)     die "Unknown flag: $arg" \
              "Usage: ./scripts/install-dashboard.sh [projectId] [--url http://host:port]" ;;
    *)      PROJECT_ID="$arg" ;;
  esac
done
[ "$want_url" = 0 ] || die "--url needs an address after it." \
  "Example: --url http://127.0.0.1:31380"

step "Installing the live dashboard"

[ -f "$SPEC_FILE" ] || die "Dashboard spec not found: $SPEC_FILE" "Check the checkout."
require_cli curl python3
load_env "$DEMO_DIR"
require_env PROXY_PORT PROXY_PROJECT

# The proxy URL this demo's project must be connected to. Same string
# `./gxr connect up` prints and you paste into the Kineviz connect dialog.
DEMO_PROXY_URL="http://127.0.0.1:${PROXY_PORT}/api/spanner/${PROXY_PROJECT}"

# --- find the server --------------------------------------------------------

# Answers only if this is a Kineviz serving the project API.
kineviz_answers() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 4 \
      "$1/api/graph/neo4j/project/recent" 2>/dev/null)" = "200" ]
}

# Ports Kineviz Desktop has actually used on this machine. Desktop keeps its port
# stable across restarts by persisting it, precisely so integrations can find it
# again — reading that file beats guessing.
desktop_ports() {
  local d
  # macOS and Linux userData locations. No Windows path: nothing else in this
  # repo runs there, and guessing %APPDATA% would be the only untested branch.
  for d in "$HOME/Library/Application Support"/{kineviz-desktop,graphxr,graphxr-viewer,Electron} \
           "$HOME/.config"/{kineviz-desktop,graphxr}; do
    [ -f "$d/desktop-settings.json" ] || continue
    python3 -c '
import json, sys
try:
    port = json.load(open(sys.argv[1])).get("serverPort")
except Exception:
    raise SystemExit
if isinstance(port, int) and port > 0:
    print(port)' "$d/desktop-settings.json" 2>/dev/null
  done
}

if [ -n "$KINEVIZ_URL" ]; then
  kineviz_answers "$KINEVIZ_URL" || die \
    "No Kineviz project API at $KINEVIZ_URL." \
    "Check the address, or drop --url and let this find it."
  info "using $KINEVIZ_URL"
else
  # Desktop's own port first, then its default, then the ports a dev server
  # binds. 31380 is desktop/desktop-settings.js's HARDCODED_FALLBACK_PORT.
  for port in $(desktop_ports) "${KINEVIZ_DESKTOP_PORT:-}" 31380 80 8080 3000; do
    [ -n "$port" ] || continue
    if kineviz_answers "http://127.0.0.1:$port"; then
      KINEVIZ_URL="http://127.0.0.1:$port"
      break
    fi
  done
  [ -n "$KINEVIZ_URL" ] || die \
    "Could not find a running Kineviz." \
    "Start Kineviz Desktop, or point at it: ./scripts/install-dashboard.sh --url http://host:port"
  ok "found Kineviz at $KINEVIZ_URL"
fi

# --- find the project -------------------------------------------------------

if [ -n "$PROJECT_ID" ]; then
  info "using the project you named: $PROJECT_ID"
else
  projects=$(curl -fsS -m 20 "$KINEVIZ_URL/api/graph/neo4j/project/list" 2>/dev/null) \
    || die "Could not list projects from $KINEVIZ_URL." "Is this Kineviz signed in?"
  recent=$(curl -fsS -m 20 "$KINEVIZ_URL/api/graph/neo4j/project/recent" 2>/dev/null || printf '')

  detected=$(PROJECTS="$projects" RECENT="$recent" DEMO_PROXY_URL="$DEMO_PROXY_URL" python3 <<'PYEOF'
import json, os, sys

def norm(url):
    """127.0.0.1 and localhost are the same host typed two ways."""
    u = (url or "").strip().rstrip("/").lower()
    return u.replace("//localhost:", "//127.0.0.1:")

want = norm(os.environ["DEMO_PROXY_URL"])

try:
    projects = json.loads(os.environ["PROJECTS"]).get("content") or []
except Exception:
    sys.exit("could not parse the project list")

# Most-recently-active order, used only to break a tie between projects that are
# all connected to this demo.
order = {}
try:
    for i, r in enumerate(json.loads(os.environ.get("RECENT") or "{}").get("content") or []):
        order[r.get("_id")] = i
except Exception:
    pass

matches = [p for p in projects if norm(p.get("hostname")) == want]
matches.sort(key=lambda p: order.get(p.get("_id"), 10**6))

if matches:
    p = matches[0]
    print("MATCH	%s	%s	%d" % (p["_id"], p.get("projectName") or "(unnamed)", len(matches)))
else:
    # Nothing to install into. List the proxy projects that DO exist so the
    # message is actionable instead of just negative.
    others = [p for p in projects if p.get("databaseType") == "databaseProxy"]
    print("NONE	%s" % "; ".join(
        "%s -> %s" % (p.get("projectName") or "(unnamed)", p.get("hostname") or "?")
        for p in others[:5]))
PYEOF
  ) || die "Could not work out which project to use." "Pass the id: ./scripts/install-dashboard.sh <projectId>"

  case "$detected" in
    MATCH*)
      PROJECT_ID=$(printf '%s' "$detected" | cut -f2)
      pname=$(printf '%s' "$detected" | cut -f3)
      count=$(printf '%s' "$detected" | cut -f4)
      ok "detected project '$pname' ($PROJECT_ID)"
      [ "$count" -gt 1 ] && dim "$count projects point at this demo; picked the most recently active"
      ;;
    NONE*)
      others=$(printf '%s' "$detected" | cut -f2)
      die "No Kineviz project is connected to this demo's proxy ($DEMO_PROXY_URL)." \
          "Create one: New project -> Database Proxy -> $DEMO_PROXY_URL
     Run './gxr connect up paysim-schemaless' first if the proxy is not up.
     Database Proxy projects found: ${others:-none}"
      ;;
  esac
fi

files_post() {  # files_post <endpoint> <json-body> — prints the HTTP status
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST "$KINEVIZ_URL/api/files/$PROJECT_ID/$1" \
    -H 'Content-Type: application/json' --data "$2"
}

DASH_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$SPEC_FILE")
DASH_PATH="dashboards/$DASH_ID.dashboard.json"

# 1 — the folder. Already existing is the normal case, not an error.
files_post mkdir '{"path":"dashboards"}' >/dev/null
info "ensured /dashboards exists"

# 2 — the spec. `write` does not create, so a 404 means "first time".
body=$(python3 -c '
import json, sys
spec = json.load(open(sys.argv[1]))
print(json.dumps({"path": sys.argv[2], "content": json.dumps(spec, indent=2)}))' \
  "$SPEC_FILE" "$DASH_PATH")
code=$(files_post write "$body")
if [ "$code" = "404" ]; then
  code=$(files_post create "$body")
fi
[ "$code" -lt 400 ] 2>/dev/null || die \
  "Could not write $DASH_PATH (HTTP $code)." \
  "Check that project $PROJECT_ID exists and that $KINEVIZ_URL is the right Kineviz."
ok "wrote /$DASH_PATH"

# 3 — the manifest, which is what the dashboard library actually lists from. Read
# it first so installing this does not delete someone else's dashboards, and keep
# their entry for this id if it is a re-install (favourite, rail pin).
# Reading a file is /download?path=..., not a GET on the path itself — a GET on
# the path hits no route at all and comes back as a 404 envelope, which parses as
# "no dashboards yet" and would quietly drop every other dashboard from the
# manifest. Same endpoint gxr.files.get uses (web/libs/Files/getFile.ts).
current=$(curl -fsS --max-time 20 \
  "$KINEVIZ_URL/api/files/$PROJECT_ID/download?path=%2Fdashboards%2F_index.json" \
  2>/dev/null || printf '')

manifest=$(CURRENT_MANIFEST="$current" python3 - "$SPEC_FILE" "$DASH_PATH" <<'PYEOF'
import json, os, sys, time

spec = json.load(open(sys.argv[1]))
raw = os.environ.get("CURRENT_MANIFEST", "")
try:
    existing = json.loads(raw).get("dashboards", [])
    if not isinstance(existing, list):
        existing = []
except Exception:
    existing = []

# metaForSpec(), from shared/dashboard/store.ts. Kept in step with it by hand;
# the fields the library reads are id / title / path / widgetCount / updatedAt.
meta = {
    "id": spec["id"],
    "title": spec["title"],
    "icon": spec.get("icon"),
    "path": "/" + sys.argv[2],
    "widgetCount": len(spec["widgets"]),
    "updatedAt": int(time.time() * 1000),
    "origin": "manual",
    "layout": [{"w": w["w"], "h": w.get("h", 1), "type": w["type"]} for w in spec["widgets"]],
}

# A re-install keeps whatever the user chose about this card.
for d in existing:
    if d.get("id") == spec["id"]:
        for k in ("fav", "menubar", "menubarSide", "railIcon"):
            if d.get(k):
                meta[k] = d[k]

others = [d for d in existing if d.get("id") != spec["id"]]
print(json.dumps({"dashboards": others + [meta]}, indent=2))
PYEOF
)

body=$(MANIFEST="$manifest" python3 -c '
import json, os
print(json.dumps({"path": "dashboards/_index.json", "content": os.environ["MANIFEST"]}))')
code=$(files_post write "$body")
if [ "$code" = "404" ]; then
  code=$(files_post create "$body")
fi
[ "$code" -lt 400 ] 2>/dev/null || die \
  "Wrote the dashboard but could not update the manifest (HTTP $code)." \
  "The file is at /$DASH_PATH; the library lists from /dashboards/_index.json."
ok "registered '$DASH_ID' in the dashboard library"

[ "$GXR_JSON" = 1 ] && exit 0
cat <<EOF

✅ The dashboard is in project $PROJECT_ID.

   Open it: the Dashboard icon in the left rail → PaySim · live

   Its four database widgets re-run every 2 seconds, so start the stream and
   watch them climb without touching anything:

     ./gxr stream up paysim-schemaless

EOF
