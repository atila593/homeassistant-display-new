#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
VERSION="1.1.0-gpu"

printf '%*s\n' 80 '' | tr ' ' '#'
bashio::log.info "######## Starting Home Assistant Display (Chromium) ########"
bashio::log.info "$(date) [Version: $VERSION]"

cleanup() {
  local exit_code=$?
  bashio::log.info "Cleaning up before exit..."
  jobs -p | xargs -r kill 2>/dev/null || true
  rm -rf /tmp/.X* /tmp/.X11-unix
  exit "$exit_code"
}
trap cleanup HUP INT QUIT ABRT TERM EXIT

load_config_var() {
  local VAR_NAME="$1"
  local DEFAULT="${2:-}"
  local MASK="${3:-}"
  local VALUE=""

  if bashio::config.exists "${VAR_NAME,,}"; then
    VALUE="$(bashio::config "${VAR_NAME,,}")"
  fi

  if [ "$VALUE" = "null" ] || [ -z "$VALUE" ]; then
    VALUE="$DEFAULT"
  fi

  printf -v "$VAR_NAME" '%s' "$VALUE"
  eval "export $VAR_NAME"

  if [ -z "$MASK" ]; then
    bashio::log.info "$VAR_NAME=$VALUE"
  else
    bashio::log.info "$VAR_NAME=XXXXXX"
  fi
}

bashio::log.info "Loading configuration..."
load_config_var HA_USERNAME ""
load_config_var HA_PASSWORD "" 1
load_config_var HA_URL "http://127.0.0.1:8123"
load_config_var HA_DASHBOARD ""
load_config_var LOGIN_DELAY 8.0
load_config_var ZOOM_LEVEL 100
load_config_var BROWSER_REFRESH 600
load_config_var SCREEN_TIMEOUT 0
load_config_var OUTPUT_NUMBER 1
load_config_var DARK_MODE true
load_config_var HA_SIDEBAR "none"
load_config_var ROTATE_DISPLAY normal
load_config_var MAP_TOUCH_INPUTS true
load_config_var CURSOR_TIMEOUT 5
load_config_var KEYBOARD_LAYOUT us
load_config_var ONSCREEN_KEYBOARD_MODE off
load_config_var REST_PORT 8080
load_config_var REST_BEARER_TOKEN "" 1
load_config_var DEBUG_MODE false

if [ -n "$HA_USERNAME" ] && [ -n "$HA_PASSWORD" ]; then
  AUTO_LOGIN=true
else
  AUTO_LOGIN=false
fi

################################################################################
# DBus & X11 Prep
rm -rf /tmp/.X* /tmp/.X11-unix
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address || true)
export DBUS_SESSION_BUS_ADDRESS

################################################################################
# udev
bashio::log.info "Settling udev devices..."
udevadm trigger || true
udevadm settle --timeout=10 || true

################################################################################
# Xorg config
mkdir -p /etc/X11
cat > /etc/X11/xorg.conf << 'EOF'
Section "Device"
  Identifier "Card0"
  Driver "modesetting"
  Option "AccelMethod" "glamor"
EndSection

Section "Screen"
  Identifier "Screen0"
  Device "Card0"
  DefaultDepth 24
EndSection

Section "ServerFlags"
  Option "DontVTSwitch" "true"
  Option "AllowMouseOpenFail" "true"
  Option "AutoAddGPU" "false"
  Option "DontZap" "true"
EndSection

Section "ServerLayout"
  Identifier "Layout0"
  Option "AutoAddDevices" "true"
EndSection
EOF

################################################################################
# Préparation des périphériques
################################################################################
bashio::log.info "Preparing environment for Xorg..."

rm -rf /tmp/.X* /tmp/.X11-unix
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

chmod 666 /dev/tty0 || true
chmod 666 /dev/fb0 || true
chmod 666 /dev/dri/* || true
chmod 666 /dev/input/* || true

################################################################################
# Start Xorg
################################################################################
bashio::log.info "Starting Xorg on DISPLAY=:0..."

Xorg :0 -nocursor -keeptty -sharevts -novtswitch -noreset -ignoreABI >/tmp/xorg.log 2>&1 &
X_PID=$!

bashio::log.info "Waiting for X server to initialize..."
for _ in $(seq 1 40); do
  [ -S /tmp/.X11-unix/X0 ] && break
  sleep 0.5
done

if [ ! -S /tmp/.X11-unix/X0 ]; then
  bashio::log.error "Xorg failed to initialize. Here is the log content:"
  cat /tmp/xorg.log
  exit 1
fi

bashio::log.info "X server is up and running!"
export DISPLAY=:0

################################################################################
# Window Manager
openbox &
sleep 1

################################################################################
# Outputs & Resolution Detection
################################################################################
readarray -t OUTPUTS < <(xrandr --query | awk '/ connected/ {print $1}')

if [ ${#OUTPUTS[@]} -eq 0 ]; then
  bashio::log.warn "No connected outputs detected by xrandr, using default HDMI-1"
  OUTPUT_NAME="HDMI-1"
else
  OUTPUT_NAME="${OUTPUTS[$((OUTPUT_NUMBER - 1))]:-${OUTPUTS[0]}}"
fi

bashio::log.info "Target output: $OUTPUT_NAME"

RAW_RES=$(xrandr --query | grep "^$OUTPUT_NAME connected" | grep -oP '\d+x\d+\+' | head -1 | tr -d '+')

if [ -n "$RAW_RES" ]; then
    SCREEN_WIDTH=$(echo "$RAW_RES" | cut -d'x' -f1)
    SCREEN_HEIGHT=$(echo "$RAW_RES" | cut -d'x' -f2)
else
    bashio::log.warn "Could not detect resolution, defaulting to 1920x1080"
    SCREEN_WIDTH=1920
    SCREEN_HEIGHT=1080
fi

export SCREEN_WIDTH
export SCREEN_HEIGHT

if [ "$ROTATE_DISPLAY" = "normal" ]; then
  xrandr --output "$OUTPUT_NAME" --auto || true
else
  xrandr --output "$OUTPUT_NAME" --rotate "$ROTATE_DISPLAY" --auto || true
fi

################################################################################
# Chromium Configuration
################################################################################
ZOOM_FACTOR=$(awk "BEGIN {printf \"%.2f\", $ZOOM_LEVEL / 100}")

CHROME_FLAGS="\
 --no-sandbox \
 --test-type \
 --start-fullscreen \
 --kiosk \
 --noerrdialogs \
 --disable-session-crashed-bubble \
 --disable-infobars \
 --window-position=0,0 \
 --window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT} \
 --force-device-scale-factor=${ZOOM_FACTOR} \
 --enable-virtual-keyboard \
 --touch-events=enabled \
 --ui-enable-touch-events \
 --disable-features=TranslateUI,UseChromeOSDirectVideoDecoder \
 --user-data-dir=/data/chromium-profile \
 --use-gl=egl \
 --enable-gpu-rasterization \
 --enable-zero-copy \
 --ignore-gpu-blocklist \
 --enable-accelerated-video-decode \
 --enable-features=VaapiVideoDecoder \
 --disable-dev-shm-usage \
 --renderer-process-limit=3"

# --- GESTION DE LA VEILLE ---
if command -v xset &>/dev/null; then
  bashio::log.info "Disabling DPMS and screen blanking..."
  xset s off
  xset -dpms
  xset s noblank
fi

# --- CONSTRUCTION DE L'URL ---
HA_URL_STRIP="${HA_URL%/}"
if [ -z "$HA_DASHBOARD" ]; then
  FULL_URL="$HA_URL_STRIP"
else
  DASH_STRIP="${HA_DASHBOARD#/}"
  FULL_URL="${HA_URL_STRIP}/${DASH_STRIP}"
fi

bashio::log.info "Launching Chromium at ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
bashio::log.info "URL: $FULL_URL"

mkdir -p /data/chromium-profile

################################################################################
# BOUCLE DE MAINTENANCE (Refresh + Anti-veille)
################################################################################
(
  sleep 20
  while true; do
    xset s off -dpms 2>/dev/null
    if [ "$BROWSER_REFRESH" -gt 0 ]; then
      sleep "$BROWSER_REFRESH"
      bashio::log.info "Maintenance: Auto-refreshing browser..."
      WINDOW=$(xdotool search --class chromium | head -1)
      if [ -n "$WINDOW" ]; then
        xdotool key --window "$WINDOW" ctrl+r
      else
        bashio::log.warn "Maintenance: Chromium window not found for refresh"
      fi
    else
      sleep 60
    fi
  done
) &
MAINTENANCE_PID=$!

################################################################################
# BOUCLE PRINCIPALE — Restart Chromium sans toucher à Xorg
################################################################################
bashio::log.info "Starting Chromium watchdog loop..."

CRASH_COUNT=0

while true; do
  bashio::log.info "Starting Chromium (attempt $((CRASH_COUNT + 1)))..."
  chromium $CHROME_FLAGS "$FULL_URL" >/tmp/chromium.log 2>&1 &
  CHROME_PID=$!
  bashio::log.info "Chromium launched (PID: $CHROME_PID)"

  wait "$CHROME_PID"
  EXIT_CODE=$?
  CRASH_COUNT=$((CRASH_COUNT + 1))

  bashio::log.warn "Chromium exited (code=$EXIT_CODE, crash #$CRASH_COUNT). Restarting in 5s..."

  # Nettoyage du profil si crash répété (corrompu)
  if [ "$CRASH_COUNT" -ge 3 ]; then
    bashio::log.warn "3 crashes detected — clearing Chromium profile cache..."
    rm -rf /data/chromium-profile/Default/Cache
    rm -rf /data/chromium-profile/Default/GPUCache
    rm -f /data/chromium-profile/Default/Preferences
    CRASH_COUNT=0
  fi

  sleep 5
done

kill "$MAINTENANCE_PID" 2>/dev/null || true
bashio::log.info "Add-on exited."

