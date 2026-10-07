# infra/web — skipperdesk.app, the website

The static site in `web/`, served from a private S3 bucket through CloudFront, with its own
Terraform root module and its own state. Nothing here touches the box that runs live sessions.

That separation is the whole point. Landing copy, pricing wording and, later, the download
page change far more often than the session backend does, and a plan here must never refresh,
lock, roll or replace anything in `infra/aws`. `infra/web/deploy.sh` ships new copy without an
`infra/aws` apply, without an SSM command, and without an app release.

## What it creates

| Where | What |
|---|---|
| `terraform/bucket.tf` | The site bucket, from the same `hardened-bucket` module the backend stack uses, plus the policy that lets only CloudFront read it, plus `config.js` |
| `terraform/cloudfront.tf` | Origin Access Control, the request-fixup function, the two cache policies, the response-headers policy, and the distribution |
| `terraform/certificate.tf` | The us-east-1 certificate for the apex and `www`, DNS-validated |
| `terraform/functions/fixup.js` | `www` → apex, and `/link` → `/link/index.html` |

The bucket is **private**. It is not a website-endpoint bucket: that endpoint is plain HTTP,
it cannot sit behind Origin Access Control, and it would hand out the same files with none of
the headers below. CloudFront is the only way in, which is what makes those headers a
property of the site rather than of one code path.

`hardened-bucket` was reused as-is; the only change it needed was a
`bucket_regional_domain_name` output, since a CloudFront origin takes the regional endpoint.

## What serves the site

CloudFront, HTTP/2 and HTTP/3, compression on, `PriceClass_100` (North America and Europe).
No access logs and no analytics of any kind — `scripts/check-isolation.sh` exists because this
product does not touch anything it does not have to, and that applies to its website.

### Caching, with no build step

There is no bundler, so no filename carries a content hash. Two cache behaviours instead:

| Path | CloudFront policy | Object `Cache-Control` |
|---|---|---|
| `/assets/*` | up to a year, **query string in the cache key** | `public, max-age=31536000, immutable` |
| everything else | 60 s default, 300 s ceiling | `no-cache` |

The pages ask for `assets/styles.css?v=1`. Bumping that number in the HTML — which is never
cached for more than a few minutes — is the cache bust. `deploy.sh` also invalidates `/*`, so
a forgotten bump corrects itself at the edge, though not in a browser that already holds the
old asset. **Bump `?v=` whenever you change anything under `web/assets/`.**

### Headers

Set by one response-headers policy on both behaviours.

| Header | Value | Why |
|---|---|---|
| `Content-Security-Policy` | `default-src 'none'` … | Below |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | No `preload`: preloading is close to irreversible and is the owner's decision to make once, not a side effect of a website deploy. `includeSubDomains` covers `api.`, which is already HTTPS only; `turn.` is not HTTP and is unaffected |
| `X-Content-Type-Options` | `nosniff` | |
| `X-Frame-Options` | `DENY` | Belt to the CSP's braces |
| `Referrer-Policy` | `no-referrer` | The sign-in page's URL carries the app's nonce and the device's public key. This is what keeps them out of Cognito's logs and anyone else's |
| `Permissions-Policy` | every listed feature `()` | The site needs no camera, microphone, location or payment API |
| `Cross-Origin-Opener-Policy` | `same-origin` | |
| `Server` | removed | |

The CSP is `terraform output content_security_policy`. It reads:

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self';
connect-src https://api.skipperdesk.app https://<sign-in origin>;
form-action 'none'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'
```

`default-src 'none'` means every directive not listed is denied, so there is no font, media,
worker, frame or manifest permission to revoke later. The page loads no third-party script,
no web font and no analytics, so `'self'` is the whole of `script-src`, `style-src` and
`img-src` — and because of that there is **no `'unsafe-inline'` anywhere**, which is only
possible because no page in `web/` carries an inline `<script>` or a `style=` attribute.
**Keep it that way**; the cost of one inline style is `'unsafe-inline'` on `style-src`, which
is most of the protection gone.

`connect-src` names exactly two origins because the page makes exactly two calls: the Cognito
token endpoint, and `POST /v1/auth/link`. There is no `'self'` in it — the page never calls
back to itself, and listing it would be permission nobody uses. `form-action 'none'` is
honest: the site has no form, and the sign-in navigation is a `location.replace`, which
`form-action` does not govern.

## State

Same bucket, lock table and KMS key as `infra/aws`, under a **different key**. One thing to
back up and one key policy to audit; separate keys so the two plans never meet.

```
cp ../aws/terraform/backend.hcl terraform/backend.hcl
# edit one line:  key = "prod/web.tfstate"
cd terraform && terraform init -backend-config=backend.hcl
```

`terraform/main.tf` reads the backend stack's outputs with a `terraform_remote_state` data
source rather than taking them as variables, so the sign-in origin, the app client id and the
API domain have one home. It is a read of an S3 object: it neither locks nor refreshes
anything `infra/aws` manages. **What it costs:** this module cannot plan until `infra/aws`
has been applied once, it needs read access to that state object and its key, and renaming an
output over there breaks the plan here. That is the price of not maintaining three strings in
two places, and it is worth it.

## Order to run it

1. `cp terraform/terraform.tfvars.example terraform/terraform.tfvars` and set
   `backend_state_bucket` to the `bucket` line of the backend stack's `backend.hcl`.
2. `terraform init -backend-config=backend.hcl`
3. `terraform apply -target=aws_acm_certificate.site`
4. `terraform output acm_validation_records` — the owner adds these at the registrar.
5. `terraform apply`. It waits for the certificate to be issued (`certificate_issue_timeout`,
   75 minutes by default) and then builds the distribution.
6. `terraform output dns_records_to_create` — the owner adds the `ALIAS` and `CNAME`.
7. `AWS_PROFILE=<profile> ./deploy.sh --profile <profile>`

### DNS is not ours, here either

The apex cannot be a `CNAME`. Namecheap's own record type for this is `ALIAS`, supported on
BasicDNS, FreeDNS and PremiumDNS, with `@` as the Host — and it cannot coexist with an `A`,
`AAAA`, `CNAME` or URL Redirect record on the same host, so **the registrar's parking address
on `@` has to be deleted first**. Namecheap resolves the ALIAS target from its own resolvers,
so CloudFront picks an edge near Namecheap rather than near the visitor; that costs a little
first-hop latency and nothing else.

## Deploying the site

```
AWS_PROFILE=<profile> infra/web/deploy.sh --profile <profile>
```

It syncs `web/` in two passes (assets immutable, pages `no-cache`), invalidates `/*`, waits
for the invalidation and then checks the distribution answers 200. `--dry-run` shows what
would move without touching anything. Like `infra/aws/deploy.sh` it sources
`scripts/aws-profile-guard.sh`, refuses to run without `--profile`, refuses the profiles that
belong to other accounts, and asserts the profile resolves to this account before it writes.

`terraform output` reads the S3 backend, which is why `AWS_PROFILE` has to be exported as well
as passed — the flag reaches the AWS CLI, not Terraform.

**`config.js` is excluded from the sync.** Terraform writes it straight into the bucket from
the backend stack's outputs, because it is the one file that carries the sign-in origin, the
app client id and the API domain. `scripts/serve-web.sh` writes a local copy for offline work;
`web/.gitignore` keeps it out of the repository and `deploy.sh` refuses to upload it.

## Shipping a release image

```
AWS_PROFILE=<profile> infra/web/deploy.sh --profile <profile> --dmg dist/SkipperDesk-<version>.dmg
```

One object into `/assets/`, `Cache-Control: public, max-age=31536000, immutable`, and
nothing else: no site sync, no invalidation. It refuses a name that is already in the
bucket, because an immutable object is served from edges and browsers for a year and
must never mean two different images.

The ordinary site sync runs with `--delete` and **excludes `*.dmg`**. Without that the
next copy change would delete the download: the image lives under `/assets/` but is not
in `web/assets/`, so `--delete` would see it as a file that should not be there.

Uploading does not publish. The app learns about a release from
`GET /v1/app/releases/latest`, which is `scripts/publish-release.sh` — that script
re-downloads this object through CloudFront and checks its hash before it tells the API
anything.

**The version on the page is hand-edited.** There is no build step, so
`web/download/index.html` carries the filename, the version and the size as text. Change
them, deploy the site, and `publish-release.sh` will warn if the live page and the
release it is publishing disagree.

## The `.dmg` belongs here, not on the instance

When the app ships, the download goes in this bucket behind this distribution — not on the
`t4g.small`. A 60 MB disk image served from the box is EC2 egress at $0.09/GB beyond the 100 GB
free tier, on the same NIC and the same 2 vCPUs that are carrying live sessions and TURN relay;
a thousand downloads a month would be 60 GB of it, competing with the thing people are paying
for. The same thousand downloads through CloudFront sit inside its 1 TB always-free tier.

Put it under `/assets/` so it inherits the immutable cache policy, and version the filename.

## Costs

| Item | Monthly |
|---|---:|
| CloudFront: 1 TB out and 10 M requests are always free | $0 |
| S3 Standard, a few hundred KB of site | ~$0.00 |
| S3 requests, served through CloudFront's cache | ~$0.00 |
| ACM certificate | $0 |
| Terraform state object in the existing bucket | $0 |
| **Total** | **~$0** |

It stays ~$0 until the site serves more than 1 TB a month, which with the `.dmg` here means
roughly 16 000 downloads. Past that it is $0.085/GB — still cheaper than EC2 egress, and off
the instance's NIC.

## What is deliberately not here yet

- **No custom sign-in domain.** Cognito's free `<prefix>.auth.<region>.amazoncognito.com`
  does the sign-in. `auth.skipperdesk.app` comes with the Apple work: it needs a second
  us-east-1 certificate, a `CNAME` at the registrar, `aws_cognito_user_pool_domain` moved to
  its `certificate_arn` form, and the parent domain to have an A record at the time Cognito
  creates it. The `TODO:` is in `infra/aws/terraform/cognito.tf`.
- **No access logs, no analytics, no tag manager, no third-party font.**
- **No WAF.** A static site behind a cache has nothing to protect; the rate limits that
  matter are rc-api's, and they are per client address there.
- **No release automation.** The download page's version, size and link are edited by
  hand and the release is published by hand. Three commands, a few times a year, each
  checking the one before it — against a build step that would have to be trusted with
  the signing identity.
