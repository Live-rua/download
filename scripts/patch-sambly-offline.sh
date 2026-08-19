#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-}"
if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR/internal/handlers" ]]; then
  echo "usage: $0 <Sambly source dir>" >&2
  exit 1
fi

HTMX_VERSION="2.0.0"
ALPINE_VERSION="3.14.9"
STATIC_DIR="$SRC_DIR/internal/handlers/static"
mkdir -p "$STATIC_DIR"

curl --fail --location --retry 3 --retry-delay 2 \
  "https://unpkg.com/htmx.org@${HTMX_VERSION}/dist/htmx.min.js" \
  -o "$STATIC_DIR/htmx.min.js"
curl --fail --location --retry 3 --retry-delay 2 \
  "https://cdn.jsdelivr.net/npm/alpinejs@${ALPINE_VERSION}/dist/cdn.min.js" \
  -o "$STATIC_DIR/alpine.min.js"\n
test "$(wc -c < "$STATIC_DIR/htmx.min.js")" -gt 10000
test "$(wc -c < "$STATIC_DIR/alpine.min.js")" -gt 10000

python3 - "$SRC_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
base = root / "internal/handlers/tmpl/base.html"
handlers = root / "internal/handlers/handlers.go"
security = root / "internal/security/security.go"

text = base.read_text()
old_htmx = '<script src="https://unpkg.com/htmx.org@2.0.0/dist/htmx.min.js" defer></script>'
old_alpine = '<script src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js" defer></script>'
if old_htmx not in text or old_alpine not in text:
    raise SystemExit("upstream Sambly CDN tags changed; refusing silent patch")
text = text.replace(old_htmx, '<script src="/static/htmx.min.js" defer></script>')
text = text.replace(old_alpine, '<script src="/static/alpine.min.js" defer></script>')
base.write_text(text)

text = handlers.read_text()
embed_old = '//go:embed tmpl/*.html'
embed_new = '//go:embed tmpl/*.html static/*.js'
if embed_old not in text:
    raise SystemExit("Sambly embed directive changed; refusing silent patch")
text = text.replace(embed_old, embed_new, 1)

route_needle = 'func (h *Handler) RegisterRoutes(mux *http.ServeMux) {\n'
route_insert = route_needle + '\t// Frontend dependencies are embedded so Sambly works with no Internet/DNS.\n\tmux.Handle("/static/", http.FileServer(http.FS(tmplFS)))\n\n'
if route_needle not in text:
    raise SystemExit("RegisterRoutes signature changed; refusing silent patch")
text = text.replace(route_needle, route_insert, 1)

force_needle = '\treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {\n'
force_insert = force_needle + '\t\tif strings.HasPrefix(r.URL.Path, "/static/") {\n\t\t\tnext.ServeHTTP(w, r)\n\t\t\treturn\n\t\t}\n'
if force_needle not in text:
    raise SystemExit("ForcePasswordChange handler changed; refusing silent patch")
text = text.replace(force_needle, force_insert, 1)
handlers.write_text(text)

text = security.read_text()
old_csp = "script-src 'self' 'unsafe-inline' 'unsafe-eval' unpkg.com cdn.jsdelivr.net;"
new_csp = "script-src 'self' 'unsafe-inline' 'unsafe-eval';"
if old_csp not in text:
    raise SystemExit("Sambly CSP changed; refusing silent patch")
security.write_text(text.replace(old_csp, new_csp, 1))
PY

if grep -R -nE 'https://(unpkg\.com|cdn\.jsdelivr\.net)' \
  "$SRC_DIR/internal/handlers/tmpl" "$SRC_DIR/internal/security"; then
  echo "error: external frontend CDN reference remains" >&2
  exit 1
fi

grep -Fq '/static/htmx.min.js' "$SRC_DIR/internal/handlers/tmpl/base.html"
grep -Fq '/static/alpine.min.js' "$SRC_DIR/internal/handlers/tmpl/base.html"
grep -Fq 'static/*.js' "$SRC_DIR/internal/handlers/handlers.go"
grep -Fq 'mux.Handle("/static/"' "$SRC_DIR/internal/handlers/handlers.go"

cat > "$SRC_DIR/OFFLINE-FRONTEND-ASSETS.txt" <<EOF
Sambly offline frontend patch
htmx=${HTMX_VERSION} source=https://unpkg.com/htmx.org@${HTMX_VERSION}/dist/htmx.min.js
alpinejs=${ALPINE_VERSION} source=https://cdn.jsdelivr.net/npm/alpinejs@${ALPINE_VERSION}/dist/cdn.min.js
The downloaded JavaScript files are embedded into the Sambly Go binary at build time.
Runtime clients do not need Internet or DNS access to these CDN hosts.
EOF

echo "Sambly frontend assets vendored for fully offline runtime."
