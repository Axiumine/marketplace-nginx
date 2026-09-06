#!/bin/sh
#
# Warns before an Authenticated Origin Pulls certificate expires. RISK_REGISTER R44.
#
#   ./scripts/check-origin-pull-cert-expiry.sh --file <cert.pem> [--warn-days N]
#
# ⚠️ **This detects. It does not renew.** Renewal is README.md §Authenticated Origin Pulls §5
# Renewal, run by a human with Cloudflare API credentials this repo does not have and will not
# hold. What this buys is that the day arrives with a warning in front of it instead of four 443
# blocks that stopped accepting Cloudflare an hour ago.
#
# ⚠️ **Two certificates expire on this connection, and only one of them lives on this host.**
# `/etc/nginx/certs/origin-pull-ca.pem` is the CA nginx verifies against; when it lapses, every
# Cloudflare client certificate stops verifying and the outage is identical. `cloudflare-client.pem`
# is the other half, and it is uploaded to Cloudflare rather than served from here — point this at
# the copy the adopter retained, or it is checked by nobody. Both are worth a timer.
#
# Nothing here reads a private key, and nothing prints a certificate body: only the subject, the
# `notAfter` date, and a verdict.
#
# Exit 0  OK       — the certificate outlives the window.
# Exit 1  WARN     — it expires inside the window, or has expired already.
# Exit 2  UNUSABLE — bad arguments, or a path openssl cannot read as a certificate. Deliberately
#                    distinct from WARN: a timer that treats "the file moved" as "still fine" is the
#                    failure this script exists to remove, so an unreadable path is never exit 0.

set -eu

WARN_DAYS=60
FILE=''

usage() {
	echo "usage: $0 --file <cert.pem> [--warn-days N]" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--file)      [ $# -ge 2 ] || usage; FILE="$2"; shift 2 ;;
		--warn-days) [ $# -ge 2 ] || usage; WARN_DAYS="$2"; shift 2 ;;
		-h|--help)   usage ;;
		*)           echo "unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$FILE" ] || usage

case "$WARN_DAYS" in
	'' | *[!0-9]*) echo "--warn-days takes a whole number of days, got: $WARN_DAYS" >&2; exit 2 ;;
esac

[ -r "$FILE" ] || { echo "UNUSABLE $FILE — not readable"; exit 2; }

# One parse, before the expiry question: `-checkend` against something that is not a certificate
# exits 1 too, which would otherwise be reported as an expiring certificate rather than as a path
# pointing at the wrong file.
END=$(openssl x509 -enddate -noout -in "$FILE" 2> /dev/null | sed 's/^notAfter=//') || END=''
[ -n "$END" ] || { echo "UNUSABLE $FILE — openssl cannot read a certificate here"; exit 2; }

SUBJECT=$(openssl x509 -subject -noout -in "$FILE" 2> /dev/null | sed 's/^subject=//')

if openssl x509 -checkend $((WARN_DAYS * 86400)) -noout -in "$FILE" > /dev/null 2>&1; then
	echo "OK   $FILE — expires $END, more than $WARN_DAYS day(s) away [$SUBJECT]"
	exit 0
fi

echo "WARN $FILE — expires $END, inside the $WARN_DAYS day window [$SUBJECT]"
echo "     Renew it: README.md §Authenticated Origin Pulls §5 Renewal. Nothing renews it on its own."
exit 1
