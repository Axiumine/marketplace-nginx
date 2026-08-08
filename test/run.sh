#!/bin/sh
# Verify the edge configuration in a throwaway container.
#
#   ./nginx/test/run.sh
#
# Runs `nginx -t` against the real files in nginx/, then starts nginx against stand-in backends
# and asserts what actually comes out of the socket. Exits non-zero on the first failed check
# so it can be wired to a hook or a pipeline.
#
# Nothing is installed on this machine and nothing is written to the repository: the whole run
# lives inside the container, which is removed on exit. nginx/ is mounted read-only.
#
# ⚠️ This proves the CONFIGURATION is right. It does not prove the deployment is: certificates
# are self-signed throwaways generated inside the container, and every upstream is a stub. What
# it does prove is the part that is otherwise only discoverable in production — that the cookie
# rewrite fires, that each path reaches the service it names, that no host can reach another
# tier's service, and that every header the snippets declare survives to the client.
#
# Override the image with NGINX_TEST_IMAGE to check a version bump before rolling it out:
#   NGINX_TEST_IMAGE=nginx:1.29-alpine ./nginx/test/run.sh
#
# ⚠️ Minimum nginx 1.25.1. Below that `http2 on` is not a directive (it was a `listen`
# parameter), and below 1.19.4 `ssl_reject_handshake` and `proxy_cookie_flags` do not exist —
# the cookie rewrite is the entire point, so an older nginx does not merely warn, it ships the
# session cookie unflagged.

set -eu

NGINX_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENGINE=${CONTAINER_ENGINE:-docker}
IMAGE=${NGINX_TEST_IMAGE:-nginx:stable-alpine}

command -v "$ENGINE" >/dev/null 2>&1 || {
	echo "$ENGINE not found. Set CONTAINER_ENGINE=podman, or install one." >&2
	exit 127
}

echo "Testing $NGINX_DIR against $IMAGE"

exec "$ENGINE" run --rm \
	-v "$NGINX_DIR":/src:ro \
	"$IMAGE" sh /src/test/suite.sh
