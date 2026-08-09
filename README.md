# nginx — the platform edge

The production edge for all three domains, in one place. **This directory is authoritative.**
`marketplace-user/docs/nginx/` held the customer vhost alone and is now a pointer at this folder — its
four `.conf` files are deleted, not copied, so there is one edge configuration and not two. The two
panels had no checked-in vhost at all, which is the documentation asymmetry recorded as §3.7g of
`docs/report/token-handling-security-audit.md` — the two higher-privilege surfaces were the undocumented
ones.

It lives in the workspace root rather than in any one repo because it is the one artefact that is not
per-repo: a single nginx instance fronts eleven loopback upstreams across five of the fifteen repos, all three
vhosts share the upstream table and the rate-limit zones, and the same `logout` service answers on all
three hosts. Split across repos, no copy is ever the whole configuration.

**No nginx exists in this workspace or on this development machine** — there is no `/etc/nginx` and no
nginx binary in `PATH`. These files describe the production edge. Nothing here has been run.

## The three domains

| Host | App | Repo | Root | Audience |
|---|---|---|---|---|
| `marketplace-domain.com` | public site + customer account area | `marketplace-user` | `/srv/marketplace-user/dist/client` + SSR on 3045 | anonymous + `User` |
| `shopowner.marketplace-domain.com` | shop-owner panel | `marketplace-shopowner` | `/srv/marketplace-shopowner/dist` | `ShopOwner` |
| `admin.marketplace-domain.com` | operator panel | `marketplace-admin` | `/srv/marketplace-admin/dist` | `Admin` |

`www.marketplace-domain.com` 308s to the apex over TLS. Any other name reaching this instance is refused
at the handshake by the default server in `conf.d/40-tls.conf`.

Three hosts, not one, and the split is load-bearing in four places:

1. **The session cookie has no `Domain` attribute**, so it is host-only. An operator's session is not
   sent to the shop-owner host and cannot be read there. One host for all three tiers would put every
   tier's cookie in one jar.
2. **`APP_DOMAIN` vs `APP_DOMAIN_USER`.** `marketplace-dev-public-resource` builds the shop owner's
   verification link from the first and the customer's from the second. `/check/verify-email/` and
   `/check/verify-email-user/` are two routes against two collections; neither can tell from an
   `(email, hash)` pair which one minted it, so they are separated by host as well as by path.
3. **Rate limiting.** All three logins hit the same process on 4028. The edge is the only layer that
   still knows which hostname was asked for, so it is the only place a stuffing run against operator
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
it, not which networks may observe it. That is §3.1 🔴 Critical of the token-handling audit, and this
directory closes it — **as long as nginx is actually in front.** Nothing else on the platform sets the
flag, nothing fails without it, and no test in any of the fifteen repos covers it.

`secure: true` in koa-utils remains the real fix (it is the sixteenth repo, outside this workspace, and
not bridged by `deploy-local.sh` the way `marketplace-common` is). When it lands, this line stays: it is
then a second lock on the same door, and the only one a config review can see.

## Files

|File|Level|Role|
|---|---|---|
|`conf.d/00-hardening.conf`|http|`server_tokens off`, slow-request timeouts, header buffers|
|`conf.d/10-upstreams.conf`|http|every backend, one `upstream` each, with keepalive pools|
|`conf.d/20-rate-limit.conf`|http|`limit_req_zone` / `limit_conn_zone` — per-surface, not shared|
|`conf.d/30-cache.conf`|http|HTML cache zone and session-bypass map, customer surface only|
|`conf.d/40-tls.conf`|http|protocols, ciphers, session cache, and the `444` default server|
|`snippets/proxy-backend.conf`|server|**the `Secure` rewrite**, keepalive, forwarded headers, timeouts|
|`snippets/security-headers-public.conf`|server/location|customer CSP + headers (nonce, MapLibre, Turnstile)|
|`snippets/security-headers-private.conf`|server/location|panel CSP + headers — strictly tighter, no nonce, no MapLibre, Turnstile allowed|
|`sites-available/marketplace-domain.com.conf`|—|customer vhost: SSR, cache, static, 5 endpoints, geocoder|
|`sites-available/shopowner.marketplace-domain.com.conf`|—|shop-owner vhost: SPA, 4 endpoints, `/check/verify-email/`|
|`sites-available/admin.marketplace-domain.com.conf`|—|operator vhost: SPA, 4 endpoints|
|`test/run.sh`|—|entry point — runs the suite below in a throwaway container|
|`test/suite.sh`|—|`nginx -t` plus 168 behavioural assertions; runs *inside* the container|
|`test/fake-backends.conf`|—|stand-ins for the eleven upstreams, test-only, never installed|

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

`APP_DOMAIN` pointing at the operator host instead of the shop-owner one sends every shop owner's
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

Certificates, one per host (the apex's covers `www` too):

```bash
sudo certbot certonly --webroot -w /var/www/acme \
	-d marketplace-domain.com -d www.marketplace-domain.com
sudo certbot certonly --webroot -w /var/www/acme -d shopowner.marketplace-domain.com
sudo certbot certonly --webroot -w /var/www/acme -d admin.marketplace-domain.com
```

## Testing it, before it reaches a host

```bash
./nginx/test/run.sh
```

Starts a throwaway `nginx:stable-alpine` container with `nginx/` mounted read-only, generates self-signed
certificates so the `ssl_certificate` lines resolve, runs `nginx -t`, then starts nginx for real against
stand-in backends and asserts what comes out of the socket. Exits non-zero on any failure. Nothing is
installed on the machine and nothing is written to the repository.

There is no nginx on the development machine, which is the whole reason this exists: without it the only
way to find out whether a directive works is to install the configuration somewhere that matters.

|Group|What it asserts|
|---|---|
|`nginx -t`|the configuration loads at all — hard gate, nothing else runs if it fails|
|**cookie rewrite**|every `Set-Cookie` on all 7 cookie-minting endpoints comes out `Secure; HttpOnly; SameSite=Strict`, including the cleared cookie from `/logout`|
|path → service|each path reaches the service it names, by identity and not by status code|
|tier isolation|no host reaches another tier's service — asserted against the **foreign backend by name**|
|proxy headers|`X-Forwarded-Proto: https` and the original `Host` survive the hop|
|CSP nonce|the nonce in the delivered HTML equals the one in the header, on a cache MISS **and** a HIT|
|security headers|every location that sets an `add_header` of its own still ships the full policy|
|SSR cache|MISS → HIT → BYPASS with a session, and the session response is never stored|
|server hardening|`Server:` carries no version on any host; the two token endpoints are **not** compressed while `/assets/` is, checked against a body large enough for the difference to mean something|
|TLS + redirects|308 on all four names, `www` → apex over TLS, ACME reachable on `:80`, unknown `Host` refused|
|panel hardening|source maps 403, `robots.txt` disallow, SPA fallback intact, dotfiles denied|
|rate limits|all three login zones — customer, shop owner, operator — let the burst through and then return 429, each out of its own budget|

The rate-limit group runs **last, after a full nginx restart**, and every other endpoint is probed
exactly once. `limit_req` counters live in shared memory: they survive a reload, and a suite that spent
the budget early would fail the endpoints it tested afterwards for the wrong reason.

The stand-in backends set their cookie exactly the way koa-utils does today — `secure: false`, no
`SameSite`. That is deliberate: anything flagged in the output was flagged by
`snippets/proxy-backend.conf` and by nothing else. Do not "fix" `test/fake-backends.conf` to set the
flags itself; the headline test would then pass with nginx doing nothing.

Check a version bump before rolling it out:

```bash
NGINX_TEST_IMAGE=nginx:1.29-alpine ./nginx/test/run.sh
CONTAINER_ENGINE=podman ./nginx/test/run.sh
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
   was, and registration is already limited there by `guardPublicWrite` — two Redis counters per hour, per
   IP *and per email address*, the second of which no `$binary_remote_addr` zone can express. Building the
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
does not catch this; `./nginx/test/run.sh` does.

**The SSR renderer must emit `nonce="__CSP_NONCE__"` verbatim, not a real nonce.** nginx substitutes it
per request with `sub_filter`, after the cache. A renderer that stamps its own value bakes one visitor's
nonce into a cached page served to everyone else, and every cache HIT then blocks hydration. This is an
application contract: if `marketplace-user` starts writing real nonces, the placeholder substitution
silently stops matching and the pages break on HITs only.

**`proxy_cache_bypass` and `proxy_no_cache` are different directives and the customer vhost needs
both.** The first skips the *lookup*; the second skips the *store*. With only the first, a logged-in
customer's personalised HTML is fetched fresh and then saved for the next anonymous visitor.

**The private areas are client-rendered, so they never produce cacheable HTML in the first place.** The
bypass map is the second line of defence, not the first. Do not weaken the app's rendering split on the
grounds that nginx is handling it — and never turn SSR on for an `/account` route.

**`limit_req_zone` name = counter.** Two vhosts naming the same zone share one budget per address. The
panels have zones of their own for exactly that reason; renaming one to reuse another's merges them
back.

**All zones key on `$binary_remote_addr`, and so do the commented-out allow-lists.** Behind a CDN or a
second proxy that is the proxy's address: every visitor shares one bucket and an allow-list allows the
whole internet. Configure `set_real_ip_from` and switch the key before putting anything in front of
this.

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
- **`INTROSPECTION_CODE` is still reachable wherever a service port is.** These vhosts do not bind the
  service ports and the services bind the wildcard address; "service-to-service only" needs a firewall
  or a bind change, neither of which is nginx's to make. §3.7c of the token audit, blocked on the
  production-topology ADR that `ADR-INDEX.md:87` already records as owed.
- **No `__Host-` cookie prefix.** `__Host-refresh_token` would make host-only + root-path + Secure
  browser-enforced rather than configuration-enforced, but the name is set in koa-utils and read by
  `cache.conf`'s bypass map and the three SPAs. It belongs in the same koa-utils release as
  `secure: true`, not here.
- **HTTP/3 is not configured.** `listen 443 quic reuseport` plus an `Alt-Svc` header would add it;
  it needs a build with the QUIC module and is a performance change, not a correctness one.
