#!/bin/sh
# Start the test Gopher server, run capi/build/test against it, stop it.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
portfile=$(mktemp)
python3 -I "$dir/test-server.py" > "$portfile" &
server=$!
trap 'kill $server 2>/dev/null; rm -f "$portfile"' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$portfile" ] && break
  sleep 0.2
done
port=$(head -n 1 "$portfile")
"$dir/build/test" "$dir/build/gopher.core" "$port"
