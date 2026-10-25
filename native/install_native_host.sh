#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install_native_host.sh -- register the native messaging host for the
# "mpv AI chain" extension.
#
#   ./native/install_native_host.sh            install where a browser exists
#   ./native/install_native_host.sh --all      install for every known browser
#   ./native/install_native_host.sh --uninstall
#
# The host script is copied to a stable location (~/.local/lib/mpv-ai-extension)
# before registering, so the registration keeps working if the git checkout is
# moved or deleted. Re-run this after changing mpv_ai_host.py.
#
# Chromium reads host manifests from <profile-root>/NativeMessagingHosts/; there
# is no per-user search path, so each browser root needs its own copy.
# ---------------------------------------------------------------------------
set -euo pipefail

HOST_NAME="com.hyperramzey.mpv_ai"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mpv-ai-extension"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"

# Chromium-family profile roots. A root is only used when it already exists,
# unless --all is given: creating ~/.config/google-chrome/ for a browser that is
# not installed leaves litter behind.
BROWSER_ROOTS=(
  "$CONFIG_DIR/net.imput.helium"
  "$CONFIG_DIR/chromium"
  "$CONFIG_DIR/google-chrome"
  "$CONFIG_DIR/google-chrome-beta"
  "$CONFIG_DIR/BraveSoftware/Brave-Browser"
  "$CONFIG_DIR/vivaldi"
  "$CONFIG_DIR/microsoft-edge"
)

MODE="install"
INSTALL_ALL=0
for arg in "$@"; do
  case "$arg" in
    --all) INSTALL_ALL=1 ;;
    --uninstall) MODE="uninstall" ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == "uninstall" ]]; then
  removed=0
  for root in "${BROWSER_ROOTS[@]}"; do
    manifest="$root/NativeMessagingHosts/$HOST_NAME.json"
    if [[ -f "$manifest" ]]; then
      rm -f "$manifest"
      echo "removed $manifest"
      removed=$((removed + 1))
    fi
  done
  rm -rf "$LIB_DIR"
  echo "removed $LIB_DIR"
  echo "uninstalled ($removed manifest(s))"
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

ext_id="$(python3 "$SCRIPT_DIR/extension_id.py")"
if [[ -z "$ext_id" ]]; then
  echo "could not derive the extension id from extension/manifest.json" >&2
  exit 1
fi

mkdir -p "$LIB_DIR"
install -m 755 "$SCRIPT_DIR/mpv_ai_host.py" "$LIB_DIR/mpv_ai_host.py"
install -m 644 "$SCRIPT_DIR/extension_id.py" "$LIB_DIR/extension_id.py"
host_path="$LIB_DIR/mpv_ai_host.py"

echo "extension id : $ext_id"
echo "host script  : $host_path"

installed=0
for root in "${BROWSER_ROOTS[@]}"; do
  if [[ $INSTALL_ALL -eq 0 && ! -d "$root" ]]; then
    continue
  fi
  mkdir -p "$root/NativeMessagingHosts"
  python3 - "$root/NativeMessagingHosts/$HOST_NAME.json" "$HOST_NAME" "$host_path" "$ext_id" <<'PY'
import json
import sys

path, name, host, ext_id = sys.argv[1:5]
manifest = {
    "name": name,
    "description": "Start the local mpv NVIDIA AI chain (VSR, TrueHDR, DLSS 5 NR, VFG)",
    "path": host,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{ext_id}/"],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  echo "registered   : $root/NativeMessagingHosts/$HOST_NAME.json"
  installed=$((installed + 1))
done

if [[ $installed -eq 0 ]]; then
  echo "no browser profile directory found under $CONFIG_DIR" >&2
  echo "start the browser once, then re-run this script (or use --all)" >&2
  exit 1
fi

# End-to-end check: frame the same message Chrome sends and verify the reply.
python3 - "$host_path" <<'PY'
import json
import struct
import subprocess
import sys

host = sys.argv[1]
payload = json.dumps({"cmd": "ping"}).encode()
proc = subprocess.run(
    [host],
    input=struct.pack("<I", len(payload)) + payload,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=20,
    check=False,
)
if proc.returncode != 0:
    sys.exit(f"host exited {proc.returncode}: {proc.stderr.decode(errors='replace')}")
(length,) = struct.unpack("<I", proc.stdout[:4])
reply = json.loads(proc.stdout[4:4 + length])
if not reply.get("ok"):
    sys.exit(f"host refused ping: {reply}")
missing = [name for name, path in reply["tools"].items() if not path]
print("host ok      :", reply["python"])
print("log          :", reply["log"])
if missing:
    print("missing tools:", ", ".join(missing), "(install them before using that profile)")
else:
    print("tools        : all four resolved on PATH")
PY
