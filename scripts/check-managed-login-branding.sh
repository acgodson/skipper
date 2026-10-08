#!/usr/bin/env bash
# Check the managed-login branding artifacts, and render a token sheet.
#
# This is NOT a preview of the sign-in pages. Managed login is rendered by AWS from the
# settings document; there is no stylesheet to inject and no markup of ours, so the pages
# cannot be produced offline the way scripts/preview-cognito-branding.sh produces the
# classic ones. The honest offline artifacts are these checks and a labelled swatch sheet.
#
# Read-only: no AWS call, no deploy.
#
# Usage: check-managed-login-branding.sh [outdir]
set -euo pipefail
cd "$(dirname "$0")/.."

BRAND="$PWD/infra/aws/terraform/branding"
OUT="${1:-${TMPDIR:-/tmp}/managed-login-branding-check}"

[[ -f "$BRAND/managed-login-settings.json" ]] || { echo "missing $BRAND/managed-login-settings.json" >&2; exit 1; }
[[ -f "$BRAND/managed-login-mark.svg" ]] || { echo "missing $BRAND/managed-login-mark.svg" >&2; exit 1; }

mkdir -p "$OUT"

BRAND="$BRAND" OUT="$OUT" python3 - <<'PY'
import base64, json, os, pathlib, re, sys

brand, out = pathlib.Path(os.environ["BRAND"]), pathlib.Path(os.environ["OUT"])
settings_text = (brand / "managed-login-settings.json").read_text()
svg_text = (brand / "managed-login-mark.svg").read_text()
fail = []

try:
    settings = json.loads(settings_text)
except json.JSONDecodeError as e:
    print("settings document is not valid JSON: %s" % e, file=sys.stderr)
    sys.exit(1)

# Colours in the settings schema are 8-digit RGBA, lower case, no leading hash. A '#' or a
# 6-digit value is silently ignored by Cognito rather than rejected, so it has to be caught
# here or not at all.
COLOR_KEY = re.compile(r"Color$|^color$")
RGBA = re.compile(r"^[0-9a-f]{8}$")

# Keys AWS documents as reserved and not implemented, plus the authentication category,
# which this document must never carry: branding may not reshape an auth method.
FORBIDDEN_TOP = {"auth", "signUp"}
FORBIDDEN_ANY = {"instructions", "languageSelector", "sessionTimerDisplay"}

def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            here = path + [k]
            if k in FORBIDDEN_ANY:
                fail.append("reserved or auth-shaping key present: %s" % ".".join(here))
            if COLOR_KEY.search(k) and isinstance(v, str) and not RGBA.match(v):
                fail.append("colour %s is %r, want 8 lower-case hex digits with no hash" % (".".join(here), v))
            walk(v, here)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path + ["%d" % i])

for k in settings.get("categories", {}):
    if k in FORBIDDEN_TOP:
        fail.append("reserved or auth-shaping key present: categories.%s" % k)
walk(settings, [])

# AWS sanitises uploaded SVG against these fixed lists ("Image assets" in the branding
# editor reference). Anything outside them is stripped, so an asset that relies on it
# renders wrong rather than failing the apply.
ELEMENTS = set("""svg a altglyph altglyphdef altglyphitem animatecolor animatemotion
animatetransform audio canvas circle clippath defs desc ellipse filter font g glyph glyphref
hkern image line lineargradient marker mask metadata mpath path pattern polygon polyline
radialgradient rect stop style switch symbol text textpath title tref tspan video view vkern
feblend fecolormatrix fecomponenttransfer fecomposite feconvolvematrix fediffuselighting
fedisplacementmap fedistantlight feflood fefunca fefuncb fefuncg fefuncr fegaussianblur
femerge femergenode femorphology feoffset fepointlight fespecularlighting fespotlight fetile
feturbulence""".split())
ATTRIBUTES = set("""accent-height accumulate additivive alignment-baseline ascent attributename
attributetype azimuth basefrequency baseline-shift begin bias by class clip clip-path clip-rule
color color-interpolation color-interpolation-filters color-profile color-rendering cx cy d dx
dy diffuseconstant direction display divisor dur edgemode elevation end fill fill-opacity
fill-rule filter filterunits flood-color flood-opacity font-family font-size font-size-adjust
font-stretch font-style font-variant font-weight fx fy g1 g2 glyph-name glyphref gradientunits
gradienttransform height href id image-rendering in in2 k k1 k2 k3 k4 kerning keypoints
keysplines keytimes lang lengthadjust letter-spacing kernelmatrix kernelunitlength lighting-color
local marker-end marker-mid marker-start markerheight markerunits markerwidth maskcontentunits
maskunits max mask media method mode min name numoctaves offset operator opacity order orient
orientation origin overflow paint-order path pathlength patterncontentunits patterntransform
patternunits points preservealpha preserveaspectratio r rx ry radius refx refy repeatcount
repeatdur restart result rotate scale seed shape-rendering specularconstant specularexponent
spreadmethod stddeviation stitchtiles stop-color stop-opacity stroke-dasharray stroke-dashoffset
stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke stroke-width style
surfacescale tabindex targetx targety transform text-anchor text-decoration text-rendering
textlength type u1 u2 unicode values viewbox visibility vert-adv-y vert-origin-x vert-origin-y
width word-spacing wrap writing-mode xchannelselector ychannelselector x x1 x2 xmlns y y1 y2 z
zoomandpan""".split())

for tag in re.findall(r"<([A-Za-z][-A-Za-z0-9]*)", svg_text):
    if tag.lower() not in ELEMENTS:
        fail.append("svg element not in AWS's allow-list: <%s>" % tag)
for attr in re.findall(r"[\s<]([A-Za-z][-:A-Za-z0-9]*)\s*=", svg_text):
    if attr.lower() not in ATTRIBUTES:
        fail.append("svg attribute not in AWS's allow-list: %s" % attr)

# CreateManagedLoginBranding takes at most 2 MB per request, assets included. Two assets
# carry the same file.
asset_b64 = len(base64.b64encode(svg_text.encode()))
request_bytes = len(settings_text.encode()) + 2 * asset_b64

# The contrast stage reads colours as numbers, so a malformed one has to stop the run here
# rather than crash there.
if fail:
    for f in fail:
        print("FAIL  %s" % f)
    sys.exit(1)

# Contrast is the one thing a swatch sheet can actually prove about these tokens.
def lum(c):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(int(c[0:2], 16)) + 0.7152 * ch(int(c[2:4], 16)) + 0.0722 * ch(int(c[4:6], 16))

def ratio(fg, bg):
    a, b = lum(fg), lum(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)

G = lambda *p: __import__("functools").reduce(lambda d, k: (d or {}).get(k, {}), p, settings)
pairs = [
    ("body text on canvas", G("components", "pageText", "lightMode")["bodyColor"], G("components", "pageBackground", "lightMode")["color"],
     G("components", "pageText", "darkMode")["bodyColor"], G("components", "pageBackground", "darkMode")["color"]),
    ("secondary text on canvas", G("components", "pageText", "lightMode")["descriptionColor"], G("components", "pageBackground", "lightMode")["color"],
     G("components", "pageText", "darkMode")["descriptionColor"], G("components", "pageBackground", "darkMode")["color"]),
    ("action label on action", G("components", "primaryButton", "lightMode", "defaults")["textColor"], G("components", "primaryButton", "lightMode", "defaults")["backgroundColor"],
     G("components", "primaryButton", "darkMode", "defaults")["textColor"], G("components", "primaryButton", "darkMode", "defaults")["backgroundColor"]),
    ("action label on hover", G("components", "primaryButton", "lightMode", "hover")["textColor"], G("components", "primaryButton", "lightMode", "hover")["backgroundColor"],
     G("components", "primaryButton", "darkMode", "hover")["textColor"], G("components", "primaryButton", "darkMode", "hover")["backgroundColor"]),
    ("field border on canvas", G("componentClasses", "input", "lightMode", "defaults")["borderColor"], G("components", "pageBackground", "lightMode")["color"],
     G("componentClasses", "input", "darkMode", "defaults")["borderColor"], G("components", "pageBackground", "darkMode")["color"]),
    ("field border on field", G("componentClasses", "input", "lightMode", "defaults")["borderColor"], G("componentClasses", "input", "lightMode", "defaults")["backgroundColor"],
     G("componentClasses", "input", "darkMode", "defaults")["borderColor"], G("componentClasses", "input", "darkMode", "defaults")["backgroundColor"]),
    ("label on field", G("componentClasses", "inputLabel", "lightMode")["textColor"], G("componentClasses", "input", "lightMode", "defaults")["backgroundColor"],
     G("componentClasses", "inputLabel", "darkMode")["textColor"], G("componentClasses", "input", "darkMode", "defaults")["backgroundColor"]),
    ("placeholder on field", G("componentClasses", "input", "lightMode")["placeholderColor"], G("componentClasses", "input", "lightMode", "defaults")["backgroundColor"],
     G("componentClasses", "input", "darkMode")["placeholderColor"], G("componentClasses", "input", "darkMode", "defaults")["backgroundColor"]),
    ("link on canvas", G("componentClasses", "link", "lightMode", "defaults")["textColor"], G("components", "pageBackground", "lightMode")["color"],
     G("componentClasses", "link", "darkMode", "defaults")["textColor"], G("components", "pageBackground", "darkMode")["color"]),
    ("focus ring on canvas", G("componentClasses", "focusState", "lightMode")["borderColor"], G("components", "pageBackground", "lightMode")["color"],
     G("componentClasses", "focusState", "darkMode")["borderColor"], G("components", "pageBackground", "darkMode")["color"]),
]

# Boundaries and focus rings are non-text: WCAG 2.1 1.4.11 wants 3:1. Everything else here
# is body-size text, so 1.4.3 wants 4.5:1.
NON_TEXT = {"field border on canvas", "field border on field", "focus ring on canvas"}

rows = []
for label, lfg, lbg, dfg, dbg in pairs:
    lr, dr = ratio(lfg, lbg), ratio(dfg, dbg)
    floor = 3.0 if label in NON_TEXT else 4.5
    for mode, r in (("light", lr), ("dark", dr)):
        if r < floor:
            fail.append("%s, %s mode: %.2f:1 is below the %.1f:1 WCAG floor" % (label, mode, r, floor))
    cells = []
    for fg, bg, r in ((lfg, lbg, lr), (dfg, dbg, dr)):
        cells.append(
            '<td style="background:#%s;color:#%s;padding:14px 16px;border-radius:10px">'
            '<span style="font:600 15px/1.4 -apple-system,system-ui,sans-serif">Harbor</span>'
            '<div style="font:12px/1.5 ui-monospace,monospace;opacity:.85">#%s on #%s &middot; %.2f:1</div></td>'
            % (bg[:6], fg[:6], fg[:6], bg[:6], r)
        )
    verdict = "pass, floor %.1f:1" % floor if min(lr, dr) >= floor else "BELOW %.1f:1" % floor
    rows.append(
        '<tr><th style="text-align:left;font:600 14px/1.5 -apple-system,system-ui,sans-serif;'
        'padding:14px 18px 14px 0;white-space:nowrap">%s</th>%s<td style="font:13px/1.5 '
        '-apple-system,system-ui,sans-serif;padding-left:18px;color:#566762">%s</td></tr>'
        % (label, "".join(cells), verdict)
    )

banner = (
    '<div style="background:#203b3a;color:#fff;font:600 13px/1.6 -apple-system,system-ui,'
    'sans-serif;padding:12px 16px;border-radius:12px;margin-bottom:28px">TOKEN SHEET, NOT A '
    'PAGE PREVIEW. Managed login is rendered by AWS from the settings document, so the real '
    'pages cannot be produced offline and nothing here is a mock-up of them. These are the '
    'exact colour values branding/managed-login-settings.json sends, with their contrast '
    'ratios. Nothing has been applied.</div>'
)
(out / "index.html").write_text(
    '<!doctype html><meta charset="utf-8"><title>Managed login token sheet</title>'
    '<body style="font:16px/1.65 -apple-system,system-ui,sans-serif;background:#faf9f6;'
    'color:#203b3a;margin:0;padding:40px 20px;max-width:1120px;margin:0 auto">%s'
    '<h1 style="font:600 28px/1.25 -apple-system,system-ui,sans-serif;margin:0 0 6px">'
    'Managed login branding tokens</h1><p style="color:#566762;margin:0 0 28px">Light column, '
    'then dark column, as the settings document defines them.</p>'
    '<table style="border-collapse:separate;border-spacing:0 10px;width:100%%">%s</table>'
    '</body>' % (banner, "".join(rows))
)

print("settings    %d bytes, %d top-level categories" % (len(settings_text.encode()), len(settings)))
print("asset       %d bytes of svg, %d base64, uploaded twice (FORM_LOGO, FAVICON_SVG)" % (len(svg_text.encode()), asset_b64))
print("request     %d bytes of 2097152 (CreateManagedLoginBranding ceiling)" % request_bytes)
if request_bytes > 2 * 1024 * 1024:
    fail.append("request would exceed the 2 MB CreateManagedLoginBranding ceiling")
print("token sheet %s" % (out / "index.html"))
print()
if fail:
    for f in fail:
        print("FAIL  %s" % f)
    sys.exit(1)
print("OK    settings keys, colour format, svg allow-list, request size")
print("NOTE  the sign-in pages themselves cannot be rendered offline; managed login is")
print("      rendered by AWS. Verify them on the real domain after the owner applies.")
PY
