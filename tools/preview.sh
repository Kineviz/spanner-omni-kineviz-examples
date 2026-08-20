#!/usr/bin/env bash
#
# Render every markdown file in this repo to a browsable local site.
#
#   ./tools/preview.sh            build, then open in your browser
#   ./tools/preview.sh --no-open  build only, print the path
#
# Why: GitHub's rendering is the real target, but a local preview catches
# broken tables, dead relative links and missing images before you push —
# and it works offline while you are still editing.
#
# Needs pandoc:  brew install pandoc  |  apt install pandoc
# Output goes to .preview/, which is gitignored.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="$ROOT/.preview"
OPEN=1
[ "${1:-}" = "--no-open" ] && OPEN=0

command -v pandoc >/dev/null 2>&1 || {
  echo "pandoc not found." >&2
  echo "  macOS: brew install pandoc" >&2
  echo "  Linux: apt install pandoc" >&2
  exit 1
}

rm -rf "$OUT"; mkdir -p "$OUT"

# Sidebar styling. Theme-aware so it is readable in both light and dark.
cat > "$OUT/style.css" <<'CSS'
:root {
  --bg:#ffffff; --fg:#1f2328; --muted:#59636e; --border:#d1d9e0;
  --link:#0969da; --sidebar:#f6f8fa; --accent:#0969da;
}
@media (prefers-color-scheme: dark) {
  :root { --bg:#0d1117; --fg:#e6edf3; --muted:#9198a1; --border:#3d444d;
          --link:#4493f8; --sidebar:#010409; --accent:#4493f8; }
}
* { box-sizing:border-box; }
body { margin:0; display:flex; min-height:100vh; background:var(--bg); color:var(--fg);
  font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
nav { width:300px; flex:0 0 300px; background:var(--sidebar); border-right:1px solid var(--border);
  padding:20px 0; overflow-y:auto; height:100vh; position:sticky; top:0; }
nav h1 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted);
  margin:22px 20px 8px; font-weight:600; }
nav h1:first-child { margin-top:0; }
nav a { display:block; padding:5px 20px 5px 28px; color:var(--fg); text-decoration:none;
  font-size:13.5px; border-left:2px solid transparent; }
nav a:hover { background:rgba(127,127,127,.12); }
nav a.active { border-left-color:var(--accent); color:var(--accent); font-weight:600;
  background:rgba(127,127,127,.10); }
nav .d { padding:6px 20px 2px; font-size:11.5px; color:var(--muted); font-family:ui-monospace,monospace; }
main { flex:1; min-width:0; }
iframe { width:100%; height:100vh; border:0; display:block; }
CSS

# Document styling, close enough to GitHub to spot layout problems.
cat > "$OUT/doc.css" <<'CSS'
:root {
  --bg:#ffffff; --fg:#1f2328; --muted:#59636e; --border:#d1d9e0;
  --link:#0969da; --code-bg:#f6f8fa; --quote:#59636e; --tblalt:#f6f8fa;
}
@media (prefers-color-scheme: dark) {
  :root { --bg:#0d1117; --fg:#e6edf3; --muted:#9198a1; --border:#3d444d;
          --link:#4493f8; --code-bg:#151b23; --quote:#9198a1; --tblalt:#151b23; }
}
* { box-sizing:border-box; }
body { background:var(--bg); color:var(--fg); max-width:900px; margin:0 auto;
  padding:36px 44px 100px;
  font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
h1,h2,h3,h4 { margin:26px 0 14px; line-height:1.3; font-weight:600; }
h1 { font-size:2em; padding-bottom:.3em; border-bottom:1px solid var(--border); margin-top:0; }
h2 { font-size:1.5em; padding-bottom:.3em; border-bottom:1px solid var(--border); }
h3 { font-size:1.2em; } h4 { font-size:1em; }
a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
p,ul,ol { margin:0 0 14px; } li { margin:.25em 0; }
code { background:var(--code-bg); padding:.2em .4em; border-radius:6px; font-size:85%;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
pre { background:var(--code-bg); padding:16px; border-radius:6px; overflow-x:auto;
  border:1px solid var(--border); }
pre code { background:none; padding:0; font-size:13.5px; line-height:1.5; }
blockquote { margin:0 0 16px; padding:0 1em; color:var(--quote);
  border-left:.25em solid var(--border); }
blockquote p:last-child { margin-bottom:0; }
table { border-collapse:collapse; margin:0 0 16px; display:block; overflow-x:auto; max-width:100%; }
th,td { border:1px solid var(--border); padding:6px 13px; text-align:left; }
th { font-weight:600; background:var(--tblalt); }
tr:nth-child(2n) td { background:var(--tblalt); }
img { max-width:100%; }
/* A missing image renders as a dashed box rather than a bare broken icon,
   so it is obvious which screenshots are still TODO. */
img:not([src^="http"]) { min-width:160px; min-height:48px; border:1px dashed var(--border);
  border-radius:6px; padding:14px; color:var(--muted); font-size:13px; }
hr { border:0; border-top:1px solid var(--border); margin:24px 0; }
.pathbar { font-family:ui-monospace,monospace; font-size:12px; color:var(--muted);
  border-bottom:1px solid var(--border); padding-bottom:10px; margin-bottom:22px; }
CSS

nav_html=""
prev_dir="__none__"
first=""

while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  slug="${rel//\//__}"; slug="${slug%.md}.html"
  [ -z "$first" ] && first="$slug"

  dir=$(dirname "$rel"); [ "$dir" = "." ] && dir="/"
  if [ "$dir" != "$prev_dir" ]; then
    nav_html+="<div class=\"d\">$dir</div>"
    prev_dir="$dir"
  fi
  nav_html+="<a href=\"$slug\" target=\"doc\">$(basename "$rel")</a>"

  {
    printf '<!doctype html><html><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width,initial-scale=1">'
    printf '<link rel="stylesheet" href="doc.css"></head><body>'
    printf '<div class="pathbar">%s</div>' "$rel"
    pandoc -f gfm -t html --syntax-highlighting=none "$f"
    printf '</body></html>'
  } > "$OUT/$slug"
done < <(git ls-files '*.md' | sed "s|^|$ROOT/|" | sort)

cat > "$OUT/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(basename "$ROOT") — docs preview</title>
<link rel="stylesheet" href="style.css"></head>
<body>
<nav id="nav"><h1>$(basename "$ROOT")</h1>$nav_html</nav>
<main><iframe name="doc" src="$first"></iframe></main>
<script>
  const links = [...document.querySelectorAll('#nav a')];
  const mark = h => links.forEach(a => a.classList.toggle('active', a.getAttribute('href') === h));
  links.forEach(a => a.addEventListener('click', () => mark(a.getAttribute('href'))));
  mark('$first');
</script>
</body></html>
HTML

count=$(find "$OUT" -name '*.html' -not -name index.html | wc -l | tr -d ' ')
echo "rendered $count page(s) -> $OUT/index.html"

if [ "$OPEN" = 1 ]; then
  case "$(uname -s)" in
    Darwin) open "$OUT/index.html" ;;
    Linux)  command -v xdg-open >/dev/null 2>&1 && xdg-open "$OUT/index.html" ;;
  esac
fi
