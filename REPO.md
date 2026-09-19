# marketplace-nginx — reference

This file holds what `CLAUDE.md` used to carry before it was slimmed down: rationale, long mechanics,
and reference detail that an agent looks up rather than needs on every task. `CLAUDE.md` still carries
every hard rule and trap, condensed to one or two sentences with a pointer back here for the rest.
`README.md` already covers most of the nginx-specific traps at length (§Things that are easy to get
wrong) and the test suite in full (§Testing it, before it reaches a host); this file adds only what
neither of those already says.

## Running the suite — container mechanics

A container engine is a hard prerequisite. The repo mounts read-only at `/src`, the container is
`--rm`, nothing is installed on the host and nothing is written back into the repo. `run.sh` `exec`s
the engine, so the suite's exit code *is* `run.sh`'s exit code.

Read the **first** failure. `nginx -t` runs as a hard gate before anything else, and the behavioural
sections then keep going after a failure, so one bad directive prints dozens of downstream ones.

## Rate-limit zones — rotation must never share a zone with login

`mkt_refresh`, `mkt_owner_refresh` and `mkt_admin_refresh` (10r/m, burst 20) exist because rotation and
login used to share a zone, and putting them back together breaks two things at once: a token flood
spends the login burst and holds the whole address to 1r/m, and rotation is timer-driven, so an office
of fifty sessions rotating twice an hour is ~1.7/min sustained and trips a login-sized ceiling with no
attacker present. The suite asserts the separation behaviourally in both directions.

## Cache safety — never add `proxy_ignore_headers Set-Cookie`

nginx's default refusal to cache a response carrying `Set-Cookie` is load-bearing on the customer
vhost, on top of the `$mkt_user_no_cache` map — and that map only works while the `refresh_token`
cookie stays root-path-scoped, so narrowing its path in koa-utils would serve one logged-in customer's
HTML to everybody.

## The `commit-msg` hook — format and internals

`.githooks/commit-msg` enforces `<type>(<scope>): <subject>` — `feat|fix|chore|docs|refactor|ci`,
optionally prefixed `🤖 ` — with a 150-char subject and a body of at most 10 lines, wrapped at 150.
`Merge `/`Revert ` subjects skip the format check. Every check reads `CLEAN`, never `$1`: git has not
stripped the file yet, so the raw one still holds the `#` template and, under `commit.verbose` /
`git commit -v`, the whole staged diff below the `>8` scissors line. **Any new check must read `CLEAN`
too** — scanning the raw file rejects good messages for what the diff contains. Blank lines,
`Key: value` trailers and whitespace-free lines (URLs, identifiers) are further exempt from the body
limits.

## The `pre-commit` hook — why its patterns diverge from the other fifteen repos

`.githooks/pre-commit` is the platform's secret guard — check 0 plus the two staged-secret scans — and
stops there, with no gate after it. Its pattern variables diverge from the other fifteen copies',
deliberately, because this repo has no `package.json`, no env file and no JavaScript:

- `SECRET_VALUE` keeps three branches — inline private key, MongoDB URL, credential URL. The npm,
	`.npmrc`, `KEYGRIP_KEY_*` and service-env-key branches are dropped.
- `SECRET_PATH` drops `.envrc`, `.npmrc`, `.yarnrc`, `.pgpass`, `credentials.json`,
	`service-account*.json` and `jks`, and **adds `key`** — `ssl_certificate_key` names a `.key` file at
	least as often as a `.pem` one, and this is the one repo where that file would plausibly be created.
- `SKIP_PATH` is gone. It allowlisted vendored semgrep / gitleaks / trufflehog rulesets, none of which
	exist here, so the staged list is scanned whole.

Everything else in the hook body is still shared, so **a fix to any other variant is merged in by hand
here, never copied over wholesale.**

## Ports mirror the service `env` templates

Ports live in the service `env` templates, not here. `conf.d/10-upstreams.conf` mirrors
`grep -m1 '^PORT=' <repo>/env`. Move a port in the template first and here second.
