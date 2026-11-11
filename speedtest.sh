#!/bin/sh
# Speed-test one PIA WireGuard server from a throwaway container.
#
# Run by refresh-loop.sh (REGION_SELECT=fastest) as:
#   docker run --rm -i --cap-add NET_ADMIN --dns 1.1.1.1 \
#     --entrypoint /app/speedtest.sh <this image> < some-wg.conf
#
# Reads a pia-wg-config WireGuard config on stdin, brings the tunnel up as this
# container's default route, downloads a test file for BENCH_SECONDS over BENCH_STREAMS
# parallel connections, and prints the total download speed in bytes/second.
# Prints 0 (and exits 1) if the tunnel carried no data. The live gluetun tunnel
# is never touched.
set -eu

: "${BENCH_SECONDS:=8}"
: "${BENCH_STREAMS:=4}"
: "${BENCH_URLS:=https://speed.cloudflare.com/__down?bytes=50000000 https://cachefly.cachefly.net/100mb.test}"
: "${BENCH_MTU:=1320}"

conf=$(cat)
get() {
  printf '%s\n' "$conf" | sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" | head -n 1 | tr -d '\r'
}

priv=$(get PrivateKey)
addr=$(get Address)
pub=$(get PublicKey)
endpoint=$(get Endpoint)
if [ -z "$priv" ] || [ -z "$addr" ] || [ -z "$pub" ] || [ -z "$endpoint" ]; then
  echo "speedtest: config on stdin is missing PrivateKey/Address/PublicKey/Endpoint" >&2
  echo 0
  exit 1
fi
endpoint_ip=${endpoint%:*}
addr=${addr%%/*}

gw=$(ip route show default | awk '{print $3; exit}')
dev=$(ip route show default | awk '{print $5; exit}')

umask 077
printf '%s\n' "$priv" > /tmp/wg.key
ip link add wgt type wireguard
wg set wgt private-key /tmp/wg.key peer "$pub" endpoint "$endpoint" allowed-ips 0.0.0.0/0 persistent-keepalive 25
ip addr add "$addr/32" dev wgt
ip link set mtu "$BENCH_MTU" up dev wgt
# Keep the VPN server itself reachable over the normal network, send the rest through the tunnel.
ip route add "$endpoint_ip/32" via "$gw" dev "$dev"
ip route replace default dev wgt

# Pick the first test file that answers through the tunnel (this also waits for the handshake).
url=""
for candidate in $BENCH_URLS; do
  code=$(curl -s -o /dev/null --connect-timeout 5 --max-time 8 -r 0-999 -w '%{http_code}' "$candidate" 2>/dev/null || true)
  case "$code" in
    200|206) url="$candidate"; break ;;
  esac
done
if [ -z "$url" ]; then
  echo "speedtest: no test file reachable through the tunnel" >&2
  echo 0
  exit 1
fi

# One stream: keep re-downloading the test file until the time is up, print bytes received.
stream() {
  end=$(($(date +%s) + BENCH_SECONDS))
  sum=0
  while :; do
    left=$((end - $(date +%s)))
    [ "$left" -le 0 ] && break
    n=$(curl -s -o /dev/null --connect-timeout 5 --max-time "$left" -w '%{size_download}' "$url" 2>/dev/null || true)
    n=${n%%.*}
    [ -z "$n" ] && n=0
    [ "$n" -lt 100000 ] && break
    sum=$((sum + n))
  done
  echo "$sum"
}

i=0
while [ "$i" -lt "$BENCH_STREAMS" ]; do
  stream > "/tmp/stream.$i" &
  i=$((i + 1))
done
wait || true

total=$(cat /tmp/stream.* 2>/dev/null | awk '{s += $1} END {printf "%d", s}')
speed=$((total / BENCH_SECONDS))
echo "$speed"
[ "$speed" -gt 0 ]
