#!/usr/bin/env bash
set -euo pipefail

# Resolve the real path of this script, following symlinks.
# This ensures we always cd to the source directory, even when
# invoked via a symlink like: ln -s /path/to/run.sh ~/bin/book-manager
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

cd "$SCRIPT_DIR"

# Check that SBCL is available
if ! command -v sbcl &>/dev/null; then
  echo "Error: sbcl not found. Please install SBCL first." >&2
  exit 1
fi

PORT=8080
URL="http://localhost:$PORT"

echo "Starting Book Manager ($URL) ..."
echo "Press Ctrl+C to stop."
echo ""

# Open browser in the background once the server is ready
(
  # Wait until the port responds (up to 30 seconds)
  for i in $(seq 1 60); do
    if curl -s -o /dev/null --connect-timeout 1 "$URL" 2>/dev/null; then
      # Detect OS and open browser
      if   command -v xdg-open  &>/dev/null; then xdg-open  "$URL"  # Linux
      elif command -v open      &>/dev/null; then open      "$URL"  # macOS
      fi
      exit 0
    fi
    sleep 0.5
  done
  echo "Warning: server did not respond within 30s. Open $URL manually." >&2
) &

exec sbcl --load start.lisp
