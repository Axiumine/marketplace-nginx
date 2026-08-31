#!/bin/sh
# Runs INSIDE the container. Do not run this on a host — it writes to /etc/nginx and starts a
# server. `marketplace-nginx/test/run.sh` is the entry point.
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
# ⚠️ `coreutils` is not decoration next to `logrotate`. logrotate shreds a rotated file by handing
# its open descriptor to `shred … -`, and busybox's applet cannot open `-`: without GNU shred every
# removal falls back to `unlink` after printing an error, which is precisely the silent degradation
# the retention section at the end of this file exists to catch. Debian 13 ships GNU coreutils.
apk add --no-cache openssl curl logrotate coreutils >/dev/null 2>&1

HOSTS='marketplace-domain.com shopowner.marketplace-domain.com admin.marketplace-domain.com'

for h in $HOSTS; do
	mkdir -p "/etc/letsencrypt/live/$h"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
		-keyout "/etc/letsencrypt/live/$h/privkey.pem" \
		-out    "/etc/letsencrypt/live/$h/fullchain.pem" \
		-subj "/CN=$h" >/dev/null 2>&1
done

# Authenticated Origin Pulls. `snippets/origin-pull.conf` trusts a CA by path that is
# never committed, so the suite generates a throwaway one where the snippet expects it. Cloudflare's
# own key is not available to a test and never will be; what is testable is the property that
# matters — nginx refuses a caller without a certificate from that CA, and serves one with it.
mkdir -p /etc/nginx/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=marketplace origin pull test CA' \
	-keyout /tmp/origin-pull-ca.key -out /etc/nginx/certs/origin-pull-ca.pem >/dev/null 2>&1

issue_client() {   # NAME CA-CERT CA-KEY — a client certificate signed by that CA
	openssl req -new -newkey rsa:2048 -nodes -subj '/CN=cloudflare-origin-pull' \
		-keyout "/tmp/$1.key" -out "/tmp/$1.csr" >/dev/null 2>&1
	openssl x509 -req -in "/tmp/$1.csr" -CA "$2" -CAkey "$3" -CAcreateserial -days 1 -sha256 \
		-out "/tmp/$1.crt" >/dev/null 2>&1
}

issue_client cf-client /etc/nginx/certs/origin-pull-ca.pem /tmp/origin-pull-ca.key

# ⚠️ A second, unrelated CA. "Signed by somebody" must not be enough — that is the whole argument
# against Cloudflare's shared global origin-pull certificate, which every Cloudflare customer is
# handed. See README.md §Three configurations.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=rogue CA' \
	-keyout /tmp/rogue-ca.key -out /tmp/rogue-ca.crt >/dev/null 2>&1
issue_client rogue /tmp/rogue-ca.crt /tmp/rogue-ca.key

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

# ⚠️ Every https request in this suite presents Cloudflare's stand-in certificate, because
# `ssl_verify_client on` is what all four 443 blocks now do. The `:80` requests deliberately do
# not, which is what keeps proving that ACME renewal is untouched by it.
CLIENT='--cert /tmp/cf-client.crt --key /tmp/cf-client.key'

HDR=/tmp/probe.hdr
BODY=/tmp/probe.body

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=$((FAILED + 1)); }

# probe METHOD HOST PATH [extra curl args…] — one request, many assertions read the result.
# Keeping it to one request per endpoint matters: the admin login sits behind a 10r/m zone
# and a second courtesy request would spend the burst the rate-limit test needs.
probe() {
	_m=$1
	_h=$2
	_p=$3
	shift 3
	# shellcheck disable=SC2086
	curl -sk -X "$_m" -o "$BODY" -D "$HDR".raw $RESOLVE $CLIENT "$@" "https://$_h$_p" 2>/dev/null
	tr -d '\r' <"$HDR".raw >"$HDR"
}

status()   { head -1 "$HDR" | awk '{print $2}'; }
header()   { grep -i "^$1:" "$HDR" | sed "s/^[^:]*: *//"; }

assert_status() { [ "$(status)" = "$1" ] && pass "$2 → $1" || fail "$2 → expected $1, got $(status)"; }
assert_body()   { grep -qF "$1" "$BODY" && pass "$2" || fail "$2 — body was: $(head -c 120 "$BODY")"; }
assert_no_body(){ grep -qF "$1" "$BODY" && fail "$2 — reached $1" || pass "$2"; }
# Substring is the wrong test for a byte range: the requested slice is a substring of the whole
# archive too, so assert_body would pass against exactly the response a range test must catch.
assert_body_exact() { [ "$(cat "$BODY")" = "$1" ] && pass "$2" || fail "$2 — body was '$(head -c 120 "$BODY")', expected '$1'"; }
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
	# Turnstile is on all three login pages. Both directives are needed and for different reasons:
	# the API script is fetched from that origin, and the challenge itself renders in an iframe
	# served by it. Missing either shows an empty box and no console error worth reading, and the
	# form then submits with no token — which fails closed only where TURNSTILE_SECRET is set, so a
	# developer box never reveals it.
	assert_header content-security-policy 'frame-src https://challenges.cloudflare.com' "$3 — Turnstile in frame-src"
	if [ "${4:-}" = private ]; then
		assert_header content-security-policy "script-src 'self' https://challenges.cloudflare.com" \
			"$3 — Turnstile in script-src"
		header content-security-policy | grep -q "nonce-" &&
			fail "$3 — panel CSP must not carry a nonce" ||
			pass "$3 — panel CSP carries no nonce (no inline script to sign)"
		assert_header referrer-policy 'no-referrer' "$3 — Referrer-Policy"
		assert_header x-robots-tag    'noindex'     "$3 — X-Robots-Tag"
	else
		assert_header content-security-policy "'strict-dynamic' https://challenges.cloudflare.com" \
			"$3 — Turnstile in script-src"
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

# The mailed-link credential. Defined once and used by two sections — the cache must never store
# a URL carrying it (below) and the log must never record one (further down) —
# so the two cannot drift onto different probe values and each pass against the other's.
LINK_EMAIL='probe@example.invalid'
LINK_EMAIL_ENC='probe%40example.invalid'
LINK_HASH='LIVEONETIMEHASHPROBE0000'

echo
echo '  --- and never a URL that carries a mailed one-time credential ---'
# ⚠️ The cookie map cannot reach this case. `/reset-password/:email/:hash` has no `location` block
# — it is an SSR route served through `location /` — and whoever follows a reset link is anonymous
# by definition, so `$mkt_user_no_cache` is 0 for exactly the request that must never be stored.
# Without `$mkt_credential_uri` the address and the live hash become a cache key on disk, kept up
# to `inactive=24h`, in a directory nothing rotates and nothing shreds.
probe GET marketplace-domain.com "/reset-password/$LINK_EMAIL_ENC/$LINK_HASH"
assert_header x-cache-status 'BYPASS' 'anonymous reset link     → BYPASS (never becomes a cache key)'
probe GET marketplace-domain.com "/reset-password/$LINK_EMAIL_ENC/$LINK_HASH"
assert_header x-cache-status 'BYPASS' 'and on the second visit  → BYPASS, not a HIT off the first'

# The decoded form, and the shape koa-utils sends when nothing overrides its default `linkPath`.
# Both reach `location /` on the apex the same way the SSR route does.
probe GET marketplace-domain.com "/x/reset/$LINK_EMAIL/$LINK_HASH"
assert_header x-cache-status 'BYPASS' 'apex /x/reset/ decoded @ → BYPASS'

# The other direction. A bypass keyed on the URL is one bad regex away from bypassing everything,
# which turns the cache off in production with every assertion above still green.
probe GET marketplace-domain.com /cache-probe-c
assert_header x-cache-status 'MISS' 'an ordinary page is still cacheable → MISS'
probe GET marketplace-domain.com /cache-probe-c
assert_header x-cache-status 'HIT'  'and still served from the cache     → HIT'

echo
echo '==================================================================='
echo ' Map tiles — one PMTiles archive answered as byte ranges (NFR-PF09)'
echo '==================================================================='
# The claim under test is "served as HTTP range requests against one static archive, never proxied
# through a live tile-serving process". A `proxy_pass` put in this location later would still
# answer 200 with the whole body and the map would still draw — the client would just refetch the
# entire archive for every tile, and nothing in a browser says so. The status code is the only
# place that difference surfaces.
probe GET marketplace-domain.com /tiles/x.pmtiles
assert_status 200                                    'apex  /tiles/ — whole archive'
assert_header accept-ranges 'bytes'                  'apex  /tiles/ — Accept-Ranges advertised'
assert_header cache-control 'public, max-age=604800' 'apex  /tiles/ — one-week lifetime (refresh job is monthly)'

# The fixture is `pmtiles\n`, 8 bytes. Asking for the middle is what proves nginx honours the
# offset: a 206 whose body is still the whole file would pass a status-only assertion.
probe GET marketplace-domain.com /tiles/x.pmtiles -H 'Range: bytes=4-6'
assert_status 206                         'apex  /tiles/ — Range: bytes=4-6 answers Partial Content'
assert_header content-range 'bytes 4-6/8' 'apex  /tiles/ — Content-Range names the slice and the total'
assert_body_exact 'les'                   'apex  /tiles/ — body is the 3 bytes asked for, not the archive'

# A reader that has the archive header will ask past the end of a stale copy. 416 is what tells it
# to re-read; a 200 with the whole body is the failure this pins down.
probe GET marketplace-domain.com /tiles/x.pmtiles -H 'Range: bytes=99-200'
assert_status 416 'apex  /tiles/ — unsatisfiable range is refused, not answered whole'

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
echo ' Authenticated Origin Pulls — only Cloudflare opens a connection'
echo '==================================================================='

# Static half. Four includes, not three: a vhost count leaves out the `www` redirect, which is a
# server block of its own and would go on answering an unauthenticated caller.
_inc=$(grep -h -c 'include snippets/origin-pull.conf;' /src/sites-available/*.conf | awk '{s+=$1} END {print s}')
[ "$_inc" = 4 ] && pass 'origin-pull.conf is included by all four 443 blocks' ||
	fail "origin-pull.conf is included $_inc time(s), expected 4"

_def=$(grep -rl 'ssl_verify_client' /src/conf.d /src/snippets /src/sites-available | wc -l)
[ "$_def" = 1 ] && pass 'ssl_verify_client is declared in exactly one file' ||
	fail "ssl_verify_client is declared in $_def files — it belongs in the snippet only"

# ⚠️ The default server is left alone on purpose. `ssl_reject_handshake on` refuses earlier in the
# handshake than client verification runs, so these directives there are dead configuration that
# reads as a second control.
if grep -q 'ssl_verify_client\|ssl_client_certificate' /src/conf.d/40-tls.conf; then
	fail 'the default server declares client verification — dead configuration, ssl_reject_handshake is earlier'
else
	pass 'the default server block is untouched'
fi

# Behavioural half. Four names, because there are four 443 blocks.
TLS_HOSTS='marketplace-domain.com www.marketplace-domain.com shopowner.marketplace-domain.com admin.marketplace-domain.com'

for h in $TLS_HOSTS; do
	# shellcheck disable=SC2086
	_c=$(curl -sk -o /dev/null -w '%{http_code}' $RESOLVE "https://$h/" 2>/dev/null)
	[ "$_c" = 400 ] && pass "$h refuses a caller presenting no client certificate → 400" ||
		fail "$h served a caller presenting no client certificate → $_c"
done

for h in $TLS_HOSTS; do
	# shellcheck disable=SC2086
	_c=$(curl -sk -o /dev/null -w '%{http_code}' $RESOLVE $CLIENT "https://$h/" 2>/dev/null)
	case "$_c" in
		200|308) pass "$h serves a certificate signed by the trusted CA → $_c" ;;
		*)       fail "$h refused the trusted client certificate → $_c" ;;
	esac
done

# ⚠️ Issuer, not merely "a certificate". Cloudflare's shared global origin-pull certificate is
# handed to every Cloudflare customer, so trusting that CA would admit anyone willing to open a
# free account and point their own zone here.
# shellcheck disable=SC2086
_c=$(curl -sk -o /dev/null -w '%{http_code}' $RESOLVE --cert /tmp/rogue.crt --key /tmp/rogue.key \
	"https://marketplace-domain.com/" 2>/dev/null)
case "$_c" in
	200|308) fail "a certificate from an unrelated CA was accepted → $_c" ;;
	*)       pass "a certificate from an unrelated CA is refused → ${_c:-handshake aborted}" ;;
esac

# ⚠️ Port 80 carries no client verification and must not: an ACME HTTP-01 renewal presents no
# certificate, and breaking it would take the TLS material down with it a few weeks later. The
# ACME assertions above already run without $CLIENT; this is the same property stated where
# somebody adding a directive to the `:80` blocks will read it.
curl -s -o "$BODY" -D "$HDR".raw --resolve "marketplace-domain.com:80:127.0.0.1" \
	"http://marketplace-domain.com/.well-known/acme-challenge/probe-token" 2>/dev/null
tr -d '\r' <"$HDR".raw >"$HDR"
[ "$(status)" = 200 ] && pass 'ACME on :80 still completes with no client certificate' ||
	fail "ACME on :80 → $(status) with no client certificate; certbot renewal would fail"

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
# reload, and the assertions above have already spent part of the admin login's budget.
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
		_codes="$_codes $(curl -sk -o /dev/null -w '%{http_code}' -X POST $RESOLVE $CLIENT "https://$1$2" 2>/dev/null)"
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

burst_probe admin.marketplace-domain.com     /public-authorization 24 'admin login  (mkt_admin_auth 1r/m b20)'
burst_probe shopowner.marketplace-domain.com /public-authorization 24 'shop-owner login (mkt_owner_auth 1r/m b20)'
# The customer surface's own login zone. The two probes above are on the panel hostnames and spend
# `mkt_owner_auth` / `mkt_admin_auth`; `mkt_auth` is a third, separate budget reached only through
# the apex — which is the whole point of giving the three logins zones of their own, since they all
# land on the same service (public-authorization, 4028).
burst_probe marketplace-domain.com           /public-authorization 24 'customer login  (mkt_auth 1r/m b20)'

# ⚠️ There is deliberately no registration burst test, because there is no `mkt_register` zone to
# test and no `/api/register` to aim one at. Registration is a GraphQL POST to /public-resource like
# every other public write, bounded at the edge by `mkt_public` and properly metered inside
# marketplace-dev-public-resource by `guardPublicWrite` — two Redis counters per hour, per IP *and*
# per email address. The per-email half is what actually stops a mail-bomb and no nginx zone keyed
# on $binary_remote_addr can express it. See the comments in 20-rate-limit.conf and the apex vhost.

# --------------------------------------------------------------------------------------
# Access logging. Last in the run, because its second half reloads nginx with
# `set_real_ip_from` pointed at the loopback, which changes the key every rate-limit zone
# buckets on and would quietly invalidate the section above it.
# --------------------------------------------------------------------------------------
echo
echo '==================================================================='
echo ' Access logs carry no client address'
echo '==================================================================='

# RFC 5737 documentation addresses rather than plausible ones: a line that leaks either is
# unmistakable in this output, and neither can collide with anything the container itself uses.
CLIENT_IP=203.0.113.77
HOP_IP=198.51.100.9

# The static half — the format itself. This is the grep a reviewer runs; keeping it here means a
# variable added to the format later fails a run rather than waiting for the next review.
FMT=$(sed -n '/^log_format/,/;/p' /src/conf.d/05-logging.conf)
_bad=''
for _v in '$remote_addr' '$binary_remote_addr' '$realip_remote_addr' '$http_x_forwarded_for' \
	'$proxy_add_x_forwarded_for' '$http_x_real_ip'; do
	case "$FMT" in *"$_v"*) _bad="$_bad $_v" ;; esac
done
[ -z "$_bad" ] && pass 'log_format mkt_access names no address variable' ||
	fail "log_format mkt_access names$_bad"

# The other direction, and it is not decoration: a format that logs nothing is trivially clean and
# gets reverted the first time somebody has to debug from it, which loses the property above too.
_missing=''
for _v in '$time_iso8601' '$host' '$request_method' '$mkt_uri' '$server_protocol' '$status' \
	'$body_bytes_sent' '$mkt_referer' '$http_user_agent' '$request_time' '$upstream_response_time'; do
	case "$FMT" in *"$_v"*) ;; *) _missing="$_missing $_v" ;; esac
done
[ -z "$_missing" ] && pass 'log_format mkt_access keeps everything not derived from the network' ||
	fail "log_format mkt_access dropped$_missing"

# The raw forms, and naming any one of them puts the account address and a live one-time
# hash straight back in the file. ⚠️ Matched by regex rather than by `case`, because `$request` is a
# prefix of `$request_method` and `$request_time`, which the format legitimately names: a substring
# test here would fail every run.
_raw=''
_names_raw() {   # NAME REGEX — record NAME when the format matches REGEX
	printf '%s\n' "$FMT" | grep -qE "$2" && _raw="$_raw $1"
}
_names_raw '$request'      '\$request([^_a-zA-Z0-9]|$)'
_names_raw '$request_uri'  '\$request_uri'
_names_raw '$http_referer' '\$http_referer'
[ -z "$_raw" ] && pass 'log_format mkt_access names no un-redacted request line or referer' ||
	fail "log_format mkt_access names$_raw — that is the mailed link in full"

# And the maps those two redacted variables come from. A format naming `$mkt_uri` with no map to
# define it does not fail `nginx -t` in any way a reader would connect to this: nginx refuses the
# whole configuration with `unknown "mkt_uri" variable`, which reads like a typo rather than like a
# deleted control.
for _m in mkt_uri mkt_referer; do
	grep -qE "^map[[:space:]]+\\\$[a-z_]+[[:space:]]+\\\$$_m[[:space:]]*\{" /src/conf.d/05-logging.conf &&
		pass "\$$_m is defined by a map in 05-logging.conf" ||
		fail "\$$_m has no map — the format names a variable nothing redacts"
done

# A third map, in conf.d/30-cache.conf, matches the same four prefixes and stops the edge
# STORING what these two stop it LOGGING. Two regexes over one list, because the redaction map needs
# a named capture to rebuild the flow name and the cache map only needs a yes. Asserted as a literal
# string on purpose: a fifth mailed link added to one file and not the other would otherwise be
# redacted in the log while sitting in /var/cache/nginx/ in full, and nothing would say so.
_alt='check/verify-email-user|check/verify-email|reset-password|x/reset'
for _f in 05-logging.conf 30-cache.conf; do
	grep -qF "$_alt" "/src/conf.d/$_f" &&
		pass "conf.d/$_f matches all four mailed-link prefixes" ||
		fail "conf.d/$_f no longer carries '$_alt' — the redaction and the cache bypass have drifted"
done

# An `access_log` with no format name means the built-in `combined`, and so does a server block
# that declares none at all and inherits the stock http-level one. Both start with the address, so
# one new vhost written from the old template reopens this with nothing to see in the diff.
_unnamed=$(grep -rn '^[[:space:]]*access_log[[:space:]]' /src/conf.d /src/sites-available /src/snippets |
	grep -v '[[:space:]]off;' | grep -v 'mkt_access;')
if [ -z "$_unnamed" ]; then
	pass 'every access_log directive in the repo names its format'
else
	fail 'access_log with no format name — that is the built-in combined:'
	echo "$_unnamed" | sed 's/^/        /'
fi

# assert_log_clean FILE LABEL — the newest line must exist, and contain no address in any form.
# ⚠️ The empty check is not a formality. "This address does not appear" is satisfied by a line
# that was never written, so without it the whole section passes on a broken log path — and would
# have passed before this check existed.
assert_log_clean() {
	_line=$(tail -1 "/var/log/nginx/$1")
	if [ -z "$_line" ]; then
		fail "$2 — nothing was logged at all, so the address assertion never ran"
		return
	fi
	_hit=''
	for _a in "$CLIENT_IP" "$HOP_IP" 127.0.0.1; do
		case "$_line" in *"$_a"*) _hit="$_hit $_a" ;; esac
	done
	if [ -n "$_hit" ]; then
		fail "$2 — address(es)$_hit in: $_line"
	else
		pass "$2"
		echo "        $_line"
	fi
}

# ⚠️ The request has to arrive the way Cloudflare sends it. Asserting no address appears in the
# log of a request that carried none proves nothing at all.
log_probe() {   # HOST
	: >"/var/log/nginx/$1.access.log"
	probe GET "$1" / -H "CF-Connecting-IP: $CLIENT_IP" -H "X-Forwarded-For: $CLIENT_IP, $HOP_IP"
}

for h in $HOSTS; do
	log_probe "$h"
	assert_status 200 "$h answered the logged request"
	assert_log_clean "$h.access.log" "$h — no address in the access log"
done

echo
echo '  --- and no account address or one-time hash either ---'

# The four mailed links, driven as a mail client follows them. Two are the encoded form koa-utils
# actually sends (`encodeURI` turns `@` into `%40`), two the decoded form, because a client that
# normalises the URL must not walk out of the redaction. `LINK_EMAIL`, `LINK_EMAIL_ENC` and
# `LINK_HASH` are defined once, up in the SSR cache section, which asserts the other half of the
# same problem: the log must not record these values and the cache must not store them.

# assert_log_redacted FILE EXPECTED LABEL — the newest line must exist, must carry EXPECTED, and
# must hold neither half of the credential in either encoding. EXPECTED is not decoration: a format
# that logged no URI at all would satisfy "the address does not appear" and lose every reason the
# access log is kept. The address check rides along on the same line — one request, both properties.
assert_log_redacted() {
	_line=$(tail -1 "/var/log/nginx/$1")
	if [ -z "$_line" ]; then
		fail "$3 — nothing was logged at all, so the redaction assertion never ran"
		return
	fi
	_hit=''
	for _s in "$LINK_EMAIL" "$LINK_EMAIL_ENC" "$LINK_HASH" "$CLIENT_IP" "$HOP_IP" 127.0.0.1; do
		case "$_line" in *"$_s"*) _hit="$_hit $_s" ;; esac
	done
	case "$_line" in *"$2"*) ;; *) _hit="$_hit (no '$2')" ;; esac
	if [ -n "$_hit" ]; then
		fail "$3 —$_hit in: $_line"
	else
		pass "$3"
		echo "        $_line"
	fi
}

link_probe() {   # HOST PATH [extra curl args…]
	_lh=$1
	_lp=$2
	shift 2
	: >"/var/log/nginx/$_lh.access.log"
	probe GET "$_lh" "$_lp" -H "CF-Connecting-IP: $CLIENT_IP" \
		-H "X-Forwarded-For: $CLIENT_IP, $HOP_IP" "$@"
}

link_probe marketplace-domain.com "/check/verify-email-user/$LINK_EMAIL_ENC/$LINK_HASH"
assert_status 200 'apex  /check/verify-email-user/ answered the logged request'
assert_log_redacted marketplace-domain.com.access.log '/check/verify-email-user/[redacted]' \
	'apex  /check/verify-email-user/:email/:hash — redacted'

link_probe shopowner.marketplace-domain.com "/check/verify-email/$LINK_EMAIL_ENC/$LINK_HASH"
assert_status 200 'owner /check/verify-email/ answered the logged request'
assert_log_redacted shopowner.marketplace-domain.com.access.log '/check/verify-email/[redacted]' \
	'owner /check/verify-email/:email/:hash — redacted'

# ⚠️ These two have no `location` block of their own — the customer reset link is an SSR route and
# the shop-owner one is koa-utils' default `linkPath`, which nothing here mounts. They are the
# reason the redaction is wired to the logged value at http level and not per location.
link_probe marketplace-domain.com "/reset-password/$LINK_EMAIL_ENC/$LINK_HASH"
assert_log_redacted marketplace-domain.com.access.log '/reset-password/[redacted]' \
	'apex  /reset-password/:email/:hash — redacted, and it matches no location block'

link_probe shopowner.marketplace-domain.com "/x/reset/$LINK_EMAIL/$LINK_HASH"
assert_log_redacted shopowner.marketplace-domain.com.access.log '/x/reset/[redacted]' \
	'owner /x/reset/:email/:hash — redacted, decoded @ and no location block'

# The second route into the same field. `strict-origin-when-cross-origin` on the customer surface
# sends the full URL on a same-origin request, so every asset and every GraphQL call the reset page
# makes carries the credential in `Referer` — with the request line clean and the next field not.
link_probe marketplace-domain.com / \
	-H "Referer: https://marketplace-domain.com/reset-password/$LINK_EMAIL_ENC/$LINK_HASH"
assert_log_redacted marketplace-domain.com.access.log \
	'https://marketplace-domain.com/reset-password/[redacted]' \
	'apex  Referer from the reset page — redacted'

echo
# The access-log format changes what is written to disk and nothing else. The forwarded address is
# load-bearing: it is what a service would have to read if it ever needed one, and this assertion
# is what stops that being read as a licence to strip the headers.
probe POST marketplace-domain.com /public-resource -H "X-Forwarded-For: $CLIENT_IP" \
	-H "CF-Connecting-IP: $CLIENT_IP"
assert_body 'xri=127.0.0.1' 'X-Real-IP still reaches the upstream'
assert_body 'xff=127.0.0.1' 'X-Forwarded-For still reaches the upstream'

# The same probe answers both. The upstream sees the loopback rather than the address
# the request claimed, twice over: `set_real_ip_from` does not cover 127.0.0.1 on a deployed host,
# so `CF-Connecting-IP` from an untrusted peer is ignored and `$remote_addr` stays that peer's own
# address; and `X-Forwarded-For` is now `$remote_addr` rather than the appending form, so the
# caller's own entry is dropped instead of forwarded.
assert_no_body "$CLIENT_IP" 'a caller outside set_real_ip_from is not trusted, and its X-Forwarded-For is dropped'

echo
echo '  --- and again with set_real_ip_from configured, which is the state this format exists for ---'
# Sorts after conf.d/06-real-ip.conf, which is what makes it an addition to that file's
# trusted set rather than a replacement for it: `set_real_ip_from` is additive.
cp /src/test/real-ip-overlay.conf /etc/nginx/conf.d/98-real-ip-overlay.conf
if nginx -t >/tmp/nginx-t3.out 2>&1; then
	nginx -s stop 2>/dev/null
	sleep 1
	nginx
	sleep 1

	# Prove the overlay took effect before believing anything below it. `X-Real-IP` is
	# `$remote_addr`, so the upstream echoing the client address is the realip module having
	# rewritten it — without this check the three assertions that follow pass on a run in which
	# nothing changed, which is exactly the failure this half exists to rule out.
	probe POST marketplace-domain.com /public-resource -H "CF-Connecting-IP: $CLIENT_IP"
	assert_body "xri=$CLIENT_IP" 'set_real_ip_from took effect — $remote_addr is now the client'

	for h in $HOSTS; do
		log_probe "$h"
		assert_log_clean "$h.access.log" "$h — still no address once \$remote_addr is the client"
	done

	# ------------------------------------------------------------------------------------
	# What the zones bucket on, and which zone each endpoint spends.
	#
	# Every case claims a different address out of 198.18.0.0/15, the RFC 2544 benchmarking
	# range, which is routable nowhere. That is not cosmetic: it gives each case a bucket of
	# its own with no third nginx restart, and the buckets being separate at all is the
	# assertion that the zones now key on the claimed address rather than on the single peer
	# every request in this container actually arrives from.
	# ------------------------------------------------------------------------------------
	A_ROT=198.18.0.11
	A_LOGIN=198.18.0.22
	A_OTHER=198.18.0.33

	codes_as() {   # ADDRESS HOST PATH COUNT — POST COUNT times as that client, echo the codes
		_out=''
		_i=0
		while [ "$_i" -lt "$4" ]; do
			# shellcheck disable=SC2086
			_out="$_out $(curl -sk -o /dev/null -w '%{http_code}' -X POST $RESOLVE $CLIENT \
				-H "CF-Connecting-IP: $1" "https://$2$3" 2>/dev/null)"
			_i=$((_i + 1))
		done
		echo "$_out"
	}

	assert_exhausted() {   # ADDRESS HOST PATH LABEL
		_c=$(codes_as "$1" "$2" "$3" 24)
		echo "      $4:$_c"
		case "$_c" in
			*429*) pass "$4 — 429 once the burst is spent" ;;
			*)     fail "$4 — no 429 in 24 requests; the zone is not limiting" ;;
		esac
		case "$_c" in
			*200*) pass "$4 — the burst is let through first" ;;
			*)     fail "$4 — nothing succeeded; the burst is too small to log in with" ;;
		esac
	}

	assert_open() {   # ADDRESS HOST PATH LABEL
		_c=$(codes_as "$1" "$2" "$3" 1)
		case "$_c" in *200*) pass "$4" ;; *) fail "$4 — got$_c" ;; esac
	}

	assert_exhausted "$A_ROT" marketplace-domain.com /user-authenticated-authorization \
		'rotation flood (mkt_refresh 10r/m b20)'
	assert_open "$A_ROT" marketplace-domain.com /public-authorization \
		'the same address can still log in — rotation does not spend mkt_auth'

	assert_exhausted "$A_LOGIN" marketplace-domain.com /public-authorization \
		'login flood    (mkt_auth 1r/m b20)'
	assert_open "$A_LOGIN" marketplace-domain.com /user-authenticated-authorization \
		'the same address can still rotate — login does not spend mkt_refresh'

	assert_open "$A_OTHER" marketplace-domain.com /public-authorization \
		'a second client address has a budget of its own — the zones key on the claimed address'
else
	fail 'the real_ip overlay broke the configuration'
	sed 's/^/        /' /tmp/nginx-t3.out
fi

# ⚠️ Nothing above touches the error log, and nothing can: nginx builds each entry with a
# hard-coded `client: <address>` prefix and no `log_format` reaches it. Measured — the parent
# workspace's `docs/report/log-sink-inventory.md` §6.1 — five of five request-scoped entries at the
# shipped `warn` carry that prefix. The decision is that they keep it and that the lifetime of the
# file is the control instead, which is what the section below tests.

# --------------------------------------------------------------------------------------
# Log retention. Last, and after the rotation it performs nothing may read a log
# file again: the forced runs below rename and compress the very files the section above
# asserts on.
# --------------------------------------------------------------------------------------
echo
echo '==================================================================='
echo ' Log retention — logrotate.d/nginx'
echo '==================================================================='

# The deployment target is Debian, where nginx runs as `www-data`. This image has no such user, and
# `create 0640 www-data adm` is resolved when the config is read — so logrotate would refuse the
# shipped file for a reason that has nothing to do with the file. Create the user rather than test a
# modified copy: the point of this section is that the bytes the repo installs are the bytes that
# work.
adduser -S -D -H www-data 2>/dev/null

# Over the top of the one the `logrotate` package ships under that name, which is the install step
# `README.md` describes and the reason this repo's file is called `nginx` too: two files globbing
# `/var/log/nginx/*.log` make logrotate drop one of them whole.
LR=/etc/logrotate.d/nginx
cp /src/logrotate.d/nginx "$LR"

_lr_ship=$(ls /src/logrotate.d | tr '\n' ' ')
[ "$_lr_ship" = 'nginx ' ] &&
	pass 'logrotate.d ships exactly one file, named nginx — one stanza per log file' ||
	fail "logrotate.d holds '$_lr_ship' — a second file globbing the same logs is a duplicate entry, and logrotate skips the whole later file"

# Every destination the repo names, plus nginx's own http-level error.log, which is not in any file
# here and is where the 162 start/stop entries land. `logrotate -d` then reports which of them the
# pattern picks up, so this is logrotate's reading of the glob and not a second grep of it.
_dests=$(grep -rhoE '(access_log|error_log)[[:space:]]+/var/log/[^[:space:];]+' \
	/src/conf.d /src/sites-available /src/snippets | awk '{print $2}' | sort -u)
_dests="$_dests
/var/log/nginx/error.log"
for _d in $_dests; do
	mkdir -p "$(dirname "$_d")"
	printf 'retention probe\n' >>"$_d"
done

if logrotate -d -s /tmp/logrotate.state "$LR" >/tmp/lr-debug.out 2>&1; then
	pass 'logrotate -d accepts logrotate.d/nginx — the shipped file parses'
else
	fail 'logrotate.d/nginx does not parse'
	sed 's/^/        /' /tmp/lr-debug.out
fi

_uncovered=''
for _d in $_dests; do
	grep -qF "considering log $_d" /tmp/lr-debug.out || _uncovered="$_uncovered $_d"
done
[ -z "$_uncovered" ] &&
	pass 'every log destination in the repo is covered by the rotation pattern' ||
	fail "not rotated:$_uncovered — those files live as long as the host lets them"

# The period and the count, read back out of logrotate rather than out of the file. `daily` +
# `rotate 14` IS the 14 days; a `weekly` that kept the same count would be 98.
_pattern=$(grep -m1 '^rotating pattern:' /tmp/lr-debug.out)
case "$_pattern" in
	*'after 1 days'*'(14 rotations)'*)
		pass 'retention is 14 daily rotations — the owner decision of 2026-08-11, at its floor' ;;
	*)  fail "retention is not 14 daily rotations — logrotate read: $_pattern" ;;
esac

# The rest of the shape. Compression, mode and owner are the retention decision's own criteria;
# `su` and `sharedscripts` are the two lines whose absence breaks rotation on the deployment target
# while leaving this file looking correct.
for _need in 'compress' 'shred' 'create 0640 www-data adm' 'su root adm' 'sharedscripts'; do
	grep -qE "^[[:space:]]*$_need[[:space:]]*(#.*)?$" "$LR" &&
		pass "logrotate.d/nginx declares '$_need'" ||
		fail "logrotate.d/nginx no longer declares '$_need'"
done
grep -qF 'kill -USR1' "$LR" &&
	pass 'logrotate.d/nginx signals nginx to reopen after the rename' ||
	fail 'no USR1 in postrotate — nginx would keep writing to the renamed inode and the new file would stay empty'

# ⚠️ The error log keeps its level and its content on purpose: the address stays and the
# lifetime is the control. Both directions are a regression — `info` adds two more address-bearing
# classes (finding §6.3), and anything above `warn` drops the failures these files exist for.
_levels=$(grep -rhoE 'error_log[[:space:]]+/var/log/nginx/[^[:space:]]+[[:space:]]+[a-z]+;' \
	/src/sites-available | awk '{print $3}' | sort -u | tr '\n' ' ')
[ "$_levels" = 'warn; ' ] &&
	pass 'every vhost error_log is still at warn' ||
	fail "vhost error_log levels are '$_levels' — expected warn on all three"

# The behavioural half: rotate for real until the retention boundary is crossed, and read back how
# logrotate removed what fell off it. Sixteen forced runs, because `rotate 14` first has to build up
# fourteen generations before the fifteenth can be dropped. A line is written before each run —
# `notifempty` skips an empty file, so without it nothing rotates twice.
_probe=/var/log/nginx/marketplace-domain.com.error.log
_i=0
while [ "$_i" -lt 16 ]; do
	printf 'retention probe %s\n' "$_i" >>"$_probe"
	logrotate -v -f -s /tmp/logrotate.run.state "$LR" >>/tmp/lr-run.out 2>&1
	_i=$((_i + 1))
done

grep -qF "Using shred to remove the file $_probe.1" /tmp/lr-run.out &&
	pass 'the plaintext copy is shredded when it is compressed, not unlinked' ||
	fail 'the uncompressed rotation was removed without shred — the addresses in it are still on the device'

grep -qF "Using shred to remove the file $_probe.15.gz" /tmp/lr-run.out &&
	pass 'the generation that falls off rotate 14 is shredded, not unlinked' ||
	fail 'nothing fell off the retention boundary through shred — rotate 14 is not removing anything, or it is unlinking it'

# ⚠️ And that it *worked*, which is a different assertion: logrotate reports the shred it attempted
# whether or not the binary could do it. On busybox the same run prints `Failed to shred …, trying
# unlink`, rotates anyway and exits 0.
if grep -qE '^error:' /tmp/lr-run.out; then
	fail 'logrotate reported an error during the forced rotations:'
	grep -E '^error:' /tmp/lr-run.out | sort -u | head -3 | sed 's/^/        /'
else
	pass 'sixteen forced rotations, no error — GNU shred is present and did the removals'
fi

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
