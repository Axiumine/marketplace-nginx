# marketplace-nginx

The platform edge: one nginx, three vhosts, TLS terminating here and nowhere else, in front of the
eleven loopback processes. the one way to execute any of it is the throwaway container in `test/` or your local setup.

**Read parent first** — [`../CLAUDE.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/CLAUDE.md)

| Need | File |
|---|---|
| what every file holds, the host → path → service → port matrix, install, env assumptions | [`README.md`](./README.md) |
| the suite, its eleven assertion groups, and six real defects it caught | [`README.md`](./README.md) §Testing it, before it reaches a host |
| seven nginx traps written out at length | [`README.md`](./README.md) §Things that are easy to get wrong |
| what is deliberately not built here | [`README.md`](./README.md) §Known gaps |
| why the `Secure` flag is rewritten at the edge at all | [`README.md`](./README.md) §⚠️ The `Secure` cookie flag lives here |
| why the edge is a repo of its own, and the port table | [`../docs/architecture.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/docs/architecture.md) §nginx |

## Running it

```bash
./test/run.sh                                       # nginx -t, then 168 assertions in a container
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
that one header is dropped silently while every other `add_header` in the file still ships. A readable
multi-line version once shipped unexecuted in `marketplace-user/docs/nginx/` and nobody noticed.

⚠️ **`proxy_cookie_flags ~ secure httponly samesite=strict;` is the only thing on the platform that
sets `Secure` on the session cookie** — koa-utils ships `secure: false` with a comment saying to
rewrite it here. `snippets/proxy-backend.conf` must be included exactly once **per vhost at server
level**: `proxy_cookie_flags` is inherited only when the current level declares none of its own, so
re-including it inside a location works only by accident.

⚠️ **A rate-limit zone name *is* the counter.** Two locations naming one zone share a single budget per
address, across vhosts as well as within one. That is why the three login endpoints — all of them
proxying to the same backend on 4028 — carry three separate zones: `mkt_auth` (customer, 20r/m),
`mkt_owner_auth` (20r/m) and `mkt_admin_auth` (10r/m, high-privilege and few accounts). nginx cannot
see which GraphQL mutation the shared process is being asked to run, so the per-vhost hostname is the
only place those budgets can be told apart. Renaming a zone onto an existing name merges two budgets
with no error anywhere.

⚠️ **Never add `proxy_ignore_headers Set-Cookie`.** nginx's default refusal to cache a response
carrying `Set-Cookie` is load-bearing on the customer vhost, on top of the `$mkt_user_no_cache` map —
and that map only works while the `refresh_token` cookie stays root-path-scoped, so narrowing its path
in koa-utils would serve one logged-in customer's HTML to everybody.

⚠️ **The `__CSP_NONCE__` contract spans two repos.** The SSR renderer writes that literal placeholder
into its inline script tags and nginx substitutes the per-request `$csp_nonce` on the way out, so a
cached page never carries one visitor's nonce. `location /` therefore forces `Accept-Encoding ""` —
`sub_filter` cannot rewrite a compressed body. Break either half and the page loads but never
hydrates, with nothing in the console.

- **Ports live in the service `env` templates, not here.** `conf.d/10-upstreams.conf` mirrors
  `grep -m1 '^PORT=' <repo>/env`. Move a port in the template first and here second.
- **`mkt_logout` on 4030 answering all three vhosts is not a copy-paste slip** — one service serves
  every tier (ADR-005), because its resolver deletes Redis keys by token content.
- **Every zone keys on `$binary_remote_addr`.** Behind a CDN or a second proxy that becomes the proxy's
  own address and all visitors share one bucket, until `set_real_ip_from` plus a `$realip`-derived key
  are configured.
- **No `/api/register` location and no `mkt_register` zone, deliberately.** The old pair matched a
  route the app never had and counted nothing; the real limit is `guardPublicWrite` in
  `marketplace-dev-public-resource`, per-IP *and* per-email, which no nginx zone can express. The
  27-line comment where it used to live says so. Do not rebuild it.
- **The suite proves configuration, never application behaviour.** All eleven upstreams are canned
  nginx stubs, and the four authorization stubs mint cookies exactly the way koa-utils does today
  (`secure: false`, no `SameSite`) — so anything the suite reports as flagged was flagged by nginx.
- **Minimum nginx 1.25.1** for the `http2 on` directive form, **1.19.3** for `proxy_cookie_flags`.
  Debian 13 ships 1.26+, and the container default `nginx:stable-alpine` is well past both.

## Gates

Two hooks, neither shaped like any other repo's (ADR-030), because this one has no `package.json`.

**`.githooks/pre-push`** runs `test/run.sh` and blocks the push on any failure. It also blocks rather
than skips when `test/run.sh` is missing or not executable, when the container engine is absent or its
daemon unreachable, or when the test image is not already present locally. There is no bypass variable.

**`.githooks/pre-commit`** is the platform's secret guard — check 0 plus the two staged-secret scans —
and stops there, with no gate after it. ⚠️ **Its body is byte-identical to the other fifteen copies and
must stay that way**: a fix to any one of the six variants is copied to the other five, and only the
header comment above the body differs per repo.

⚠️ **The hook is not self-arming.** This repo has no `package.json`, so no `prepare` script sets
`core.hooksPath`. Once, by hand, after a fresh clone:

```bash
git config core.hooksPath .githooks
```

- No lint, coverage, mutation or Qodana gate exists here and none is expected — there is no JavaScript
  for them to run against.
- Never commit on `main`. Branch first: `git switch -c <type>/<slug>`. Merging is the user's call, and
  this repo is push-on-request like every repo except `marketplace-common`.
