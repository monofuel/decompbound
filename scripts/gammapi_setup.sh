#!/bin/bash
# Set up decompbound on gammapi (Pi 3A+, Pi OS Bookworm, RetroPie ES menu).
#
#   scripts/gammapi_setup.sh [rom-path]
#
# Run on gammapi from the repo checkout. Idempotent: installs the Nim
# toolchain via nimby (prebuilt arm64), the build/runtime libraries, builds
# the shipping player, lays out ~/decompbound, writes the launcher into the
# EmulationStation "Custom" menu (any .sh dropped in that folder shows up
# there) and registers that system if the menu lacks it. The ROM
# defaults to the RetroArch working copy already on the box. See
# docs/raspberry-pi.md.
set -euo pipefail

ROM_SRC=${1:-"$HOME/RetroPie/roms/snes/Earthbound (U) [!].smc"}
INSTALL=$HOME/decompbound
NIM_VERSION=2.2.4
NIMBY_URL=https://github.com/treeform/nimby/releases/download/0.2.3/nimby-Linux-ARM64
ES_USER_CFG=$HOME/.emulationstation/es_systems.cfg
ES_SYS_CFG=/etc/emulationstation/es_systems.cfg
CUSTOM_DIR=$HOME/RetroPie/roms/custom

echo "== libraries"
sudo apt-get install -y --no-install-recommends \
  libopenal-dev libevdev-dev libudev-dev libgl-dev libx11-dev libxext-dev libxcursor-dev \
  libopenal1 libevdev2 libudev1 libgl1 libx11-6 libxext6 libxcursor1 git curl >/dev/null

echo "== nim $NIM_VERSION via nimby"
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/nimby" ]; then
  curl -sL -o "$HOME/.local/bin/nimby" "$NIMBY_URL"
  chmod +x "$HOME/.local/bin/nimby"
fi
export PATH=$HOME/.local/bin:$HOME/.nimby/nim/bin:$PATH
grep -q '.nimby/nim/bin' "$HOME/.bashrc" || \
  echo 'export PATH=$HOME/.local/bin:$HOME/.nimby/nim/bin:$PATH' >> "$HOME/.bashrc"
[ -x "$HOME/.nimby/nim/bin/nim" ] || nimby use "$NIM_VERSION"
nim -v | head -1
nimby sync -g nimby.lock | tail -1

echo "== build"
make release-play
ldd bin/decompbound-play | grep -E "not found" && { echo "missing runtime libraries"; exit 1; }

echo "== install to $INSTALL"
mkdir -p "$INSTALL/bin/states" "$INSTALL/captures"
install -m 755 bin/decompbound-play "$INSTALL/decompbound-play"
if [ ! -f "$INSTALL/bin/Earthbound (U) [!].smc" ]; then
  cp "$ROM_SRC" "$INSTALL/bin/Earthbound (U) [!].smc"
fi
SRM_SRC=${ROM_SRC%.smc}.srm
if [ -f "$SRM_SRC" ] && [ ! -f "$INSTALL/bin/Earthbound (U) [!].srm" ]; then
  cp "$SRM_SRC" "$INSTALL/bin/Earthbound (U) [!].srm"
  echo "copied existing RetroArch battery save"
fi

echo "== EmulationStation custom entry"
mkdir -p "$CUSTOM_DIR"
cat > "$PORTS_DIR/decompbound.sh" <<'EOF'
#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
cd "$HOME/decompbound" || exit 1
exec ./decompbound-play --kiosk "bin/Earthbound (U) [!].smc" >> play_stdout.log 2>&1
EOF
chmod +x "$PORTS_DIR/decompbound.sh"
if [ ! -f "$ES_USER_CFG" ]; then
  mkdir -p "$(dirname "$ES_USER_CFG")"
  cp "$ES_SYS_CFG" "$ES_USER_CFG"
fi
if ! grep -q "<name>custom</name>" "$ES_USER_CFG"; then
  python3 - "$ES_USER_CFG" "$CUSTOM_DIR" <<'EOF'
import sys
path, custom = sys.argv[1], sys.argv[2]
s = open(path).read()
entry = f"""  <system>
    <name>custom</name>
    <fullname>Custom</fullname>
    <path>{custom}</path>
    <extension>.sh .SH</extension>
    <command>bash %ROM%</command>
    <platform>pc</platform>
    <theme>ports</theme>
  </system>
</systemList>"""
s = s.replace("</systemList>", entry, 1)
open(path, "w").write(s)
EOF
  echo "added custom system to $ES_USER_CFG"
fi
echo "== done: restart EmulationStation, then Custom -> decompbound"
