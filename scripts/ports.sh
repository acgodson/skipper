#!/usr/bin/env bash
# Port and process guards for the scripts that start a local server.
# Sourced, never run: a test must never pass against a server it did not start,
# so the port is proved free before the server starts and the process is proved
# alive after it answers.

port_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

any_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# require_port_free <port> <what to do about it>
require_port_free() {
  if port_free "$1"; then return 0; fi
  echo "FAIL  port $1 is already in use, so this would test someone else's server: $2"
  return 1
}

# still_running <pid> <name>
still_running() {
  if kill -0 "$1" 2>/dev/null; then return 0; fi
  echo "FAIL  $2 is not running: whatever answered on its port is not the server this script started"
  return 1
}
