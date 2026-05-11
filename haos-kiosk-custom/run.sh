#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
VERSION="1.0.0"

printf '%*s\n' 80 '' | tr ' ' '#'
bashio::log.info "######## Starting Home Assistant Display (Chromium) ########"
bashio::log.info "$(date) [Version: $VERSION]"

cleanup() {
  local exit_code=$?
  jobs -p | xargs -r kill 2>/dev/null || true
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
  bashio::log.warning "Auto-login enabled (xdotool). If HA search opens on startup, prefer Trusted Networks + empty username/password."
else
  AUTO_LOGIN=false
  bashio::log.info "Auto-login disabled (recommended with Trusted Networks)."
fi

################################################################################
# DBus
DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address || true)
export DBUS_SESSION_BUS_ADDRESS

################################################################################
# udev
bashio::log.info "Starting udevd..."
udevd --daemon || true
udevadm trigger || true
udevadm settle --timeout=10 || true

################################################################################
# Xorg config
rm -rf /tmp/.X*-lock
mkdir -p /etc/X11

cat > /etc/X11/xorg.conf << 'EOF'
Section "Device"
 Identifier "Card0"
 Driver "modesetting"
 Option "DRI" "3"
EndSection

Section "Screen"
 Identifier "Screen0"
 Device "Card0"
 DefaultDepth 24
EndSection

Section "InputClass"
 Identifier "libinput keyboard"
 MatchIsKeyboard "on"
 Driver "libinput"
EndSection

Section "InputClass"
 Identifier "libinput pointer"
 MatchIsPointer "on"
 Driver "libinput"
 Option "Tapping" "on"
 Option "NaturalScrolling" "true"
EndSection

Section "InputClass"
 Identifier "libinput touchscreen"
 MatchIsTouchscreen "on"
 Driver "libinput"
 Option "Tapping" "on"
 Option "TappingDrag" "on"
EndSection
EOF

################################################################################
# Start Xorg
bashio::log.info "Starting Xorg on DISPLAY=:0..."
Xorg :0 -nocursor -keeptty -noreset -allowMouseOpenFail -ignoreABI </dev/null >/tmp/xorg.log 2>&1 &
X_PID=$!

# Wait for X socket
for _ in $(seq 1 40); do
  [ -S /tmp/.X11-unix/X0 ] && break
  sleep 0.25
done

if [ ! -S /tmp/.X11-unix/X0 ]; then
  bashio::log.error "Xorg did not start. See /tmp/xorg.log"
  exit 1
fi

export DISPLAY=:0

################################################################################
# Openbox
openbox &
sleep 0.5

################################################################################
# Screen timeout
xset +dpms || true
if [ "${SCREEN_TIMEOUT}" = "0" ]; then
  xset s off || true
  xset -dpms || true
else
  xset s "$SCREEN_TIMEOUT" || true
  xset dpms "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT" || true
fi

################################################################################
# Outputs
readarray -t OUTPUTS < <(xrandr --query | awk '/ connected/ {print $1}')
if [ ${#OUTPUTS[@]} -eq 0 ]; then
  bashio::log.error "No connected outputs detected."
  exit 1
fi

if [ "$OUTPUT_NUMBER" -gt "${#OUTPUTS[@]}" ]; then
  OUTPUT_NUMBER=${#OUTPUTS[@]}
fi

OUTPUT_NAME="${OUTPUTS[$((OUTPUT_NUMBER - 1))]}"
bashio::log.info "Using output: $OUTPUT_NAME"

for OUTPUT in "${OUTPUTS[@]}"; do
  if [ "$OUTPUT" = "$OUTPUT_NAME" ]; then
    if [ "$ROTATE_DISPLAY" = normal ]; then
      xrandr --output "$OUTPUT_NAME" --primary --auto
    else
      xrandr --output "$OUTPUT_NAME" --primary --rotate "${ROTATE_DISPLAY}"
    fi
  else
    xrandr --output "$OUTPUT" --off
  fi
done

################################################################################
# Touch mapping
if [ "$MAP_TOUCH_INPUTS" = true ]; then
  while IFS= read -r id; do
    name=$(xinput list --name-only "$id" 2>/dev/null || true)
    [[ "${name,,}" =~ (^|[^[:alnum:]_])(touch|touchscreen|stylus)([^[:alnum:]_]|$) ]] || continue
    props="$(xinput list-props "$id" 2>/dev/null || true)"
    [[ "$props" = *"Coordinate Transformation Matrix"* ]] || continue
    xinput map-to-output "$id" "$OUTPUT_NAME" || true
  done < <(xinput list --id-only 2>/dev/null | sort -n)
fi

################################################################################
# Keyboard layout
setxkbmap "$KEYBOARD_LAYOUT" || true

################################################################################
# Screen dimensions
read -r SCREEN_WIDTH SCREEN_HEIGHT < <(
  xrandr --query --current | grep "^$OUTPUT_NAME " |
  sed -n "s/^$OUTPUT_NAME connected.* \\([0-9]\\+\\)x\\([0-9]\\+\\)+.*$/\\1 \\2/p"
)
[ -z "$SCREEN_WIDTH" ] && SCREEN_WIDTH=1280
[ -z "$SCREEN_HEIGHT" ] && SCREEN_HEIGHT=720

################################################################################
# On-screen keyboard
case "${ONSCREEN_KEYBOARD_MODE}" in
  always)
    bashio::log.info "On-screen keyboard: ALWAYS (matchbox-keyboard)"
    matchbox-keyboard &
    ;;
  manual)
    bashio::log.info "On-screen keyboard: MANUAL (use REST /keyboard/toggle)"
    ;;
  off|*)
    bashio::log.info "On-screen keyboard: OFF"
    ;;
esac

################################################################################
# REST server
bashio::log.info "Starting REST server on 127.0.0.1:${REST_PORT}..."
REST_PORT="$REST_PORT" REST_BEARER_TOKEN="$REST_BEARER_TOKEN" python3 /rest_server.py &

################################################################################
# Debug mode
if [ "$DEBUG_MODE" = true ]; then
  bashio::log.info "DEBUG MODE: X/Openbox running, Chromium not started."
  wait
  exit 0
fi

################################################################################
# Chromium flags
ZOOM_DPI=$(awk "BEGIN {printf \"%.2f\", $ZOOM_LEVEL / 100}")

CHROME_FLAGS="\
 --no-sandbox \
 --test-type \
 --start-fullscreen \
 --noerrdialogs \
 --disable-session-crashed-bubble \
 --disable-restore-session-state \
 --disable-infobars \
 --disable-notifications \
 --disable-popup-blocking \
 --force-device-scale-factor=$ZOOM_DPI \
 --disable-features=TranslateUI \
 --window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT} \
 --no-first-run \
 --user-data-dir=/data/chromium-profile"

[ "$DARK_MODE" = true ] && CHROME_FLAGS="$CHROME_FLAGS --force-dark-mode"

FULL_URL="${HA_URL}"
[ -n "$HA_DASHBOARD" ] && FULL_URL="${HA_URL}/${HA_DASHBOARD}"

bashio::log.info "Launching Chromium → $FULL_URL"

mkdir -p /data/chromium-profile/Default
chromium $CHROME_FLAGS "$FULL_URL" >/tmp/chromium.log 2>&1 &
CHROME_PID=$!

################################################################################
# Optional auto-login (best-effort, can be flaky)
if [ "$AUTO_LOGIN" = true ]; then
  (
    sleep "${LOGIN_DELAY%.*}"
    for attempt in $(seq 1 20); do
      WINDOW_ID=$(xdotool search --class chromium 2>/dev/null | head -1 || true)
      [ -n "$WINDOW_ID" ] && break
      sleep 0.5
    done

    # SAFETY: do not type unless user explicitly enabled credentials.
    if [ -n "$WINDOW_ID" ]; then
      # Try to focus address bar then navigate to /login (best-effort)
      xdotool key --window "$WINDOW_ID" ctrl+l 2>/dev/null || true
      sleep 0.2
      xdotool type --clearmodifiers --delay 25 "${HA_URL}/login" 2>/dev/null || true
      xdotool key --window "$WINDOW_ID" Return 2>/dev/null || true
      sleep 2

      # Now type creds (still best-effort)
      xdotool type --clearmodifiers --delay 50 "$HA_USERNAME" 2>/dev/null || true
      xdotool key --window "$WINDOW_ID" Tab 2>/dev/null || true
      xdotool type --clearmodifiers --delay 50 "$HA_PASSWORD" 2>/dev/null || true
      xdotool key --window "$WINDOW_ID" Return 2>/dev/null || true
    fi
  ) &
fi

################################################################################
# Browser refresh timer
if [ "$BROWSER_REFRESH" -gt 0 ] 2>/dev/null; then
  (
    while true; do
      sleep "$BROWSER_REFRESH"
      WINDOW_ID=$(xdotool search --class chromium 2>/dev/null | head -1 || true)
      [ -n "$WINDOW_ID" ] && xdotool key --window "$WINDOW_ID" ctrl+r 2>/dev/null || true
    done
  ) &
fi

bashio::log.info "Monitoring Chromium (PID: $CHROME_PID)..."
wait "$CHROME_PID"

