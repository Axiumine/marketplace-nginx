# nginx — the platform edge

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Axiumine/marketplace-nginx/badge)](https://scorecard.dev/viewer/?uri=github.com/Axiumine/marketplace-nginx)

> [!WARNING]
> **Work in progress — this software is not tested yet.** It has never run outside a developer
> workstation: no real deployment, no load test, no security review, no upgrade path. Parts of the
> platform are deliberately unbuilt, and anything here — schemas, endpoints, configuration, file
> layout — can still change without notice. Whatever automated gates this repo runs, treat the result
> as unproven: do not point it at real users or real data.
> Read [`docs/PRODUCTION_HARDENING.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/docs/PRODUCTION_HARDENING.md) before taking any of it further.

The production edge for all three domains, in one place. **This repo is authoritative.**
`marketplace-user/docs/nginx/` held the customer vhost alone and is now a pointer at this folder — its
four `.conf` files are deleted, not copied, so there is one edge configuration and not two. The two
panels had no checked-in vhost at all — the higher-privilege surfaces were the undocumented ones, an
asymmetry [`docs/report/token-handling-security-audit.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/docs/report/token-handling-security-audit.md) carried as a finding until this repo closed
it.

It is a repo of its own, checked out at the workspace root, because it is the one artefact that is not
per-service: a single nginx instance fronts eleven loopback upstreams across five of the sixteen repos,
all three vhosts share the upstream table and the rate-limit zones, and the same `logout` service answers
on all three hosts. Split across the service repos, no copy is ever the whole configuration.

⚠️ **This repo has no `package.json`, so its two hooks look like nobody else's.** `.githooks/pre-push`
runs `test/run.sh` and blocks the push on the first failed check — that is the whole quality gate,
because there is no lint, no coverage, no mutation score and no Qodana project here for anything else to
run. `.githooks/pre-commit` is the platform's secret guard — check 0 plus the two staged-secret scans,
byte-identical to the other fifteen repos' copies — and then exits, with no gate after it.

⚠️ **`core.hooksPath` is local config and no `prepare` script arms it here.** After a fresh clone,
`git config core.hooksPath .githooks` — until you run it the hook is off and a push is ungated with no
output to say so. This repo and the parent workspace are the two with no `package.json` and so the two
that must be armed by hand.

**No nginx exists in this workspace or on this development machine** — there is no `/etc/nginx` and no
nginx binary in `PATH`. These files describe the production edge. Nothing here has been run.

## The three domains

| Host | App | Repo | Root | Audience |
|---|---|---|---|---|
| `marketplace-domain.com` | public site + customer account area | `marketplace-user` | `/srv/marketplace-user/dist/client` + SSR on 3045 | anonymous + `User` |
| `shopowner.marketplace-domain.com` | shop-owner panel | `marketplace-shopowner` | `/srv/marketplace-shopowner/dist` | `ShopOwner` |
| `admin.marketplace-domain.com` | admin panel | `marketplace-admin` | `/srv/marketplace-admin/dist` | `Admin` |

`www.marketplace-domain.com` 308s to the apex over TLS. Any other name reaching this instance is refused
at the handshake by the default server in `conf.d/40-tls.conf`.

Three hosts, not one, and the split is load-bearing in four places:

1. **The session cookie has no `Domain` attribute**, so it is host-only. An admin's session is not
   sent to the shop-owner host and cannot be read there. One host for all three tiers would put every
   tier's cookie in one jar.
2. **`APP_DOMAIN` vs `APP_DOMAIN_USER`.** `marketplace-dev-public-resource` builds the shop owner's
   verification link from the first and the customer's from the second. `/check/verify-email/` and
   `/check/verify-email-user/` are two routes against two collections; neither can tell from an
   `(email, hash)` pair which one minted it, so they are separated by host as well as by path.
3. **Rate limiting.** All three logins hit the same process on 4028. The edge is the only layer that
   still knows which hostname was asked for, so it is the only place a stuffing run against admin
   accounts can be stopped from spending the customers' allowance.
4. **Header policy.** The customer surface needs a CSP loose enough for MapLibre and a nonce for its
   server-rendered inline script; the panels need neither and get a strictly tighter one. Both
   policies allow `challenges.cloudflare.com` in `script-src` and `frame-src` — all three login
   pages render Turnstile.

## ⚠️ The `Secure` cookie flag lives here

`@axiumine/koa-utils/dist/lib/tokenOptions.mjs` sets both cookie option objects with:

```js
httpOnly: true,
sameSite: 'Strict',
secure: false, // rewrite a true in Nginx !
```

`snippets/proxy-backend.conf` is the other half of that comment:

```nginx
proxy_cookie_flags ~ secure httponly samesite=strict;
```

`~` is the empty regex and matches every cookie name — `refresh_token`, its Keygrip signature
`refresh_token.sig`, and anything a later koa-utils release adds. It is included at **server** level in
all three vhosts, so every proxied response inherits it.

Before this existed, the flag was set by nobody: the session cookie went out marked as safe to replay
over plain HTTP. Keygrip's constant-time signature stops an attacker who wants to *write* a cookie and
does nothing against one who *reads* it in cleartext; `SameSite=Strict` constrains which sites may send
it, not which networks may observe it. That was the 🔴 Critical of the token-handling audit, dropped from
that report once this directory closed it — **as long as nginx is actually in front.** Nothing else on the platform sets the
flag, nothing fails without it, and no test in any of the sixteen repos covers it.

`secure: true` in koa-utils remains the real fix (it is the seventeenth repo, outside this workspace, so
none of the release discipline `marketplace-common` is held to is observable from it). When it lands, this line stays: it is
then a second lock on the same door, and the only one a config review can see.

## Files

|File|Level|Role|
|---|---|---|
|`conf.d/00-hardening.conf`|http|`server_tokens off`, slow-request timeouts, header buffers|
|`conf.d/05-logging.conf`|http|`log_format mkt_access` — the one access-log format: no address, and no mailed-link credential|
|`conf.d/06-real-ip.conf`|http|Cloudflare's ranges + `CF-Connecting-IP` — the only place the platform learns a client address|
|`conf.d/10-upstreams.conf`|http|every backend, one `upstream` each, with keepalive pools|
|`conf.d/20-rate-limit.conf`|http|`limit_req_zone` / `limit_conn_zone` — per-surface, not shared|
|`conf.d/30-cache.conf`|http|HTML cache zone, session-bypass map and mailed-credential bypass map, customer surface only|
|`conf.d/40-tls.conf`|http|protocols, ciphers, session cache, and the `444` default server|
|`snippets/origin-pull.conf`|server|mutual TLS — the CA Cloudflare's client certificate is verified against, included by all four 443 blocks|
|`snippets/proxy-backend.conf`|server|**the `Secure` rewrite**, keepalive, forwarded headers, timeouts|
|`snippets/security-headers-public.conf`|server/location|customer CSP + headers (nonce, MapLibre, Turnstile)|
|`snippets/security-headers-private.conf`|server/location|panel CSP + headers — strictly tighter, no nonce, no MapLibre, Turnstile allowed|
|`sites-available/marketplace-domain.com.conf`|—|customer vhost: SSR, cache, static, 5 endpoints, geocoder|
|`sites-available/shopowner.marketplace-domain.com.conf`|—|shop-owner vhost: SPA, 4 endpoints, `/check/verify-email/`|
|`sites-available/admin.marketplace-domain.com.conf`|—|admin vhost: SPA, 4 endpoints|
|`logrotate.d/nginx`|—|**retention** — 14 daily rotations with `shred` on removal, over all eight log destinations|
|`.githooks/pre-commit`|—|the platform secret guard, and nothing after it — no code here to gate|
|`.githooks/pre-push`|—|the quality gate — runs `test/run.sh`, blocks the push on any failure|
|`test/run.sh`|—|entry point — runs the suite below in a throwaway container|
|`test/suite.sh`|—|`nginx -t` plus 234 behavioural assertions; runs *inside* the container|
|`test/fake-backends.conf`|—|stand-ins for the eleven upstreams, test-only, never installed|
|`test/real-ip-overlay.conf`|http|test-only — trusts the loopback so the log assertions run against the post-`set_real_ip_from` shape|

`conf.d/*` must be included at `http` level — `proxy_cache_path`, `limit_req_zone`, `map` and `upstream`
are not valid inside a `server` block. On Debian, `/etc/nginx/conf.d/*.conf` is already included from
`http` by the stock `nginx.conf`. The numeric prefixes only fix the order in that glob; nothing depends
on it today beyond readability.

**Requires nginx ≥ 1.25.1** — `http2 on` (1.25.1), `ssl_reject_handshake` (1.19.4) and
`proxy_cookie_flags` (1.19.3). Debian 13 ships 1.26+.

## Which host proxies what

| Path | Service | Port | apex | shopowner | admin |
|---|---|---|:--:|:--:|:--:|
|`/public-resource`|`marketplace-dev-public-resource`|4027|✅|—|—|
|`/public-authorization`|`marketplace-dev-public-authorization`|4028|✅|✅|✅|
|`/user-authenticated-authorization`|`…-user-authenticated-authorization`|4031|✅|—|—|
|`/user-authenticated-resource`|`…-user-authenticated-resource`|4032|✅|—|—|
|`/authenticated-authorization`|`marketplace-dev-authenticated-authorization`|4029|—|✅|—|
|`/authenticated-resource`|`marketplace-dev-authenticated-resource`|4026|—|✅|—|
|`/admin-authenticated-authorization`|`…-admin-authenticated-authorization`|4025|—|—|✅|
|`/admin-authenticated-resource`|`…-admin-authenticated-resource`|4024|—|—|✅|
|`/logout`|`marketplace-dev-authenticated-logout`|4030|✅|✅|✅|
|`/check/verify-email-user/`|`marketplace-dev-public-resource`|4027|✅|—|—|
|`/check/verify-email/`|`marketplace-dev-public-resource`|4027|—|✅|—|
|`/` (everything else)|`marketplace-user` SSR|3045|✅|—|—|
|`/geocode/`|Nominatim|8080|✅|—|—|

**The path IS the service.** Each one serves its GraphQL at exactly that path — `ENDPOINT` in its
`src/index.mts` — so no `proxy_pass` here rewrites a URI and none may be made to. `/logout` is shared by
all three on purpose: that resolver deletes Redis keys by token content and never asks which collection
minted them.

Pointing a host at another tier's endpoint fails closed — since the Phase 0 tier fix a session carries a
`tier` field and a service rejects a token minted for another tier with a 403 — but it fails at the
wrong service, which is a confusing way to find out.

## Environment variables this configuration assumes

| Variable | Where | Value |
|---|---|---|
|`APP_DOMAIN`|`marketplace-dev-public-resource`|`https://shopowner.marketplace-domain.com`|
|`APP_DOMAIN_USER`|`marketplace-dev-public-resource`|`https://marketplace-domain.com`|
|`VITE_GRAPHQL_ENDPOINT_*`|both panels|**unset** — the same-origin defaults in `src/env.ts` are the correct production values|
|`PUBLIC_RESOURCE_URL`|`marketplace-user` SSR|loopback `http://127.0.0.1:4027`, deliberately not through nginx|

`APP_DOMAIN` pointing at the admin host instead of the shop-owner one sends every shop owner's
registration link to a panel that will never authenticate them.

## Install

```bash
sudo cp conf.d/*.conf              /etc/nginx/conf.d/
sudo cp snippets/*.conf            /etc/nginx/snippets/
sudo cp sites-available/*.conf     /etc/nginx/sites-available/

for h in marketplace-domain.com shopowner.marketplace-domain.com admin.marketplace-domain.com; do
	sudo ln -sf /etc/nginx/sites-available/$h.conf /etc/nginx/sites-enabled/$h.conf
done

sudo mkdir -p /var/cache/nginx/marketplace-user /var/www/acme
sudo chown -R www-data:www-data /var/cache/nginx/marketplace-user

sudo nginx -t && sudo systemctl reload nginx
```

Retention is part of the install, not an afterthought — the error logs carry a client address in every
line and their lifetime is the only control on it:

```bash
sudo cp logrotate.d/nginx /etc/logrotate.d/nginx      # over the packaged one, deliberately
sudo logrotate -d /etc/logrotate.d/nginx              # parses, and lists what it will rotate
```

⚠️ **Over the packaged file, under the same name.** Two files in `/etc/logrotate.d` globbing
`/var/log/nginx/*.log` are a duplicate entry: logrotate prints
`error: <file>:1 duplicate log entry for …`, skips the **whole** later-named file and exits 1. Installed
as `marketplace-nginx` it would be the distribution's weekly `rotate 4` that wins on name order and this
policy that is silently dropped, with the only trace in cron mail. It is a dpkg conffile, so `apt` will
ask on the next nginx upgrade — keep the local version.

⚠️ **`shred` needs GNU coreutils and fails open without it.** logrotate shreds by handing the open
descriptor to `shred … -`, which busybox's applet cannot do; on such a host every removal prints
`Failed to shred …, trying unlink`, unlinks anyway and still exits 0. Debian 13 ships GNU coreutils, so
the target is fine — an Alpine-based image is not.

Certificates, one per host (the apex's covers `www` too):

```bash
sudo certbot certonly --webroot -w /var/www/acme \
	-d marketplace-domain.com -d www.marketplace-domain.com
sudo certbot certonly --webroot -w /var/www/acme -d shopowner.marketplace-domain.com
sudo certbot certonly --webroot -w /var/www/acme -d admin.marketplace-domain.com
```

## Authenticated Origin Pulls — making the origin accept Cloudflare only

**Configured here, not yet switched on at Cloudflare.** `snippets/origin-pull.conf` is in the
repo and included by all four 443 blocks, and the suite asserts both directions against a throwaway CA
it generates itself. What is *not* done is step 2 below — the Cloudflare side — and until it is, this
configuration must not reach the host: nginx would demand a client certificate that nothing is
presenting. Read §3 before deploying, and follow the order.

### Why the origin is otherwise open

The zone is Cloudflare-proxied (orange cloud) with the TLS mode on **Full (strict)**. Neither of those
refuses anybody:

- **Full (strict) is a TLS mode, not an access control.** It encrypts the Cloudflare→origin leg and has
  Cloudflare validate this origin's certificate. It says nothing about who else may connect.
- **nginx never declines to serve on the strength of its own certificate.** A TLS server presents what it
  is configured with; the *client* decides whether to trust it. `curl -k`, `openssl s_client` and every
  scanner skip that decision. The certificates here are Let's Encrypt in any case — publicly trusted, so a
  direct connection with the right SNI gets a clean chain and no warning at all.

What *is* already refused is the untargeted half: `ssl_reject_handshake on` in the default server
(`conf.d/40-tls.conf`) kills the handshake before any certificate is presented when a connection carries
no SNI or an SNI for a host this instance does not serve. A mass IP scan therefore indexes nothing here
and this origin is not discoverable that way.

What is not refused is a caller who sets SNI and `Host` to a hostname the edge does serve — and every one
of those names is public by construction, each Let's Encrypt issuance being recorded in Certificate
Transparency. That caller reaches the origin directly and skips the WAF, the bot rules and every
Cloudflare-side rate limit. Authenticated Origin Pulls closes that half and only that half.

It works by making the leg **mutual**: Cloudflare presents a client certificate and nginx verifies it.
No address list, so nothing to refresh when Cloudflare publishes new ranges.

### Three configurations, and they are not equivalent

| Configuration | Cloudflare side | nginx trusts | Weakness |
|---|---|---|---|
| **Zone-level, global certificate** | one dashboard toggle | Cloudflare's shared origin-pull CA | the same certificate is presented for **every Cloudflare customer** — anyone who points their own zone at this origin passes |
| **Zone-level, own certificate** | API upload + enable | a CA generated here | none; one certificate covers all four server blocks |
| **Per-hostname, own certificate** | API upload + per-hostname association | a CA generated here | same strength, more lifecycle — one association per hostname, and each is a thing that can be forgotten |

⚠️ **The global certificate stops the internet, not an attacker with a free Cloudflare account.** Take it
only as an interim step, and pin the identity as well as the issuer if you do — `$ssl_client_s_dn` or
`$ssl_client_fingerprint` in a `map`, refusing anything that is not the expected value. Verifying the
issuer alone proves nothing more than "some Cloudflare customer".

There are three hostnames here and all of them want the same answer, so **zone-level with an own
certificate is the configuration to use**. Per-hostname earns its extra lifecycle only if one hostname
must stay reachable without Cloudflare, which is not the case here.

### 1. Generate the CA and the client certificate

```bash
# The CA nginx will trust. Long-lived: replacing it is a coordinated change on both sides.
openssl genrsa -out origin-pull-ca.key 4096
openssl req -x509 -new -nodes -key origin-pull-ca.key -sha256 -days 3650 \
	-subj "/CN=marketplace origin pull CA" -out origin-pull-ca.pem

# The certificate Cloudflare will present. Its expiry is the outage clock — see Renewal below.
openssl genrsa -out cloudflare-client.key 2048
openssl req -new -key cloudflare-client.key -subj "/CN=cloudflare-origin-pull" \
	-out cloudflare-client.csr
openssl x509 -req -in cloudflare-client.csr -CA origin-pull-ca.pem -CAkey origin-pull-ca.key \
	-CAcreateserial -days 825 -sha256 -out cloudflare-client.pem
```

⚠️ **`origin-pull-ca.key` and `cloudflare-client.key` are secrets and never enter this repo.** Generate
them off the repo tree. `.githooks/pre-commit` matches both `*.pem` and `*.key` paths, so an attempt to
stage one is refused — the guard and the convention agree, and neither is a reason to relax the other.
Only `origin-pull-ca.pem` reaches the server, and it goes beside the Let's Encrypt material rather than
into version control:

```bash
sudo install -m 644 -o root -g root origin-pull-ca.pem /etc/nginx/certs/origin-pull-ca.pem
```

### 2. Cloudflare side — enable it **first**

Endpoint paths as of 2026-08; check them against Cloudflare's current API reference before running any
of this, and read `$CF_API_TOKEN` from your own store rather than pasting it.

**Zone-level, own certificate** — upload the client certificate and its key, then switch the zone on:

```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/origin_tls_client_auth" \
	-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
	--data "$(jq -n --rawfile c cloudflare-client.pem --rawfile k cloudflare-client.key \
		'{certificate:$c, private_key:$k}')"

curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/origin_tls_client_auth/settings" \
	-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
	--data '{"enabled": true}'
```

**Per-hostname, own certificate** — upload against
`/zones/$ZONE_ID/origin_tls_client_auth/hostnames/certificates`, then associate each hostname via
`PUT /zones/$ZONE_ID/origin_tls_client_auth/hostnames`. A per-hostname configuration takes precedence
over the zone-level one for the hostnames it names, so the two can disagree silently: if you use it,
use it for all three hostnames rather than mixing.

**Zone-level, global certificate** — Dashboard → SSL/TLS → Origin Server → *Authenticated Origin Pulls*.
Nothing to upload; nginx then trusts the CA Cloudflare publishes in its Authenticated Origin Pulls
documentation instead of `origin-pull-ca.pem`. Re-read the warning above before choosing this.

### 3. nginx side — stage it on the host, do not go straight to `on`

`snippets/origin-pull.conf` already exists and already reads `on`, because that is the state the repo
describes and the state the suite asserts:

```nginx
ssl_client_certificate /etc/nginx/certs/origin-pull-ca.pem;
ssl_verify_client      on;
```

It is included at **server level in all four 443 blocks** — the `www` redirect and the apex in
`sites-available/marketplace-domain.com.conf`, plus the shop-owner and admin vhosts. The `www` block
is a redirect and easy to skip; skipping it leaves one name that still answers an unauthenticated
caller, which is exactly the property being removed. `grep -c 'include snippets/origin-pull.conf'` over
`sites-available/` must read 4, and the suite asserts that count as well as the behaviour.

The default server in `conf.d/40-tls.conf` is **left alone**, and the suite asserts it declares neither
directive. `ssl_reject_handshake on` refuses earlier in the handshake than client verification runs, so
adding them there is dead configuration that reads as a second control.

**On the host, edit that one word to `optional` for the first deployment.** Verification is then
performed but a failure is not fatal, so a Cloudflare side that is not yet presenting anything degrades
to a log line rather than an outage. Put the result in the access log and watch it:

```nginx
log_format origin_pull '... $ssl_client_verify $ssl_client_s_dn';
```

`$ssl_client_verify` reads `SUCCESS` for every request once Cloudflare is presenting the certificate, and
`NONE` for a connection that presented none. When the log shows `SUCCESS` and nothing else across all
three hostnames, restore the committed `on` and reload. ⚠️ **That temporary `optional` is a host-local
edit and must never be committed back** — a repo reading `optional` is a repo whose origin is open,
which is the condition this whole section exists to remove.

⚠️ **Order is the whole risk here.** Cloudflare presents a client certificate only where the feature is
switched on. Deploying `ssl_verify_client on` before step 2 means every request to those vhosts fails
from the moment nginx reloads — a total outage on all three hostnames, presenting as a TLS fault rather
than as a toggle nobody flipped.

### 4. Verify

```bash
# Through Cloudflare: must still work.
curl -sI https://marketplace-domain.com/ | head -1

# Straight at the origin, no client certificate: must not be served.
curl -sv --resolve marketplace-domain.com:443:<origin-ip> https://marketplace-domain.com/ 2>&1 | tail -5
```

Two different failures, and both count as a pass:

- **No certificate presented** — the handshake completes and nginx answers
  `400 Bad Request — No required SSL certificate was sent`.
- **A certificate from the wrong CA** — OpenSSL aborts during the handshake, and curl reports a TLS
  alert rather than any HTTP status.

Port 80 is untouched by all of this, so `certbot renew` over HTTP-01 keeps working — the ACME challenge
is plain HTTP and reaches `/var/www/acme` exactly as before.

### 5. Renewal

⚠️ **`cloudflare-client.pem` expires and nothing renews it.** On that day all four server blocks stop
accepting Cloudflare and the whole platform is unreachable, with a symptom that looks like a certificate
problem on the wrong side of the connection. It is not `certbot`'s certificate and `certbot renew` will
not touch it.

The expiry date, the owner and this procedure are risk **R44** in the parent workspace's
`docs/devprotocol/phase5/RISK_REGISTER.md`; fill the date in there the day step 1 is run for real, since
nothing in this repo can know it. Renewing is step 1 for the client certificate only — same CA, new `cloudflare-client.pem` — then
step 2's upload. The CA and therefore `/etc/nginx/certs/origin-pull-ca.pem` stay as they are, so nginx
needs no reload.

One consequence worth writing down for whoever operates this: **an uptime probe or health check pointed
straight at the origin will fail by design** once this is on. Point monitoring at the Cloudflare
hostname, or give the probe a client certificate of its own signed by the same CA.

#### Noticing before the day arrives

```bash
./marketplace-nginx/scripts/check-origin-pull-cert-expiry.sh --file /etc/nginx/certs/origin-pull-ca.pem
./marketplace-nginx/scripts/check-origin-pull-cert-expiry.sh --file /path/to/cloudflare-client.pem --warn-days 30
```

Exit `0` the certificate outlives the window (default 60 days), `1` it does not, `2` the path is not a
certificate this host can read — three answers rather than two, because a timer that reports "fine" for a
path that moved is worse than no timer. It prints the subject and the `notAfter` date and nothing else;
it never reads a private key.

⚠️ **It detects. It does not renew.** Renewal is steps 1 and 2 above, run by a human with Cloudflare API
credentials this repo does not hold, and this script is a second layer beside the calendar entry in R44 —
never a replacement for recording the real issuance date the day step 1 is run.

⚠️ **Two certificates expire on this connection and only one of them lives on this host.**
`origin-pull-ca.pem` is the CA nginx verifies against, and when it lapses every Cloudflare client
certificate stops verifying — the same outage, from the other end. `cloudflare-client.pem` is uploaded to
Cloudflare rather than served from here, so point the script at the copy you retained, or it is checked by
nobody. Give both their own timer:

```
# /etc/systemd/system/origin-pull-expiry.service — Type=oneshot, OnFailure= an alert unit
ExecStart=/opt/marketplace-nginx/scripts/check-origin-pull-cert-expiry.sh --file /etc/nginx/certs/origin-pull-ca.pem
ExecStart=/opt/marketplace-nginx/scripts/check-origin-pull-cert-expiry.sh --file /etc/nginx/certs/cloudflare-client.pem
```

Daily is enough — the window is measured in weeks. A `cron` line works as well; what matters is that a
non-zero exit reaches a person, since a check whose failure goes to a log nobody reads is the state this
replaces.

## Testing it, before it reaches a host

```bash
./marketplace-nginx/test/run.sh
```

Starts a throwaway `nginx:stable-alpine` container with `marketplace-nginx/` mounted read-only, generates self-signed
certificates so the `ssl_certificate` lines resolve, runs `nginx -t`, then starts nginx for real against
stand-in backends and asserts what comes out of the socket. Exits non-zero on any failure. Nothing is
installed on the machine and nothing is written to the repository.

There is no nginx on the development machine, which is the whole reason this exists: without it the only
way to find out whether a directive works is to install the configuration somewhere that matters.

**`.githooks/pre-push` runs exactly this on every push and blocks on any failure.** It checks its
prerequisites first and blocks rather than skipping when one is missing — no container engine, an
unreachable daemon, the image absent locally, a non-executable `test/run.sh` — because a gate that
steps aside when it cannot run is not a gate, and this repo has only this one for the configuration. It reads the engine and
image defaults out of `test/run.sh` instead of repeating them, and honours the same two overrides, so
`NGINX_TEST_IMAGE=nginx:1.29-alpine git push` checks and tests the image it is about to gate on. There
is no bypass variable: the suite takes well under a minute, and `git push --no-verify` is the escape
hatch precisely because it is conspicuous.

|Group|What it asserts|
|---|---|
|`nginx -t`|the configuration loads at all — hard gate, nothing else runs if it fails|
|**cookie rewrite**|every `Set-Cookie` on all 7 cookie-minting endpoints comes out `Secure; HttpOnly; SameSite=Strict`, including the cleared cookie from `/logout`|
|path → service|each path reaches the service it names, by identity and not by status code|
|tier isolation|no host reaches another tier's service — asserted against the **foreign backend by name**|
|proxy headers|`X-Forwarded-Proto: https` and the original `Host` survive the hop|
|CSP nonce|the nonce in the delivered HTML equals the one in the header, on a cache MISS **and** a HIT|
|security headers|every location that sets an `add_header` of its own still ships the full policy|
|SSR cache|MISS → HIT → BYPASS with a session, and the session response is never stored; a URL carrying a mailed `:email/:hash` credential is BYPASS on the first visit and on the second — never a HIT off its own key — while an ordinary page still goes MISS → HIT, which is what stops a too-greedy bypass regex from turning the cache off unnoticed|
|server hardening|`Server:` carries no version on any host; the two token endpoints are **not** compressed while `/assets/` is, checked against a body large enough for the difference to mean something|
|TLS + redirects|308 on all four names, `www` → apex over TLS, ACME reachable on `:80`, unknown `Host` refused|
|panel hardening|source maps 403, `robots.txt` disallow, SPA fallback intact, dotfiles denied|
|rate limits|all three login zones — customer, shop owner, admin — let the burst through and then return 429, each out of its own budget|
|real client address|a `CF-Connecting-IP` from outside `set_real_ip_from` is ignored and the caller's `X-Forwarded-For` never reaches the upstream; from inside it, `$remote_addr` becomes the claimed address, a second address gets a budget of its own, and flooding a rotation zone leaves that address able to log in — and the reverse|
|origin pulls|all four 443 blocks refuse a caller presenting no client certificate and serve one presenting a certificate from the trusted CA; a certificate from an unrelated CA is refused; `ssl_verify_client` is declared once, the default server has none, and `:80` still completes an ACME challenge with no certificate at all|
|access logging|the format names no address variable and still names everything that is not one; no `access_log` in the repo is left without it; and a real request carrying `CF-Connecting-IP` and an `X-Forwarded-For` produces a log line holding neither — asserted twice, the second time with `set_real_ip_from` in effect so `$remote_addr` is the client|
|mailed-link redaction|the format names no raw `$request`, `$request_uri` or `$http_referer`, and both redacting maps exist; all four `:email/:hash` links are then driven for real — encoded `%40` and decoded `@` — and each log line keeps the flow name, drops the address and the hash, and stays address-free; the last one carries the reset URL in `Referer` instead of in the path|
|log retention|`logrotate.d/nginx` parses, reads back as 14 daily rotations, and covers every destination the repo names plus nginx's own `error.log`; the shape is asserted directive by directive; then sixteen forced rotations run for real and both removals — the plaintext copy at compression time and the generation that falls off `rotate 14` — go through `shred` with no error|

The access-logging group runs after the rate-limit one and reloads nginx a second time, with
`test/real-ip-overlay.conf` trusting the loopback. That overlay exists because the deployed
`conf.d/06-real-ip.conf` cannot be used here: it trusts Cloudflare's published ranges, the container
connects from its own loopback, and the real file would therefore leave `$remote_addr` at 127.0.0.1 —
the second half of the assertions would pass without ever having been exercised. The upstream echoes
`X-Real-IP` back, and the suite asserts it has become the client address before believing anything the
log assertions say.

The retention group runs **last of all, and nothing may be added after it**: it rotates
`/var/log/nginx/*.log` for real, sixteen times, so every file the groups above assert on has been
renamed and gzipped by the time it finishes. It creates a `www-data` user the image does not have,
because `create 0640 www-data adm` is resolved when the config is read and the point of the group is
that the bytes the repo installs are the bytes that work.

The rate-limit group runs **after everything except that, and after a full nginx restart**, and every other endpoint is probed
exactly once. `limit_req` counters live in shared memory: they survive a reload, and a suite that spent
the budget early would fail the endpoints it tested afterwards for the wrong reason.

The stand-in backends set their cookie exactly the way koa-utils does today — `secure: false`, no
`SameSite`. That is deliberate: anything flagged in the output was flagged by
`snippets/proxy-backend.conf` and by nothing else. Do not "fix" `test/fake-backends.conf` to set the
flags itself; the headline test would then pass with nginx doing nothing.

Check a version bump before rolling it out:

```bash
NGINX_TEST_IMAGE=nginx:1.29-alpine ./marketplace-nginx/test/run.sh
CONTAINER_ENGINE=podman ./marketplace-nginx/test/run.sh
```

**Real defects this suite found, all of them already fixed here.** The first two are the ones worth
knowing; neither is visible to `nginx -t` and neither is visible by reading the file.

1. `add_header Content-Security-Policy "\` with one directive per line — the readable form carried over
   from `marketplace-user/docs/nginx/` — **emits no header at all**. nginx does not do backslash
   line-continuation inside a quoted string; the `\` escapes the newline, which puts a literal LF into
   the value, and the header is then dropped. Every other header in the same file kept working, which is
   what makes it hard to spot. Both snippets now carry the value on one line.
2. Handing the SSR renderer a per-request nonce and caching its HTML cannot both be true. On every cache
   HIT the body carries the nonce of whoever populated the entry while the header carries a fresh one,
   and the browser blocks hydration — but it works on a MISS, so it survives local testing and breaks
   from the second visitor onwards. The renderer now emits a constant `__CSP_NONCE__` placeholder and
   nginx substitutes it with `sub_filter`, which runs after the cache.
3. `keepalive_timeout` in `conf.d/00-hardening.conf` is `[emerg] … directive is duplicate` and nginx
   refuses to start — both Debian's and the official image's stock `nginx.conf` already set it at http
   level. This one `nginx -t` does catch, which is exactly why the gate exists; it was caught before the
   file was ever written to a host. The comment in that file says what to edit instead.
4. `ssl_stapling on` was configured and could never have worked: Let's Encrypt retired OCSP in 2025, and
   stapling needs a `resolver`, which nginx does not inherit from the system. It is now off with the
   recipe kept in a comment for a CA that still answers.
5. `sub_filter_types text/html;` is `[warn] duplicate MIME type "text/html"` — `text/html` is already in
   the default set and restating it is not free. Removed; the reasoning stayed as a comment.
6. `location = /api/register` and `location /api/` proxied to the SSR process under a dedicated 5r/m
   `mkt_register` zone, documented as verifying Turnstile server-side before forwarding to the
   `userRegister` mutation. **No `/api/*` route has ever existed in `marketplace-user/src/routes/`**, so
   both blocks matched paths the renderer answers with a 404 and the zone metered nothing. Deleted rather
   than built: the Turnstile secret is already server-side in `marketplace-dev-public-resource` and always
   was, and registration is already limited there by `guardPublicWrite` — one Redis counter per hour *per
   email address*, which no `$binary_remote_addr` zone can express (the per-address half is this repo's,
   and the service's own copy of it was removed as a counter that metered nothing but nginx).
   Building the
   route would have pushed plaintext passwords through a second process to weaken both controls. The apex
   vhost and `conf.d/20-rate-limit.conf` each carry the reasoning where the block used to be.

Two smaller hardening gaps were closed at the same time, both of which the suite now guards: the
`Server:` header advertised the exact nginx version, and the four authorization endpoints compressed a
response body carrying a freshly minted access token — the BREACH shape. `gzip off` on those locations,
`server_tokens off` at http level.

## Verifying a live deployment

**The `Secure` flag — check this first, on every host that can mint a cookie.**

```bash
# Log in and look at the Set-Cookie the edge produced.
curl -sD - -o /dev/null -X POST https://marketplace-domain.com/public-authorization \
	-H 'content-type: application/json' \
	-d '{"query":"mutation{loginUser(email:\"…\",password:\"…\"){__typename}}"}' \
	| grep -i '^set-cookie'
# expected on BOTH the refresh_token and refresh_token.sig lines:
#   Secure; HttpOnly; SameSite=Strict
```

Repeat against `https://shopowner.marketplace-domain.com/public-authorization` and
`https://admin.marketplace-domain.com/public-authorization`. A missing `Secure` means the snippet is not
included at server level on that vhost — the application will not add it.

```bash
# Cache: a cold anonymous request, then a warm one
curl -sI https://marketplace-domain.com/shops | grep -i x-cache-status   # MISS
curl -sI https://marketplace-domain.com/shops | grep -i x-cache-status   # HIT

# a request carrying a session must never be cached
curl -sI -H 'Cookie: refresh_token=whatever' https://marketplace-domain.com/shops \
	| grep -i x-cache-status                                              # BYPASS

# nor must a mailed link, whose URL *is* the credential — anonymous, so the cookie map sees nothing
curl -sI 'https://marketplace-domain.com/reset-password/someone%40example.com/HASH' \
	| grep -i x-cache-status                                              # BYPASS

# the HTML must contain the metadata, not a JS bundle that will add it later
curl -s https://marketplace-domain.com/shop/<slug> | grep -E '<title>|rel="canonical"|application/ld\+json'

# panels: no source maps, no indexing, SPA fallback intact
curl -sI https://admin.marketplace-domain.com/assets/index-<hash>.js.map   # 403
curl -sI https://admin.marketplace-domain.com/ | grep -i x-robots-tag      # noindex, nofollow, noarchive
curl -sI https://admin.marketplace-domain.com/companies                    # 200, index.html

# an unknown Host is refused rather than served by whichever vhost sorted first
curl -sI https://marketplace-domain.com/ -H 'Host: nothing.marketplace-domain.com'  # closed / 444

# the cache is actually absorbing the load
autocannon -c 100 -d 20 https://marketplace-domain.com/shops
```

If the second HTML request is a `MISS`, the response carried a `Set-Cookie` or a `Cache-Control: private`
from the app — nginx will not store either. That is the app's bug, not the edge's.

## Things that are easy to get wrong

**`proxy_cookie_flags` is inherited only when the current level declares none of its own.** It is
included once at server level in each vhost and no location redefines it. A location that declared its
own `proxy_cookie_flags` for any reason would silently drop `Secure` from that endpoint's cookies.

**`add_header` does not merge.** A location declaring even one `add_header` of its own discards every
header inherited from the server block. Every such location re-includes its security-headers snippet.
Add a location that sets a header, include the snippet there too, or that response ships bare.

**A CSP written one directive per line with `\` at the end of each ships no CSP.** nginx has no
line-continuation inside a quoted string — the backslash escapes the newline and embeds a literal LF,
and the header is discarded on the way out while every other `add_header` in the file keeps working.
Both snippets keep the value on a single line with the directive list in a comment above it. `nginx -t`
does not catch this; `./marketplace-nginx/test/run.sh` does.

**The SSR renderer must emit `nonce="__CSP_NONCE__"` verbatim, not a real nonce.** nginx substitutes it
per request with `sub_filter`, after the cache. A renderer that stamps its own value bakes one visitor's
nonce into a cached page served to everyone else, and every cache HIT then blocks hydration. This is an
application contract: if `marketplace-user` starts writing real nonces, the placeholder substitution
silently stops matching and the pages break on HITs only.

**`proxy_cache_bypass` and `proxy_no_cache` are different directives and the customer vhost needs
both.** The first skips the *lookup*; the second skips the *store*. With only the first, a logged-in
customer's personalised HTML is fetched fresh and then saved for the next anonymous visitor.

**Both of them read *two* variables, and the second one is not about the visitor.** `proxy_cache_key` is
the full request URI, so a mailed `/reset-password/:email/:hash` link becomes a file under
`/var/cache/nginx/marketplace-user/` whose header holds an account address next to a live one-time hash —
kept up to `inactive=24h`, which is the lifetime, not the 60s of `proxy_cache_valid`, and in a directory
nothing rotates and nothing shreds. ⚠️ **The cookie map cannot catch it**: that route has no `location`
block of its own and whoever follows a reset link is anonymous by definition, so `$mkt_user_no_cache` is 0
for exactly the request that must not be stored. `$mkt_credential_uri` is the URL test beside
it, matching the same four prefixes `conf.d/05-logging.conf` redacts — the log and the cache have to agree
about which links carry a credential, and the suite fails if the two lists drift.

**The private areas are client-rendered, so they never produce cacheable HTML in the first place.** The
bypass map is the second line of defence, not the first. Do not weaken the app's rendering split on the
grounds that nginx is handling it — and never turn SSR on for an `/account` route.

**`limit_req_zone` name = counter.** Two vhosts naming the same zone share one budget per address. The
panels have zones of their own for exactly that reason; renaming one to reuse another's merges them
back.

**All zones key on `$binary_remote_addr`, and so do the commented-out allow-lists — which means they
key on whatever `conf.d/06-real-ip.conf` last said to trust.** Delete that file and every visitor
shares one bucket per Cloudflare point of presence and an allow-list allows the whole internet; widen
`set_real_ip_from` past Cloudflare's ranges and any caller can claim any address by setting one header.
The list in it is a vendored copy of `cloudflare.com/ips-v4` and `ips-v6` with the fetch date and the
regeneration command at the top, and it expires without failing: a range Cloudflare added after that
date is simply not trusted, and the only symptom is those visitors metering as an edge address again.

**Read `CF-Connecting-IP`, never `X-Forwarded-For`.** Cloudflare appends to a caller-supplied
`X-Forwarded-For` rather than replacing it, so its first entry is attacker-controlled; a limiter keyed
on it gives every attacker a private bucket, which is worse than the shared one. `CF-Connecting-IP` is
single-valued and overwritten unconditionally, and `real_ip_recursive` is `off` because a single-valued
header has no chain to walk.

**An `access_log` with no format name is not a default, it is `combined` — and so is declaring none at
all.** `conf.d/05-logging.conf` defines `mkt_access`, which records no address of any kind, and all
eight server blocks name it. A server block that declares no `access_log` inherits the stock http-level
one instead, which is why the three `:80` redirects, the `www` redirect and the `444` default server
each carry the line rather than only the three vhosts. And an http-level `access_log` here would not
fix that: `access_log` is additive at the same level, so the stock one would keep writing alongside it.
Today the address in those lines would be a Cloudflare edge address; `conf.d/06-real-ip.conf` turns it
into a visitor's, with nothing in that diff to say so.

**`$request` and `$http_referer` are the mailed links in full, so the format names neither.** Four
links put `:email/:hash` in the path — the two `/check/verify-email*` routes, the customer's
`/reset-password/` and the shop owner's `/x/reset/` — and the hash is live while the line sits on
disk. `conf.d/05-logging.conf` therefore builds the request line from `$request_method`, a
`$request_uri` passed through a `map`, and `$server_protocol`, and passes the referer through a
second map, because a raw variable cannot be rewritten. Three things follow that are easy to undo by
accident. Redacting per `location` covers half the links and looks complete — only two of the four
have a block of their own, and the map is at http level for that reason. Putting `$request` back for
"better debugging" restores the credential on every one of them. And the referer is not decoration:
`strict-origin-when-cross-origin` on the customer surface sends the full URL on same-origin requests,
so the reset page's own asset and GraphQL calls carry the link into the next field along.

**`snippets/origin-pull.conf` goes in four server blocks, and a vhost count says three.** The `www`
redirect in `sites-available/marketplace-domain.com.conf` is a server block of its own; leaving it out
leaves one hostname answering any caller, which is the whole property the snippet removes. The default
server in `conf.d/40-tls.conf` is the mirror-image mistake: `ssl_reject_handshake on` refuses earlier in
the handshake than client verification runs, so adding the directives there is dead configuration that
reads as a control. The suite asserts the count, the single `ssl_verify_client` declaration and the
default server's absence from it.

**The origin now answers Cloudflare and nothing else, which includes your monitoring.** An uptime probe
or health check pointed straight at the origin address fails by design once this is enabled on the
Cloudflare side. Point it at the hostname, or issue it a client certificate from the same CA. The same
goes for anyone debugging with `curl --resolve` — the `400 Bad Request` is the control working.

**The `error_log` is a separate file that none of this reaches.** nginx hard-codes a `client: <address>`
prefix into every error entry and exposes no format for it — only the destination and the level. The
access-log format is not a property of the edge as a whole. Measured, at the `warn` all three vhosts
ship, five of five request-scoped entries carry that prefix and the 162 process-lifecycle entries carry
none — so every line in a per-host error log is a line with an address in it. That is decided rather
than pending: the address stays, and `logrotate.d/nginx` makes the file's lifetime the control instead.
Changing the level breaks the decision in both directions — `info` adds two more
address-bearing classes, and anything stricter than `warn` drops the failures the file exists for — so
the suite asserts all three are still `warn`.

## Known gaps, stated so they are not read as oversights

- **`/x/registration-done`, `/x/email-check` and `/x/error` exist in no frontend.** The email-verify
  handler in koa-utils redirects to them relative to the host it ran on. On the shop-owner vhost they
  fall through to the SPA, which has no route for any of the three, so a verified shop owner lands on
  the login page rather than a confirmation. Application gap, not an edge one — nginx has nowhere better
  to send them.
- **No `/media/` or image-serving location anywhere.** The two resource services mount
  `graphqlUploadKoa` and both panels' upload endpoints are sized for it, but `item` carries no image
  field yet and nothing serves `UPLOAD_DIR` back to a browser. When that lands it needs a location here,
  a `Cross-Origin-Resource-Policy`, and a decision about whether the apex or a fourth host serves it.
- **Every service port is reachable wherever the machine is.** These vhosts do not bind the service
  ports and the services bind the wildcard address, so nothing here stops a caller that can route to
  the host from talking to 4024-4032 directly. Narrowing that needs a firewall or a bind change,
  neither of which is nginx's to make — blocked on the production-topology ADR that
  `ADR-INDEX.md:87` already records as owed.
- **No `__Host-` cookie prefix.** `__Host-refresh_token` would make host-only + root-path + Secure
  browser-enforced rather than configuration-enforced, but the name is set in koa-utils and read by
  `cache.conf`'s bypass map and the three SPAs. It belongs in the same koa-utils release as
  `secure: true`, not here.
- **HTTP/3 is not configured.** `listen 443 quic reuseport` plus an `Alt-Svc` header would add it;
  it needs a build with the QUIC module and is a performance change, not a correctness one.

## License

GPL-3.0-or-later — see [LICENSE](./LICENSE).
