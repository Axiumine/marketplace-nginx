# marketplace-nginx

The platform edge: one nginx, three vhosts, TLS terminating here and nowhere else, in front of the
eleven loopback processes. the one way to execute any of it is the throwaway container in `test/` or your local setup.

**Read parent first** — [`../CLAUDE.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/CLAUDE.md)

| Need | File |
|---|---|
| what every file holds, the host → path → service → port matrix, install, env assumptions | [`README.md`](./README.md) |
| the suite and its assertion groups | [`README.md`](./README.md) §Testing it, before it reaches a host |
| thirteen nginx traps written out at length | [`README.md`](./README.md) §Things that are easy to get wrong |
| what is deliberately not built here | [`README.md`](./README.md) §Known gaps |
| why the `Secure` flag is rewritten at the edge at all | [`README.md`](./README.md) §⚠️ The `Secure` cookie flag lives here |
| why the edge is a repo of its own, and the port table | [`../docs/architecture.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/docs/architecture.md) §nginx |

## Running it

```bash
./test/run.sh                                       # nginx -t, then the assertion suite in a container
CONTAINER_ENGINE=podman ./test/run.sh               # podman instead of docker
NGINX_TEST_IMAGE=nginx:1.29-alpine ./test/run.sh    # check a version bump before rollout
```

A container engine is a hard prerequisite. The repo mounts read-only at `/src`, the container is
`--rm`, nothing is installed on the host and nothing is written back into the repo. `run.sh` `exec`s
the engine, so the suite's exit code *is* `run.sh`'s exit code.

Read the **first** failure. `nginx -t` runs as a hard gate before anything else, and the behavioural
sections then keep going after a failure, so one bad directive prints dozens of downstream ones.

## What will bite you here

⚠️ **`add_header` does not merge across levels.** A location declaring even one `add_header` of its own
discards the entire inherited set from `server` level. Every location that adds a header must
re-include its vhost's `snippets/security-headers-public.conf` or `-private.conf`. This is the most
common way a CSP silently disappears from exactly one route.

⚠️ **Both CSP lines must stay on one physical line.** nginx has no backslash continuation inside a
quoted string: a `\` before a newline becomes a literal LF in the value, header validation fails, and
that one header is dropped silently while every other `add_header` in the file still ships.

⚠️ **`proxy_cookie_flags ~ secure httponly samesite=strict;` is the only thing on the platform that
sets `Secure` on the session cookie** — koa-utils ships `secure: false` with a comment saying to
rewrite it here. `snippets/proxy-backend.conf` must be included exactly once **per vhost at server
level**: `proxy_cookie_flags` is inherited only when the current level declares none of its own, so
re-including it inside a location works only by accident.

⚠️ **A rate-limit zone name *is* the counter.** Two locations naming one zone share a single budget per
address, across vhosts as well as within one. That is why the three login endpoints — all of them
proxying to the same backend on 4028 — carry three separate zones: `mkt_auth`, `mkt_owner_auth` and
`mkt_admin_auth`, all three at `rate=1r/m burst=20 nodelay`. nginx cannot see which GraphQL mutation the
shared process is being asked to run, so the per-vhost hostname is the only place those budgets can be
told apart. Renaming a zone onto an existing name merges two budgets with no error anywhere.

⚠️ **Rotation and login never share a zone, on any vhost.** `mkt_refresh`, `mkt_owner_refresh` and
`mkt_admin_refresh` (10r/m, burst 20) exist because they used to (E12-S09), and putting them back
together breaks two things at once: a token flood spends the login burst and holds the whole address to
1r/m, and rotation is timer-driven, so an office of fifty sessions rotating twice an hour is ~1.7/min
sustained and trips a login-sized ceiling with no attacker present. The suite asserts the separation
behaviourally in both directions.

⚠️ **Never add `proxy_ignore_headers Set-Cookie`.** nginx's default refusal to cache a response
carrying `Set-Cookie` is load-bearing on the customer vhost, on top of the `$mkt_user_no_cache` map —
and that map only works while the `refresh_token` cookie stays root-path-scoped, so narrowing its path
in koa-utils would serve one logged-in customer's HTML to everybody.

⚠️ **The cache bypass reads two variables and only one of them is about the visitor.**
`proxy_cache_key` is the full request URI, so a mailed `:email/:hash` link cached by `location /` is a
file whose header holds the account address beside a live one-time hash, kept for `inactive=24h` rather
than the 60s of `proxy_cache_valid`, in a directory nothing rotates. `$mkt_user_no_cache` never sees it —
that route has no `location` of its own and the visitor following a reset link is anonymous — so
`$mkt_credential_uri` in `conf.d/30-cache.conf` is the URL test beside it (E12-S26). It matches the same
four prefixes the logging maps redact, deliberately duplicated because that map needs a named capture and
this one needs a yes; the suite asserts both files still carry the list, since a fifth link added to one
of them would be redacted in the log and stored on disk in full.

⚠️ **The `__CSP_NONCE__` contract spans two repos.** The SSR renderer writes that literal placeholder
into its inline script tags and nginx substitutes the per-request `$csp_nonce` on the way out, so a
cached page never carries one visitor's nonce. `location /` therefore forces `Accept-Encoding ""` —
`sub_filter` cannot rewrite a compressed body. Break either half and the page loads but never
hydrates, with nothing in the console.

⚠️ **The access logs carry no client address, and one new `access_log` line reopens that.**
`conf.d/05-logging.conf` defines `log_format mkt_access`, which omits `$remote_addr` and every other
address variable by the same 2026-08-10 decision that took the address out of the Sentry events
(E12-S07), and **every** `access_log` directive in the repo names it — all eight server blocks, not
the three vhosts, because a block that declares none inherits the stock http-level one and that is
`combined`, whose first field is the address. Adding an unnamed `access_log`, or a server block with
none at all, is therefore a silent regression rather than a missing line, and the suite fails on both.

⚠️ **The same format names no `$request` and no `$http_referer` either, and both omissions are
controls.** Four mailed links carry `:email/:hash` in the path — `/check/verify-email-user/`,
`/check/verify-email/`, `/reset-password/` and `/x/reset/` — so the raw request line is an account
address next to a live one-time hash (E12-S16). The request line is rebuilt from `$request_method`,
`$request_uri` through a `map`, and `$server_protocol`; the referer goes through a second map, because
`strict-origin-when-cross-origin` on the customer surface sends the full URL on same-origin requests
and the reset page's own calls would carry the link. ⚠️ **Only two of the four have a `location` block
of their own** — the other two are an SSR route and a SPA fallback — which is why the redaction is at
http level on the logged value and must stay there. Restoring `$request` for readability puts every
one of them back.

⚠️ **All four 443 blocks demand a client certificate, so the origin answers Cloudflare and nobody
else.** `snippets/origin-pull.conf` (E12-S15) is included at server level four times, not three — the
`www` redirect is a server block of its own, and a hostname without the include goes on answering anyone
who knows the origin address. Two consequences to hold on to: a monitoring probe or a `curl --resolve`
aimed straight at the origin gets `400 Bad Request — No required SSL certificate was sent`, and that is
the control working, not a fault; and the CA is referenced by path and never committed, so the test
container generates a throwaway one of its own. The Cloudflare side is **not yet enabled**, so the
staged `optional` → `on` rollout in `README.md` §Authenticated Origin Pulls is the only safe way to put
this on a host — reloading straight to `on` first is an outage on all three hostnames.

⚠️ **The error log is a different file, and its control is `logrotate.d/nginx` rather than a format.**
nginx builds each error entry with a hard-coded `client: <address>` prefix; only the destination and the
level are configurable, so no `log_format` reaches it and the three vhosts running it at `warn` do write
addresses there. Measured (`docs/report/log-sink-inventory.md` §6.1): severity is not the discriminator
— five of five request-scoped entries at `warn` carry the prefix, none of the 162 process-lifecycle ones
do — so **every line in a per-host error log is a line with an address in it**. The decision of
2026-08-11 is that they stay and that lifetime is the control: 14 daily rotations, `shred` on removal,
shipped by this repo (E12-S19) and installed **over** `/etc/logrotate.d/nginx`, because two files
globbing `/var/log/nginx/*.log` make logrotate skip one of them whole. Three things to hold on to
before editing that file: `rotate 14` with `daily` *is* the retention and the privacy notice states it
(E12-S25), so the two change together; `shred` needs GNU coreutils and fails open to `unlink` on a
busybox host, printing to cron mail and exiting 0; and the level stays `warn` in both directions, since
`info` adds two more address-bearing classes (§6.3) and anything stricter drops the failures the file
exists for.

- **Ports live in the service `env` templates, not here.** `conf.d/10-upstreams.conf` mirrors
  `grep -m1 '^PORT=' <repo>/env`. Move a port in the template first and here second.
- **`mkt_logout` on 4030 answering all three vhosts is not a copy-paste slip** — one service serves
  every tier (ADR-005), because its resolver deletes Redis keys by token content.
- **Every zone keys on `$binary_remote_addr`, and `conf.d/06-real-ip.conf` is what makes that a
  visitor's address.** The zone is proxied by Cloudflare, so without that file the variable is an edge
  address and each zone buckets a whole point of presence. It reads `CF-Connecting-IP`, never
  `X-Forwarded-For` — Cloudflare *appends* to a caller-supplied one, so its first entry is whatever the
  caller wrote, and trusting it hands every attacker a private bucket. ⚠️ **The trusted range list
  expires silently**: Cloudflare adds ranges, a stale list stops trusting a point of presence, and the
  only symptom is `$remote_addr` reverting to an edge address for those visitors. Regeneration command
  at the top of the file; review trigger is risk R43 in the parent workspace.
- **No `/api/register` location and no `mkt_register` zone, deliberately.** The app has no such route:
  registration is a GraphQL mutation on the one endpoint the vhost already meters. The limit is split,
  and each half sits where it can be enforced — **per client address here**, in the zones above, and
  **per email address in `guardPublicWrite`** (`marketplace-dev-public-resource`), which is the half no
  zone can express, since a zone keyed on `$binary_remote_addr` never sees the inbox a distributed
  source is mail-bombing. The services kept a per-address counter of their own until E12-S10 and it was
  a fiction — `app.proxy` is off, so the address they see is this proxy's and the counter metered the
  whole platform at once. Do not add a location, and do not expect the backend to bucket callers.
- **The suite proves configuration, never application behaviour.** All eleven upstreams are canned
  nginx stubs, and the four authorization stubs mint cookies exactly the way koa-utils does today
  (`secure: false`, no `SameSite`) — so anything the suite reports as flagged was flagged by nginx.
- **Minimum nginx 1.25.1** for the `http2 on` directive form, **1.19.3** for `proxy_cookie_flags`.
  Debian 13 ships 1.26+, and the container default `nginx:stable-alpine` is well past both.

## Gates

Three hooks. `commit-msg` is byte-identical across all sixteen repos; the other two are shaped like no
other repo's (ADR-030), because this one has no `package.json`.

**`.githooks/commit-msg`** enforces `<type>(<scope>): <subject>` — `feat|fix|chore|docs|refactor|ci`,
optionally prefixed `🤖 ` — with a 150-char subject and a body of at most 10 lines, wrapped at 150.
`Merge `/`Revert ` subjects skip the format check. ⚠️ **`Co-Authored-By` is banned anywhere in the
message and that check runs first, so even a merge commit is rejected for it.** Every check reads
`CLEAN`, never `$1`: git has not stripped the file yet, so the raw one still holds the `#` template and,
under `commit.verbose` / `git commit -v`, the whole staged diff below the `>8` scissors line. **Any new
check must read `CLEAN` too** — scanning the raw file rejects good messages for what the diff contains.
Blank lines, `Key: value` trailers and whitespace-free lines (URLs, identifiers) are further exempt from
the body limits.

**`.githooks/pre-push`** runs `test/run.sh` and blocks the push on any failure. It also blocks rather
than skips when `test/run.sh` is missing or not executable, when the container engine is absent or its
daemon unreachable, or when the test image is not already present locally. There is no bypass variable.

**`.githooks/pre-commit`** is the platform's secret guard — check 0 plus the two staged-secret scans —
and stops there, with no gate after it. ⚠️ **Its pattern variables diverge from the other fifteen
copies', deliberately** — this repo has no `package.json`, no env file and no JavaScript:

- `SECRET_VALUE` keeps three branches — inline private key, MongoDB URL, credential URL. The npm,
  `.npmrc`, `KEYGRIP_KEY_*` and service-env-key branches are dropped.
- `SECRET_PATH` drops `.envrc`, `.npmrc`, `.yarnrc`, `.pgpass`, `credentials.json`,
  `service-account*.json` and `jks`, and **adds `key`** — `ssl_certificate_key` names a `.key` file at
  least as often as a `.pem` one, and this is the one repo where that file would plausibly be created.
- `SKIP_PATH` is gone. It allowlisted vendored semgrep / gitleaks / trufflehog rulesets, none of which
  exist here, so the staged list is scanned whole.

Everything else in the body is still shared, so **a fix to any other variant is merged in by hand here,
never copied over wholesale.**

⚠️ **The hook is not self-arming.** This repo has no `package.json`, so no `prepare` script sets
`core.hooksPath`. Once, by hand, after a fresh clone:

```bash
git config core.hooksPath .githooks
```

- No lint, coverage, mutation or Qodana gate exists here and none is expected — there is no JavaScript
  for them to run against.
- Never commit on `main`. Branch first: `git switch -c <type>/<slug>`. Merging is the user's call, and
  this repo is push-on-request like every repo except `marketplace-common`.
