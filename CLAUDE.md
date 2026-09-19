# marketplace-nginx

The platform edge: one nginx, three vhosts, TLS terminating here and nowhere else, in front of the
eleven loopback processes. The only way to execute any of it is the throwaway container in `test/`.

**Read parent first** — [`../CLAUDE.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/CLAUDE.md)

## Where to read next

| Need | File |
|---|---|
| what every file holds, the host → path → service → port matrix, install, env assumptions | [`README.md`](./README.md) |
| the suite, its assertion groups, and the commands to run it | [`README.md`](./README.md) §Testing it, before it reaches a host |
| every nginx trap written out at length | [`README.md`](./README.md) §Things that are easy to get wrong |
| the register-endpoint and `/logout` (ADR-005) reasoning | [`README.md`](./README.md) §Testing it, before it reaches a host and §Which host proxies what |
| container mechanics, the two traps README doesn't carry, and hook internals | [`REPO.md`](./REPO.md) |
| what is deliberately not built here | [`README.md`](./README.md) §Known gaps |
| why the `Secure` flag is rewritten at the edge at all | [`README.md`](./README.md) §⚠️ The `Secure` cookie flag lives here |
| why the edge is a repo of its own, and the port table | [`../docs/architecture.md`](https://github.com/Axiumine/fullstack-marketplace-blueprint/blob/main/docs/architecture.md) §nginx |

## Hard rules and traps

⚠️ **`add_header` does not merge across levels.** A location setting even one drops the whole inherited
security-header set — re-include the vhost's snippet in every location that adds a header.

⚠️ **Both CSP lines must stay on one physical line.** A `\` line-continuation inside a quoted string
embeds a literal LF and nginx drops that header silently while the rest of the file keeps working.

⚠️ **`proxy_cookie_flags` in `snippets/proxy-backend.conf` is the only thing that sets `Secure`** on the
session cookie — koa-utils ships `secure: false` on purpose. Include it once per vhost at server level;
it is inherited only when no lower level declares its own.

⚠️ **A `limit_req_zone` name *is* the counter, and rotation must never share one with login.** Two
locations naming one zone share a single budget per address. Full math for why rotation and login split
zones is in [`REPO.md`](./REPO.md) §Rate-limit zones.

⚠️ **Never add `proxy_ignore_headers Set-Cookie`.** nginx's default cache refusal on a `Set-Cookie`
response is load-bearing for the customer vhost's cache bypass — detail in [`REPO.md`](./REPO.md)
§Cache safety.

⚠️ **The cache bypass reads two variables and only one is about the visitor.** `$mkt_credential_uri`
in `conf.d/30-cache.conf` must keep matching the same four mailed-link prefixes the logging maps
redact, or a link stops being either logged safely or cached safely — full detail in
[`README.md`](./README.md) §Things that are easy to get wrong.

⚠️ **`__CSP_NONCE__` is an application contract with `marketplace-user`'s SSR** — it must emit that
literal placeholder, never a real nonce, and nginx substitutes it via `sub_filter`. `location /` must
keep `proxy_set_header Accept-Encoding "";`, since `sub_filter` cannot rewrite a compressed body. Break
either half and the page loads but never hydrates, with nothing in the console.

⚠️ **The access-log format names no client address and no `$request`/`$http_referer`** — every
`access_log` directive in the repo must name it explicitly; a block declaring none inherits the stock
`combined` format instead, which is an address-bearing regression.

⚠️ **All four 443 blocks require a client certificate via `snippets/origin-pull.conf`.** A hostname
missing the include answers anyone who knows the origin address, not just Cloudflare.

⚠️ **The error log is a separate mechanism from the access-log format.** nginx hard-codes a client
address into it, and severity is not the discriminator: 5 of 5 request-scoped entries at `warn` carry
it, 0 of 162 process-lifecycle ones do (`docs/report/log-sink-inventory.md` §6.1, §6.3) — so every line
in a per-host error log has one. Only `logrotate.d/nginx`'s 14-day retention + `shred` controls its
lifetime.

⚠️ **`conf.d/06-real-ip.conf`'s Cloudflare IP list expires silently** — a stale list reverts
`$remote_addr` to an edge address with no error. Regeneration command at the top of the file; review
trigger is risk R43 in the parent workspace.

## Gates

Three hooks in `.githooks/`, shaped unlike any other repo's because this repo has no `package.json`
(ADR-030) — full mechanics of the `commit-msg` and `pre-commit` internals below are in
[`REPO.md`](./REPO.md).

⚠️ **`Co-Authored-By` is banned anywhere in a commit message** — `commit-msg` checks it first, so even a
merge commit is rejected for carrying one.

⚠️ **`pre-push` runs `test/run.sh` and blocks on any failure**, including a missing container engine or
test image. There is no bypass variable.

⚠️ **`pre-commit`'s secret-guard patterns diverge from the other fifteen repos' copies, deliberately**
(no `package.json`, no env file, no JS in this repo) — merge a fix in by hand here, never copy the file
over wholesale.

⚠️ **No hook is self-arming.** `core.hooksPath` is local config and no `prepare` script sets it here —
run once, by hand, after a fresh clone:
```bash
git config core.hooksPath .githooks
```

No lint, coverage or mutation gate exists here — there is no JavaScript for one to run against.

⚠️ **Never commit on `main`.** Branch first: `git switch -c <type>/<slug>`. This repo is
push-on-request, like every repo except `marketplace-common`.
