#!/usr/bin/env bash
# check-endpoint.sh - layered, read-only connectivity check for one endpoint.
#
# Checks, in order: DNS resolution, TCP connect, TLS handshake and
# certificate verification, and one unauthenticated HTTP request.
# Stops at the first layer that fails and says which layer it was.
#
# Usage:
#   ./check-endpoint.sh [options] HOST [PORT]
#
# Options:
#   -p PATH     HTTP path to request (default: /)
#   -t SECONDS  Timeout per step (default: 5)
#   -c FILE     CA bundle (PEM) to trust for the TLS and HTTP steps
#   --plain     Plain TCP/HTTP, no TLS (default port 80)
#   --no-http   Skip the HTTP step
#   -h          Show this help
#
# Exit codes:
#   0   every requested step passed (HTTP status below 400, if requested)
#   1   DNS failed            2   TCP failed            3   TLS failed
#   4   HTTP request did not complete
#   5   a required tool is missing; no checks were run
#   6   HTTP response was 4xx or 5xx (DNS, TCP, and TLS passed)
#   64  usage error
#
# Certificate verification is never disabled. No credentials are sent.
# The DNS, TCP, and TLS steps test the direct path. If a proxy is set in
# the environment, curl uses it for the HTTP step and the script says so.

set -u
export LC_ALL=C

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

path="/"
timeout_s=5
ca_file=""
plain=0
do_http=1

while [ $# -gt 0 ]; do
    case "$1" in
        -p|-t|-c)
            if [ $# -lt 2 ]; then echo "Option $1 needs a value" >&2; exit 64; fi
            case "$1" in
                -p) path="$2" ;;
                -t) timeout_s="$2" ;;
                -c) ca_file="$2" ;;
            esac
            shift 2
            ;;
        --plain) plain=1; shift ;;
        --no-http) do_http=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
        *) break ;;
    esac
done

host="${1:-}"
if [ -z "$host" ]; then usage >&2; exit 64; fi
if [ "$plain" -eq 1 ]; then port="${2:-80}"; else port="${2:-443}"; fi

case "$port" in ''|*[!0-9]*) echo "PORT must be a number" >&2; exit 64 ;; esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then echo "PORT must be 1-65535" >&2; exit 64; fi
case "$timeout_s" in ''|*[!0-9]*) echo "Timeout must be a whole number of seconds" >&2; exit 64 ;; esac
# timeout(1) treats 0 as "no limit", so require at least 1 second.
if [ "$timeout_s" -lt 1 ] || [ "$timeout_s" -gt 300 ]; then echo "Timeout must be 1-300 seconds" >&2; exit 64; fi
case "$path" in /*) ;; *) path="/$path" ;; esac
if [ -n "$ca_file" ] && [ ! -r "$ca_file" ]; then echo "CA file not readable: $ca_file" >&2; exit 64; fi
case "$host" in *[!A-Za-z0-9.:_-]*) echo "HOST contains unexpected characters" >&2; exit 64 ;; esac

have() { command -v "$1" >/dev/null 2>&1; }

# Every tool a requested step needs must exist before anything runs, so a
# missing tool can never turn into a skipped step and a successful exit.
required="timeout getent awk sed grep sort tr"
[ "$plain" -eq 0 ] && required="$required openssl"
[ "$do_http" -eq 1 ] && required="$required curl"
missing=""
for tool in $required; do have "$tool" || missing="$missing $tool"; done
if [ -n "$missing" ]; then
    echo "Missing required tool(s):$missing. No checks were run." >&2
    exit 5
fi

pass() { printf '  [ OK ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; }
info() { printf '         %s\n' "$1"; }

is_ip=0
if printf '%s' "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' || printf '%s' "$host" | grep -q ':'; then
    is_ip=1
fi

url_host="$host"
if printf '%s' "$host" | grep -q ':'; then url_host="[$host]"; fi

echo "Endpoint: $host port $port"
for v in https_proxy HTTPS_PROXY http_proxy no_proxy NO_PROXY; do
    if [ -n "${!v:-}" ]; then
        info "$v is set in the environment (value not shown)"
    fi
done

# 1. DNS -------------------------------------------------------------------
echo "1. DNS"
if [ "$is_ip" -eq 1 ]; then
    pass "HOST is an IP address; DNS skipped"
else
    addrs=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -z "$addrs" ]; then
        fail "$host did not resolve (getent ahosts, which includes /etc/hosts)"
        info "Next: dig $host; check /etc/resolv.conf search domains. See network/dns.md"
        exit 1
    fi
    pass "$host resolves to: $addrs"
fi

# 2. TCP -------------------------------------------------------------------
echo "2. TCP"
tcp_err=$(timeout "$timeout_s" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>&1)
tcp_rc=$?
if [ "$tcp_rc" -eq 0 ]; then
    pass "TCP connect to port $port succeeded"
else
    if printf '%s' "$tcp_err" | grep -q '/dev/tcp.*No such file'; then
        fail "This bash was built without /dev/tcp support; the TCP step cannot run"
        exit 5
    elif [ "$tcp_rc" -eq 124 ]; then
        fail "TCP connect timed out after ${timeout_s}s (no reply: dropped, wrong address, or host down)"
        info "Next: check firewalls and routing on the path. See network/workflows.md#connection-refused-versus-timeout"
    elif printf '%s' "$tcp_err" | grep -qi 'refused'; then
        fail "TCP connection refused (host reachable; nothing listening or a reject rule)"
        info "Next: on the server, ss -ltnp | grep :$port"
    else
        fail "TCP connect failed: $(printf '%s' "$tcp_err" | sed 's/^.*: //' | tail -1)"
        info "Next: ip route get <address>; see network/workflows.md"
    fi
    exit 2
fi

# 3. TLS -------------------------------------------------------------------
if [ "$plain" -eq 0 ]; then
    echo "3. TLS"
    tls_args=(-connect "$url_host:$port")
    if [ "$is_ip" -eq 1 ]; then
        tls_args+=(-verify_ip "$host")
    else
        tls_args+=(-servername "$host" -verify_hostname "$host")
    fi
    if [ -n "$ca_file" ]; then tls_args+=(-CAfile "$ca_file"); fi

    tls_out=$(timeout "$timeout_s" openssl s_client "${tls_args[@]}" </dev/null 2>&1)
    tls_rc=$?
    verify_line=$(printf '%s\n' "$tls_out" | grep -m1 'Verify return code:' | sed 's/^ *//')
    proto=$(printf '%s\n' "$tls_out" | sed -n 's/^New, \(TLSv[0-9.]*\), Cipher is \(.*\)$/\1 \2/p' | head -1)
    [ -z "$proto" ] && proto=$(printf '%s\n' "$tls_out" | grep -m1 -E '^ *Protocol *:' | sed 's/^ *Protocol *: *//')
    cert_pem=$(printf '%s\n' "$tls_out" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')

    if [ -z "$cert_pem" ]; then
        if [ "$tls_rc" -eq 124 ]; then
            fail "TLS handshake timed out after TCP connected (possible MTU problem or non-TLS service)"
        else
            fail "TLS handshake failed before a certificate was received"
            info "$(printf '%s\n' "$tls_out" | grep -Ei 'error|alert|wrong version|unexpected eof' | head -1)"
        fi
        info "Next: see network/tls-openssl.md#handshake-failures"
        exit 3
    fi

    info "Protocol and cipher: ${proto:-unknown}"
    cert_info=$(printf '%s\n' "$cert_pem" | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)
    printf '%s\n' "$cert_info" | while IFS= read -r line; do info "$line"; done
    san=$(printf '%s\n' "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | sed 's/^ *//')
    [ -n "$san" ] && info "SAN: $san"

    case "$verify_line" in
        *'return code: 0 '*)
            pass "Certificate chain and name verified"
            ;;
        *)
            fail "Certificate verification failed: ${verify_line:-no verify result}"
            info "Next: look up the code in network/tls-openssl.md#verify-return-codes. Do not disable verification."
            exit 3
            ;;
    esac
fi

# 4. HTTP ------------------------------------------------------------------
if [ "$do_http" -eq 1 ]; then
    echo "4. HTTP"
    if [ "$plain" -eq 1 ]; then scheme=http; else scheme=https; fi
    curl_args=(-sS -o /dev/null --max-time "$timeout_s"
        -w 'code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s ttfb=%{time_starttransfer}s total=%{time_total}s')
    if [ -n "$ca_file" ]; then curl_args+=(--cacert "$ca_file"); fi
    http_out=$(curl "${curl_args[@]}" "$scheme://$url_host:$port$path" 2>&1)
    http_rc=$?
    code=$(printf '%s' "$http_out" | sed -n 's/.*code=\([0-9][0-9][0-9]\).*/\1/p')
    if [ "$http_rc" -eq 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then
        timings="$(printf '%s' "$http_out" | sed 's/^code=[0-9]* //')"
        case "$code" in
            [123]??)
                pass "HTTP response received: $code for GET $path"
                info "$timings"
                ;;
            *)
                fail "HTTP response received with error status $code for GET $path"
                info "$timings"
                case "$code" in
                    401) info "401: the network works; authentication is required or failed. See api/http-error-troubleshooting.md" ;;
                    403) info "403: the network works; the request or identity is not allowed. See api/http-error-troubleshooting.md" ;;
                    407) info "407: a proxy requires authentication" ;;
                    5??) info "$code: the server or a gateway in front of it reported an error" ;;
                    *) info "See api/http-error-troubleshooting.md for status $code" ;;
                esac
                exit 6
                ;;
        esac
    else
        fail "HTTP request did not complete: $(printf '%s' "$http_out" | grep -o 'curl: ([0-9]*) .*' | head -1)"
        exit 4
    fi
fi

steps="DNS, TCP"
[ "$plain" -eq 0 ] && steps="$steps, TLS"
[ "$do_http" -eq 1 ] && steps="$steps, HTTP"
echo "Done. Passed: $steps."
exit 0
