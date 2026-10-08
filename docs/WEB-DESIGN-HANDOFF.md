# SkipperDesk web redesign — deployment and brand handoff

Prepared 8 October 2026. These are local, uncommitted changes. No deployment has been performed.

## Design direction

**Your Mac. With you.** The website should make remote access feel familiar and approachable. Warm off-white, Harbor teal, generous spacing and an occasional system-serif phrase bring softness without decorative panels. Dark mode uses a quiet green-charcoal canvas with mint-teal actions. There are no content cards, enclosing borders, heavy gradients or third-party resources.

The compass mark is unchanged. A new local SVG shows two Macs with the same coastal landscape: an explanation of screen sharing, not a screenshot or a proposed native-app interface. The native app and its design system have not been edited.

`docs/DESIGN.md` remains the native design-system reference and the source for the nine shared copy rules. The website uses the web-specific scale and palette below; do not propagate them to the native app as part of deployment.

## Changed files and rationale

| File | Change and reason |
| --- | --- |
| `web/index.html` | Replaced boxed feature paragraphs with a clear headline, a two-Mac illustration, three setup steps, trial explanation and download action. Trial expiry and unopened paid top-ups remain explicit. |
| `web/download/index.html` | Prominent download action and requirements, followed by an ordered installation guide. Preserves the existing DMG URL, version and size. Explains both-Mac setup and unattended access before leaving. |
| `web/account/index.html` | Open editorial sections explain beta hours, future pricing, running out and support. Remains an informational page, not a live account dashboard. |
| `web/link/index.html` | Branded, spacious sign-in handoff with readable status text and a no-JavaScript instruction. Preserves all existing script sources, DOM hooks, hidden-state classes, referrer policy and robots metadata. |
| `web/credits/index.html` | Matching fallback design; retains the immediate `/account` redirect. |
| `web/404.html` | Matching utility-page design and an explicit action back to the home page. |
| `web/assets/styles.css` | Rebuilt the web layout with responsive typography, unboxed sections, light/dark tokens, visible keyboard focus, skip links, 44px navigation targets and reduced-motion handling. All six pages request `?v=2`. |
| `web/assets/two-macs.svg` | New small, self-contained vector illustration. Requested with `?v=1`. No fonts, scripts or remote references. |
| `docs/WEB-DESIGN-HANDOFF.md` | This design rationale, verification record and prompts for deployment and Cognito branding. |

No changes to `web/assets/link.js`, `web/assets/mark.svg`, generated configuration, Terraform, backend code or native app code. Development-only QA tools were installed under `/private/tmp`, not in this repository. No production dependency or build step was added.

## Web brand specification

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | `#FAF9F6` | `#172322` |
| Primary text | `#203B3A` | `#EDF1E9` |
| Secondary text | `#566762` | `#B4C2BA` |
| Primary action / link | `#0E6F7A` | `#80CFCE` |
| Action hover | `#0A555E` | `#A3E1DE` |
| Text on action | `#FFFFFF` | `#152D2C` |
| Field / muted surface | `#EEEEE8` | `#2B3B37` |

Use the system sans-serif stack in `styles.css`. Georgia is a locally available accent for the landing headline and trial figure, not a downloaded font. Body copy is 17px; navigation and secondary copy are 13–14px. Main actions are 50px tall with a pill radius. Marketing headings are intentionally larger than native-app headings. Content width is capped at 1120px with 20px mobile gutters. Keep technical details out of public copy.

## Verification

- Rendered all six routes at 375px and 1440px, in light and dark, using a local server with the production CSP. No horizontal overflow, missing images or inline code. `/credits` resolves to the account page.
- Personally inspected screenshots of the landing, download, account, handoff and 404 layouts.
- Static checks passed for local page/asset references, unique IDs, stylesheet version bumps, preserved download path, preserved credits redirect, and unchanged sign-in script sources and DOM hooks.
- Automated axe checks for WCAG 2 A/AA, 2.1 AA and 2.2 AA reported no violations across the 24 route/size/theme combinations. Browser console errors were also empty. This is an automated check, not a full accessibility certification.
- `git diff --check` passed.
- The full live sign-in exchange, native-app handoff and binary download were not exercised. These remain deployment smoke checks. Local sign-in rendering uses an offline configuration; no real credentials or authentication requests were sent.

## Prompt for Claude: deploy the website

> Review and deploy the local SkipperDesk web redesign in `/Users/godson/Desktop/remote-control`. Start with `docs/WEB-DESIGN-HANDOFF.md`, `docs/DESIGN.md` and `infra/web/README.md`. Review the working diff and the new `web/assets/two-macs.svg`; preserve unrelated work. This release changes only static web presentation. Do not build, release or redesign the native app and do not apply the backend Terraform stack.
>
> Preserve the CSP, external `link.js` authentication logic and all its DOM IDs, `config.js`, the `/credits` redirect, and the current DMG URL. All pages now use `styles.css?v=2`; the new SVG uses `?v=1`. Confirm the displayed DMG version/size still match the artifact currently served before deployment; do not publish a new app release to satisfy this website change. Use the existing guarded `infra/web/deploy.sh` workflow and the correct explicit AWS profile. Inspect its dry run first. Keep generated config and release images out of the ordinary sync, as the deploy script already does.
>
> After deployment, verify `/`, `/download`, `/account`, `/credits`, `/link` without query parameters, and a nonexistent path. Check 375px mobile and desktop in light/dark, the new SVG, the stylesheet version, response security headers and the download link. Exercise a real sign-in from the app with the owner, including return to SkipperDesk, without logging sensitive callback parameters. Report exactly what was deployed and any verification limits. Cognito branding is a separate task described below; do not mix an unreviewed authentication change into this static-site deployment.

## Prompt for Claude: close the Cognito branding gap

> Brand the existing Cognito-hosted authentication screens to match the SkipperDesk website. Read `docs/WEB-DESIGN-HANDOFF.md`, `web/assets/styles.css`, `web/assets/mark.svg`, `web/link/index.html`, and the Cognito Terraform configuration. First inspect the actual deployed branding version, app client and user-pool tier; the repository's variable is not proof of live configuration.
>
> For managed login (version 2), use its supported branding settings/assets, with a reproducible change in the existing infrastructure workflow. For classic hosted UI (version 1), use the supported logo and CSS customization options. Do not upload the website stylesheet wholesale or assume classic CSS applies to managed login. Do not switch the branding version, tier, domain or authentication architecture just to change appearance; report any such dependency before proceeding.
>
> Match the existing compass mark, warm `#FAF9F6` canvas, `#203B3A` text, `#566762` secondary text, `#0E6F7A` action with white text, system typography and generous space. Where dark branding is supported, use the corresponding tokens in this handoff. Avoid background illustrations, extra marketing panels and prominent outer card borders. Keep input boundaries and focus states clear. Aim for a 440px form column and 48–50px actions, within Cognito's supported settings. Convert the existing logo into a supported upload format only if required, preserving its shape and transparency. Keep provider-mandated controls and text intact.
>
> Preserve email/password, verification, password reset, MFA and enabled identity-provider flows, OAuth scopes, PKCE, callback/logout URLs, nonce handling, and the `skipperdesk://link` return path. Do not add trackers, third-party fonts or a custom credential form. Prepare reviewable branding artifacts and screenshots; then validate sign-in, sign-up, verification, password reset, errors and MFA on desktop and 375px mobile. Document any parts of the visual specification that Cognito cannot support. Keep infrastructure changes confined to the branding implementation and provide a rollback procedure.

AWS distinguishes the two mechanisms: [branding overview](https://docs.aws.amazon.com/cognito/latest/developerguide/managed-login-branding.html), [managed-login branding editor](https://docs.aws.amazon.com/cognito/latest/developerguide/managed-login-brandingeditor.html), [classic hosted UI customization](https://docs.aws.amazon.com/cognito/latest/developerguide/hosted-ui-classic-branding.html). Managed-login text is not freely editable; use supported branding controls rather than promising a pixel-identical copy of the website.
