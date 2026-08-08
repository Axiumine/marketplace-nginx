#!/bin/sh
# Runs INSIDE the container. Do not run this on a host — it writes to /etc/nginx and starts a
# server. `nginx/test/run.sh` is the entry point.
#
# Two halves:
#   1. `nginx -t` against the real configuration, with throwaway certificates so the
#      ssl_certificate lines resolve. Syntax only, but that is the half that catches a typo
#      before it reaches a host where a failed reload is an outage.
#   2. Behaviour. nginx is started for real against stand-in backends and the assertions below
#      check what actually comes out of the socket. This is the half that caught the
#      Content-Security-Policy header being silently dropped — `nginx -t` was perfectly happy
#      with a value that no client ever received.

set -eu

# --------------------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------------------
apk add --no-cache openssl curl >/dev/null 2>&1

HOSTS='marketplace-domain.com shopowner.marketplace-domain.com admin.marketplace-domain.com'

for h in $HOSTS; do
	mkdir -p "/etc/letsencrypt/live/$h"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
		-keyout "/etc/letsencrypt/live/$h/privkey.pem" \
		-out    "/etc/letsencrypt/live/$h/fullchain.pem" \
		-subj "/CN=$h" >/dev/null 2>&1
done

mkdir -p /etc/nginx/snippets /etc/nginx/sites-enabled
cp /src/conf.d/*.conf          /etc/nginx/conf.d/
cp /src/snippets/*.conf        /etc/nginx/snippets/
cp /src/sites-available/*.conf /etc/nginx/sites-enabled/

# The stock image ships a default_server on :80 that collides with conf.d/40-tls.conf.
rm -f /etc/nginx/conf.d/default.conf

# The image symlinks the stock log files to stdout/stderr, which is right for a container and
# wrong for a test harness: a few hundred access-log lines bury the one FAIL you are looking
# for. Real files instead; the suite prints what matters.
rm -f /var/log/nginx/access.log /var/log/nginx/error.log
: >/var/log/nginx/access.log
: >/var/log/nginx/error.log

# The stock nginx.conf includes conf.d only. A real host includes sites-enabled as well; add the
# same glob here so the vhosts under test are actually loaded.
grep -q 'sites-enabled' /etc/nginx/nginx.conf ||
	sed -i 's#include /etc/nginx/conf.d/\*.conf;#include /etc/nginx/conf.d/*.conf;\n    include /etc/nginx/sites-enabled/*.conf;#' /etc/nginx/nginx.conf

# Paths the configuration expects to exist on a deployed host.
mkdir -p /var/cache/nginx/marketplace-user /var/www/acme \
	/srv/marketplace-user/dist/client/assets /srv/marketplace-user/dist/client/fonts \
	/srv/marketplace-user/tiles \
	/srv/marketplace-admin/dist/assets /srv/marketplace-shopowner/dist/assets

printf '<!doctype html><title>customer</title>\n'  >/srv/marketplace-user/dist/client/index.html
printf '<!doctype html><title>admin</title>\n'     >/srv/marketplace-admin/dist/index.html
printf '<!doctype html><title>shopowner</title>\n' >/srv/marketplace-shopowner/dist/index.html

# Assets are the compression control: they must be over `gzip_min_length 1024` so that "this
# response IS gzipped" is a meaningful comparison against the authorization endpoints, where
# compression is deliberately off.
pad() { i=0; while [ $i -lt 60 ]; do printf 'padding-so-the-body-clears-gzip-min-length-1024-bytes\n'; i=$((i + 1)); done; }
{ printf 'console.log(1)\n'; pad; } >/srv/marketplace-user/dist/client/assets/app.js
printf 'woff2\n'          >/srv/marketplace-user/dist/client/fonts/x.woff2
printf 'pmtiles\n'        >/srv/marketplace-user/tiles/x.pmtiles
for d in admin shopowner; do
	{ printf 'console.log(1)\n'; pad; } >"/srv/marketplace-$d/dist/assets/app.js"
	printf '{"version":3}\n'            >"/srv/marketplace-$d/dist/assets/app.js.map"
done
# `root /var/www/acme` appends the whole URI, so the token lands where certbot's webroot plugin
# puts it: `certbot --webroot -w /var/www/acme` writes exactly this path.
mkdir -p /var/www/acme/.well-known/acme-challenge
printf 'acme-token-body\n' >/var/www/acme/.well-known/acme-challenge/probe-token

# --------------------------------------------------------------------------------------
# 1. Syntax — hard gate. Nothing below runs if the configuration will not load.
# --------------------------------------------------------------------------------------
echo '==================================================================='
nginx -v 2>&1
echo '==================================================================='
# ⚠️ Run it, then test $?. `nginx -t | sed` would report sed's exit status, which is 0 whatever
# nginx thought — the gate would print PASS over the top of an [emerg].
nginx -t >/tmp/nginx-t.out 2>&1
_t=$?
sed 's/^/  /' /tmp/nginx-t.out
if [ "$_t" -eq 0 ]; then
	echo 'PASS  nginx -t'
else
	echo 'FAIL  nginx -t — configuration does not load. Nothing else was run.'
	exit 1
fi
echo

# The `ssl_stapling ignored, issuer certificate not found` warnings above are expected: the
# certificates are self-signed here and have no issuer to fetch an OCSP response from.

# --------------------------------------------------------------------------------------
# 2. Behaviour
# --------------------------------------------------------------------------------------
cp /src/test/fake-backends.conf /etc/nginx/conf.d/99-fake-backends.conf
nginx -t >/tmp/nginx-t2.out 2>&1 || {
	echo 'FAIL  fake backends broke the configuration'
	sed 's/^/  /' /tmp/nginx-t2.out
	exit 1
}
nginx
sleep 1

set +e   # assertions report, they do not abort

FAILED=0
RESOLVE="--resolve marketplace-domain.com:443:127.0.0.1
--resolve www.marketplace-domain.com:443:127.0.0.1
--resolve shopowner.marketplace-domain.com:443:127.0.0.1
--resolve admin.marketplace-domain.com:443:127.0.0.1"
# shellcheck disable=SC2086
RESOLVE=$(echo $RESOLVE)

HDR=/tmp/probe.hdr
BODY=/tmp/probe.body

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=$((FAILED + 1)); }

# probe METHOD HOST PATH [extra curl args…] — one request, many assertions read the result.
# Keeping it to one request per endpoint matters: the operator login sits behind a 10r/m zone
# and a second courtesy request would spend the burst the rate-limit test needs.
probe() {
	_m=$1
	_h=$2
	_p=$3
	shift 3
	# shellcheck disable=SC2086
	curl -sk -X "$_m" -o "$BODY" -D "$HDR".raw $RESOLVE "$@" "https://$_h$_p" 2>/dev/null
	tr -d '\r' <"$HDR".raw >"$HDR"
}

status()   { head -1 "$HDR" | awk '{print $2}'; }
header()   { grep -i "^$1:" "$HDR" | sed "s/^[^:]*: *//"; }

assert_status() { [ "$(status)" = "$1" ] && pass "$2 → $1" || fail "$2 → expected $1, got $(status)"; }
assert_body()   { grep -qF "$1" "$BODY" && pass "$2" || fail "$2 — body was: $(head -c 120 "$BODY")"; }
assert_no_body(){ grep -qF "$1" "$BODY" && fail "$2 — reached $1" || pass "$2"; }
assert_header() { header "$1" | grep -qiF "$2" && pass "$3" || fail "$3 — $1: $(header "$1" | head -1)"; }
assert_no_header() { [ -z "$(header "$1")" ] && pass "$2" || fail "$2 — $1 was present"; }

# Every Set-Cookie in the last probe must carry all three flags. Empty cookie list = failure:
# a silently absent Set-Cookie would otherwise pass a "none of them are unflagged" test.
assert_cookies_hardened() {
	_n=$(grep -ci '^set-cookie:' "$HDR")
	if [ "$_n" -eq 0 ]; then
		fail "$1 — no Set-Cookie at all"
		return
	fi
	_ok=$(grep -i '^set-cookie:' "$HDR" | grep -i 'Secure' | grep -i 'HttpOnly' | grep -ci 'SameSite=Strict')
	if [ "$_ok" = "$_n" ]; then
		pass "$1 — $_n cookie(s), all Secure + HttpOnly + SameSite=Strict"
	else
		fail "$1 — $((_n - _ok)) of $_n cookie(s) missing a flag:"
		grep -i '^set-cookie:' "$HDR" | sed 's/^/        /'
	fi
}

echo '==================================================================='
echo ' THE HEADLINE — Secure / HttpOnly / SameSite=Strict rewrite'
echo '==================================================================='
echo ' koa-utils sets `secure: false` with the comment "rewrite a true in Nginx !".'
echo ' The stand-in backends reproduce that exactly. Anything flagged below was flagged'
echo ' by snippets/proxy-backend.conf and by nothing else.'
echo

probe POST marketplace-domain.com /public-authorization
assert_cookies_hardened 'apex  login          /public-authorization'
assert_body 'BACKEND:mkt_public_authz' 'apex  login          → mkt_public_authz'

probe POST marketplace-domain.com /user-authenticated-authorization
assert_cookies_hardened 'apex  rotation       /user-authenticated-authorization'
assert_body 'BACKEND:mkt_user_authz' 'apex  rotation       → mkt_user_authz'

probe POST shopowner.marketplace-domain.com /public-authorization
assert_cookies_hardened 'owner login          /public-authorization'
assert_body 'BACKEND:mkt_public_authz' 'owner login          → mkt_public_authz'

probe POST shopowner.marketplace-domain.com /authenticated-authorization
assert_cookies_hardened 'owner rotation       /authenticated-authorization'
assert_body 'BACKEND:mkt_owner_authz' 'owner rotation       → mkt_owner_authz'

probe POST admin.marketplace-domain.com /public-authorization
assert_cookies_hardened 'admin login          /public-authorization'
assert_body 'BACKEND:mkt_public_authz' 'admin login          → mkt_public_authz'

probe POST admin.marketplace-domain.com /admin-authenticated-authorization
assert_cookies_hardened 'admin rotation       /admin-authenticated-authorization'
assert_body 'BACKEND:mkt_admin_authz' 'admin rotation       → mkt_admin_authz'

for h in $HOSTS; do
	probe POST "$h" /logout
	assert_cookies_hardened "logout, cleared cookie still flagged — $h"
done

echo
echo '==================================================================='
echo ' Path → service map. The path IS the service; no rewrite is involved.'
echo '==================================================================='
probe POST marketplace-domain.com /public-resource
assert_body 'BACKEND:mkt_public_resource' 'apex  /public-resource              → mkt_public_resource'
probe POST marketplace-domain.com /user-authenticated-resource
assert_body 'BACKEND:mkt_user_resource' 'apex  /user-authenticated-resource   → mkt_user_resource'
probe GET marketplace-domain.com /check/verify-email-user/a@b.c/deadbeef
assert_body 'BACKEND:mkt_public_resource' 'apex  /check/verify-email-user/     → mkt_public_resource'
# No `/api/` location exists any more, so this must fall through to the SSR catch-all like any
# other unknown path — not to a location of its own. See the comment in the apex vhost.
probe POST marketplace-domain.com /api/register
assert_body 'BACKEND:mkt_user_ssr' 'apex  /api/register  → mkt_user_ssr via the catch-all, no /api/ location'
probe GET marketplace-domain.com /health
assert_body 'BACKEND:mkt_user_ssr' 'apex  /health                       → mkt_user_ssr'
probe GET marketplace-domain.com /geocode/search
assert_body 'BACKEND:mkt_nominatim' 'apex  /geocode/                     → mkt_nominatim'
probe POST shopowner.marketplace-domain.com /authenticated-resource
assert_body 'BACKEND:mkt_owner_resource' 'owner /authenticated-resource        → mkt_owner_resource'
probe GET shopowner.marketplace-domain.com /check/verify-email/a@b.c/deadbeef
assert_body 'BACKEND:mkt_public_resource' 'owner /check/verify-email/          → mkt_public_resource'
probe POST admin.marketplace-domain.com /admin-authenticated-resource
assert_body 'BACKEND:mkt_admin_resource' 'admin /admin-authenticated-resource  → mkt_admin_resource'

echo
echo '==================================================================='
echo ' Tier isolation — a path belonging to another tier must not reach its service'
echo '==================================================================='
echo ' Asserted against the FOREIGN backend by name, not against a status code: a 403 from'
echo ' the wrong service and never reaching a service are the same number from outside.'
echo
probe POST admin.marketplace-domain.com /authenticated-resource
assert_no_body 'BACKEND:mkt_owner_resource' 'admin ⇏ ShopOwner resource'
probe POST admin.marketplace-domain.com /user-authenticated-resource
assert_no_body 'BACKEND:mkt_user_resource' 'admin ⇏ User resource'
probe POST shopowner.marketplace-domain.com /admin-authenticated-resource
assert_no_body 'BACKEND:mkt_admin_resource' 'owner ⇏ Admin resource'
probe POST shopowner.marketplace-domain.com /user-authenticated-resource
assert_no_body 'BACKEND:mkt_user_resource' 'owner ⇏ User resource'
probe GET shopowner.marketplace-domain.com /check/verify-email-user/a@b.c/deadbeef
assert_no_body 'BACKEND:mkt_public_resource' 'owner ⇏ customer verification route'
probe POST marketplace-domain.com /admin-authenticated-resource
assert_no_body 'BACKEND:mkt_admin_resource' 'apex  ⇏ Admin resource'
probe POST marketplace-domain.com /authenticated-resource
assert_no_body 'BACKEND:mkt_owner_resource' 'apex  ⇏ ShopOwner resource'
probe GET marketplace-domain.com /check/verify-email/a@b.c/deadbeef
assert_no_body 'BACKEND:mkt_public_resource' 'apex  ⇏ shop-owner verification route'

echo
echo '==================================================================='
echo ' Proxy headers — TLS terminates here, so upstream only knows what we tell it'
echo '==================================================================='
probe GET marketplace-domain.com /health
assert_body 'proto=https' 'X-Forwarded-Proto reaches upstream as https'
assert_body 'host=marketplace-domain.com' 'Host survives the proxy hop'

# The nonce in the delivered HTML must equal the nonce in the header of the SAME response, on a
# cache MISS and on a cache HIT alike. The HIT is the case that matters: it is where handing the
# renderer a per-request nonce breaks, because the cached body then carries the nonce of an
# earlier visitor's request while the header carries this visitor's.
assert_nonce_agrees() {
	_up=$(sed -n 's/.*nonce=\([0-9a-zA-Z_]*\).*/\1/p' "$BODY")
	_csp=$(header content-security-policy | sed -n "s/.*'nonce-\([0-9a-f]*\)'.*/\1/p")
	_cache=$(header x-cache-status)
	if [ -n "$_up" ] && [ "$_up" = "$_csp" ]; then
		pass "CSP nonce agrees with the header on a $_cache ($_up)"
	else
		fail "CSP nonce on a $_cache — body carries '$_up', header carries '$_csp'"
	fi
}
probe GET marketplace-domain.com /nonce-probe
assert_nonce_agrees
probe GET marketplace-domain.com /nonce-probe
assert_nonce_agrees

echo
echo '==================================================================='
echo ' Security headers. add_header does NOT merge — every location that sets one'
echo ' of its own must re-include the snippet or its responses ship bare.'
echo '==================================================================='
check_headers() {   # HOST PATH LABEL PRIVATE?
	probe GET "$1" "$2"
	assert_header content-security-policy   "default-src 'self'" "$3 — CSP present"
	assert_header content-security-policy   'upgrade-insecure-requests' "$3 — CSP complete to the last directive"
	assert_header strict-transport-security 'max-age=63072000'   "$3 — HSTS"
	assert_header x-content-type-options    'nosniff'            "$3 — nosniff"
	assert_header content-security-policy   "frame-ancestors 'none'" "$3 — frame-ancestors"
	# A literal newline in the value is what silently dropped this header before: nginx does not
	# do backslash line-continuation inside a quoted string, so `"\` + newline embeds an LF and
	# the whole header is discarded. One CSP line in the dump means one header, unfolded.
	_n=$(grep -ci '^content-security-policy:' "$HDR")
	[ "$_n" = 1 ] && pass "$3 — CSP is a single unfolded header" || fail "$3 — CSP appears $_n times (folded value?)"
	if [ "${4:-}" = private ]; then
		header content-security-policy | grep -q "nonce-" &&
			fail "$3 — panel CSP must not carry a nonce" ||
			pass "$3 — panel CSP carries no nonce (no inline script to sign)"
		assert_header referrer-policy 'no-referrer' "$3 — Referrer-Policy"
		assert_header x-robots-tag    'noindex'     "$3 — X-Robots-Tag"
	else
		header content-security-policy | grep -qE "'nonce-[0-9a-f]{32}'" &&
			pass "$3 — customer CSP carries a 32-hex nonce" ||
			fail "$3 — customer CSP nonce missing or malformed"
		assert_header referrer-policy 'strict-origin-when-cross-origin' "$3 — Referrer-Policy"
	fi
}

check_headers marketplace-domain.com            /some-page        'apex  /'
check_headers marketplace-domain.com            /assets/app.js    'apex  /assets/'
check_headers marketplace-domain.com            /fonts/x.woff2    'apex  /fonts/'
check_headers marketplace-domain.com            /tiles/x.pmtiles  'apex  /tiles/'
check_headers marketplace-domain.com            /geocode/search   'apex  /geocode/'
check_headers shopowner.marketplace-domain.com  /companies        'owner SPA'      private
check_headers shopowner.marketplace-domain.com  /assets/app.js    'owner /assets/' private
check_headers admin.marketplace-domain.com      /companies        'admin SPA'      private
check_headers admin.marketplace-domain.com      /assets/app.js    'admin /assets/' private

# X-Frame-Options is deliberately absent — frame-ancestors replaces it.
probe GET admin.marketplace-domain.com /companies
assert_no_header x-frame-options 'admin — no X-Frame-Options (frame-ancestors replaces it)'

echo
echo '==================================================================='
echo ' Server-wide hardening'
echo '==================================================================='
for h in $HOSTS; do
	probe GET "$h" /
	_srv=$(header server)
	case "$_srv" in
		*[0-9]*) fail "$h — Server header leaks a version: $_srv" ;;
		*)       pass "$h — Server: $_srv (no version, server_tokens off)" ;;
	esac
done

# Compression is on everywhere except the endpoints whose body carries a token. Both halves are
# asserted: an "is not gzipped" check alone would pass on a host where gzip was off entirely.
probe GET admin.marketplace-domain.com /assets/app.js -H 'Accept-Encoding: gzip'
assert_header content-encoding 'gzip' 'admin /assets/ IS compressed (the control)'

probe POST admin.marketplace-domain.com /public-authorization -H 'Accept-Encoding: gzip'
if [ -z "$(header content-encoding)" ]; then
	pass 'admin /public-authorization is NOT compressed (token in the body — BREACH shape)'
else
	fail "admin /public-authorization was compressed: $(header content-encoding)"
fi
_len=$(header content-length)
if [ -n "$_len" ] && [ "$_len" -gt 1024 ]; then
	pass "the uncompressed check is meaningful — body is ${_len}b, over gzip_min_length"
else
	fail "body is only ${_len:-?}b; under gzip_min_length, so the check above proves nothing"
fi

echo
echo '==================================================================='
echo ' SSR cache — anonymous visitors share it, a session must never touch it'
echo '==================================================================='
probe GET marketplace-domain.com /cache-probe-a
assert_header x-cache-status 'MISS' 'first anonymous request  → MISS'
probe GET marketplace-domain.com /cache-probe-a
assert_header x-cache-status 'HIT'  'second anonymous request → HIT'
probe GET marketplace-domain.com /cache-probe-b -H 'Cookie: refresh_token=abc123'
assert_header x-cache-status 'BYPASS' 'request with a session   → BYPASS (skips the lookup)'
probe GET marketplace-domain.com /cache-probe-b
assert_header x-cache-status 'MISS' 'the session response was never stored (proxy_no_cache)'

echo
echo '==================================================================='
echo ' TLS termination and redirects'
echo '==================================================================='
for h in marketplace-domain.com www.marketplace-domain.com shopowner.marketplace-domain.com admin.marketplace-domain.com; do
	curl -s -o /dev/null -D "$HDR".raw --resolve "$h:80:127.0.0.1" "http://$h/deep/path?q=1" 2>/dev/null
	tr -d '\r' <"$HDR".raw >"$HDR"
	_loc=$(header location)
	if [ "$(status)" = 308 ] && [ "${_loc#https://}" != "$_loc" ]; then
		pass ":80 $h → 308 $_loc"
	else
		fail ":80 $h → expected 308 to https, got $(status) $_loc"
	fi
done

probe GET www.marketplace-domain.com /deep/path
if [ "$(status)" = 308 ] && [ "$(header location)" = 'https://marketplace-domain.com/deep/path' ]; then
	pass ':443 www → 308 apex, over TLS'
else
	fail ":443 www → expected 308 to the apex, got $(status) $(header location)"
fi

for h in $HOSTS; do
	curl -s -o "$BODY" -D "$HDR".raw --resolve "$h:80:127.0.0.1" \
		"http://$h/.well-known/acme-challenge/probe-token" 2>/dev/null
	tr -d '\r' <"$HDR".raw >"$HDR"
	if [ "$(status)" = 200 ] && grep -q acme-token-body "$BODY"; then
		pass "ACME challenge served on :80 without a redirect — $h"
	else
		fail "ACME challenge on :80 → $(status) — certbot renewal would fail for $h"
	fi
done

_code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve nothing.marketplace-domain.com:443:127.0.0.1 \
	https://nothing.marketplace-domain.com/ 2>/dev/null)
[ "$_code" = 000 ] && pass 'unknown Host → handshake refused by the default server' ||
	fail "unknown Host → answered with $_code; ssl_reject_handshake is not doing its job"

echo
echo '==================================================================='
echo ' Panel hardening'
echo '==================================================================='
for h in shopowner.marketplace-domain.com admin.marketplace-domain.com; do
	probe GET "$h" /assets/app.js.map
	assert_status 403 "$h source map denied"
	probe GET "$h" /robots.txt
	assert_body 'Disallow: /' "$h robots.txt disallows everything"
	probe GET "$h" /nonexistent-route
	assert_status 200 "$h SPA fallback serves index.html"
	assert_header cache-control 'no-store' "$h index.html is no-store"
done
for h in $HOSTS; do
	probe GET "$h" /.env
	assert_status 403 "$h dotfiles denied"
done

# --------------------------------------------------------------------------------------
# Rate limiting. Restart first: limit_req counters live in shared memory that survives a
# reload, and the assertions above have already spent part of the operator login's budget.
# --------------------------------------------------------------------------------------
echo
echo '==================================================================='
echo ' Rate limiting (fresh counters — nginx restarted)'
echo '==================================================================='
nginx -s stop 2>/dev/null
sleep 1
nginx
sleep 1

burst_probe() {   # HOST PATH COUNT LABEL
	_codes=''
	_i=0
	while [ "$_i" -lt "$3" ]; do
		# shellcheck disable=SC2086
		_codes="$_codes $(curl -sk -o /dev/null -w '%{http_code}' -X POST $RESOLVE "https://$1$2" 2>/dev/null)"
		_i=$((_i + 1))
	done
	echo "      $4:$_codes"
	case "$_codes" in
		*429*) pass "$4 — limiter engages" ;;
		*)     fail "$4 — no 429 in $3 requests; the zone is not limiting" ;;
	esac
	case "$_codes" in
		*200*) pass "$4 — the burst is let through first" ;;
		*)     fail "$4 — nothing succeeded; the burst is too small to log in with" ;;
	esac
}

burst_probe admin.marketplace-domain.com     /public-authorization 12 'operator login  (mkt_admin_auth 10r/m)'
burst_probe shopowner.marketplace-domain.com /public-authorization 24 'shop-owner login (mkt_owner_auth 20r/m)'
# The customer surface's own login zone. The two probes above are on the panel hostnames and spend
# `mkt_owner_auth` / `mkt_admin_auth`; `mkt_auth` is a third, separate budget reached only through
# the apex — which is the whole point of giving the three logins zones of their own, since they all
# land on the same service (public-authorization, 4028).
burst_probe marketplace-domain.com           /public-authorization 24 'customer login  (mkt_auth 20r/m)'

# ⚠️ There is deliberately no registration burst test, because there is no `mkt_register` zone to
# test and no `/api/register` to aim one at. Registration is a GraphQL POST to /public-resource like
# every other public write, bounded at the edge by `mkt_public` and properly metered inside
# marketplace-dev-public-resource by `guardPublicWrite` — two Redis counters per hour, per IP *and*
# per email address. The per-email half is what actually stops a mail-bomb and no nginx zone keyed
# on $binary_remote_addr can express it. See the comments in 20-rate-limit.conf and the apex vhost.

echo
echo '==================================================================='
if [ "$FAILED" -eq 0 ]; then
	echo ' ALL CHECKS PASSED'
	echo '==================================================================='
	exit 0
fi
echo " $FAILED CHECK(S) FAILED"
echo '==================================================================='
exit 1
