#!/usr/bin/env bash
# Render the classic hosted-UI branding locally, against the REAL hosted pages, without
# applying anything. Cognito's markup is not ours and not documented, so a hand-written
# mock would prove nothing: this fetches the live sign-in, sign-up and reset pages,
# points them at Cognito's own two stylesheets, injects
# infra/aws/terraform/branding/cognito-hosted-ui.css exactly as SetUICustomization would
# serve it, and drops the logo into the banner the way Cognito does.
#
# Read-only: GETs on public endpoints, no credentials, no AWS call, no deploy.
#
# Usage: preview-cognito-branding.sh [outdir]
# Then open outdir/index.html, or serve outdir and look at 1440px and 375px.
set -euo pipefail
cd "$(dirname "$0")/.."

POOL_DOMAIN="${COGNITO_PREVIEW_DOMAIN:-skipperdesk.auth.eu-west-2.amazoncognito.com}"
CLIENT_ID="${COGNITO_PREVIEW_CLIENT_ID:-d6l5074tbc8v645e7t3drn908}"
REDIRECT="${COGNITO_PREVIEW_REDIRECT:-https://skipperdesk.app/link}"
BRAND="$PWD/infra/aws/terraform/branding"
OUT="${1:-${TMPDIR:-/tmp}/cognito-branding-preview}"

[[ -f "$BRAND/cognito-hosted-ui.css" ]] || { echo "missing $BRAND/cognito-hosted-ui.css" >&2; exit 1; }
[[ -f "$BRAND/cognito-hosted-ui-logo.png" ]] || { echo "missing logo" >&2; exit 1; }

mkdir -p "$OUT"
QS="response_type=code&client_id=${CLIENT_ID}&redirect_uri=$(printf %s "$REDIRECT" | sed 's|:|%3A|g; s|/|%2F|g')&scope=openid+email+profile"

for page in login signup forgotPassword; do
  curl -fsS -o "$OUT/$page.src.html" "https://${POOL_DOMAIN}/${page}?${QS}"
done

CDN=$(sed -n 's|.*href="\(https://[^"]*\)/css/bootstrap.min.css".*|\1|p' "$OUT/login.src.html" | head -1)
[[ -n "$CDN" ]] || { echo "could not find Cognito's stylesheet base" >&2; exit 1; }
curl -fsS -o "$OUT/bootstrap.min.css" "$CDN/css/bootstrap.min.css"
curl -fsS -o "$OUT/cognito-login.css" "$CDN/css/cognito-login.css"

BRAND="$BRAND" OUT="$OUT" CDN="$CDN" python3 - <<'PY'
import base64, os, pathlib, re

brand, out, cdn = pathlib.Path(os.environ["BRAND"]), pathlib.Path(os.environ["OUT"]), os.environ["CDN"]
css = (brand / "cognito-hosted-ui.css").read_text()
logo = base64.b64encode((brand / "cognito-hosted-ui-logo.png").read_bytes()).decode()
error_row = '<p class="errorMessage-customizable">Incorrect username or password.</p>'

pages = [
    ("login.src.html", "signin.html", "Sign in", False),
    ("login.src.html", "signin-error.html", "Sign in, error", True),
    ("signup.src.html", "signup.html", "Sign up", False),
    ("forgotPassword.src.html", "reset.html", "Password reset", False),
]

for src, dest, label, inject_error in pages:
    h = (out / src).read_text()
    h = h.replace(cdn + "/css/", "")
    h = re.sub(r'<script src="[^"]*advanced-security-data[^"]*"\s*>\s*</script>', "", h)
    h = h.replace("<center>", '<center><img class="logo-customizable" alt="logo" src="data:image/png;base64,%s"/>' % logo)
    if inject_error:
        h = h.replace('<div class="modal-body">', '<div class="modal-body">' + error_row)
    h = h.replace("</head>", '<meta charset="utf-8"><style>\n%s</style></head>' % css, 1)
    note = " Error row synthesized from Cognito's own class; no credentials submitted." if inject_error else ""
    bar = ('<div style="background:#203b3a;color:#fff;font:600 12px/1.5 -apple-system,system-ui,'
           'sans-serif;padding:6px 10px;text-align:center">PREVIEW - NOT THE LIVE PAGE. Real '
           'hosted-UI markup, Cognito stylesheets, branding CSS injected locally. Nothing '
           'applied.%s</div>') % note
    h = re.sub(r"(<body[^>]*>)", r"\1" + bar, h, count=1)
    (out / dest).write_text(h)

links = "".join('<li><a href="%s">%s</a></li>' % (d, l) for _, d, l, _ in pages)
(out / "index.html").write_text(
    '<!doctype html><meta charset="utf-8"><title>Cognito branding preview</title>'
    '<body style="font:16px/1.6 -apple-system,system-ui,sans-serif;padding:40px">'
    '<h1>Cognito hosted-UI branding preview</h1><p>Local render. Nothing applied.</p>'
    '<ul>%s</ul>' % links
)
PY

echo "CSS   $(wc -c < "$PWD/infra/aws/terraform/branding/cognito-hosted-ui.css") bytes (3 KB ceiling)"
echo "logo  $(wc -c < "$PWD/infra/aws/terraform/branding/cognito-hosted-ui-logo.png") bytes (100 KB ceiling)"
echo "open  $OUT/index.html"
