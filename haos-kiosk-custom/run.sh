#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
VERSION="1.0.0"

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
# udev (On ne lance pas udevd car HAOS avec udev:true le fait déjà)
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
  # Option "kmsdev" "/dev/dri/card0" # Décommente si ça échoue encore
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
  # On empêche Xorg de chercher à gérer les terminaux physiques
  Option "DontZap" "true"
EndSection

Section "ServerLayout"
  Identifier "Layout0"
  Option "AutoAddDevices" "true"
EndSection
EOF

################################################################################
# Préparation des périphériques et nettoyage
################################################################################
bashio::log.info "Preparing environment for Xorg..."

# Nettoyage radical des sockets et des verrous
rm -rf /tmp/.X* /tmp/.X11-unix
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# Forcer les permissions sur les périphériques critiques
# Cela aide énormément si le mode privilégié de Docker a des ratés
chmod 666 /dev/tty0 || true
chmod 666 /dev/fb0 || true
chmod 666 /dev/dri/* || true
chmod 666 /dev/input/* || true

################################################################################
# Start Xorg
################################################################################
bashio::log.info "Starting Xorg on DISPLAY=:0..."

# On lance Xorg avec tous les drapeaux de contournement pour HAOS
# -sharevts et -novtswitch empêchent le conflit avec la console de secours de HA
Xorg :0 -nocursor -keeptty -sharevts -novtswitch -noreset -ignoreABI >/tmp/xorg.log 2>&1 &
X_PID=$!

# Attente du socket X11 (on est patient, 20 secondes max)
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
# Outputs & Rotation
readarray -t OUTPUTS < <(xrandr --query | awk '/ connected/ {print $1}')
if [ ${#OUTPUTS[@]} -eq 0 ]; then
  bashio::log.error "No connected outputs detected."
  # On ne quitte pas forcément, xrandr peut mentir au début
fi

OUTPUT_NAME="${OUTPUTS[$((OUTPUT_NUMBER - 1))]:-HDMI-1}"
bashio::log.info "Target output: $OUTPUT_NAME"

if [ "$ROTATE_DISPLAY" = "normal" ]; then
  xrandr --output "$OUTPUT_NAME" --auto || true
else
  xrandr --output "$OUTPUT_NAME" --rotate "$ROTATE_DISPLAY" --auto || true
fi

################################################################################
# Chromium
################################################################################
# Calcul du Zoom
ZOOM_DPI=$(awk "BEGIN {printf \"%.2f\", $ZOOM_LEVEL / 100}")

# Récupération de la résolution réelle via xrandr (détectée plus haut dans le script)
# Si la détection a échoué, on met 1920x1080 par défaut
[ -z "$SCREEN_WIDTH" ] && SCREEN_WIDTH=1920
[ -z "$SCREEN_HEIGHT" ] && SCREEN_HEIGHT=1080

bashio::log.info "Configuring Chromium for resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"

CHROME_FLAGS="\
 --no-sandbox \
 --test-type \
 --start-fullscreen \
 --kiosk \
 --noerrdialogs \
 --disable-session-crashed-bubble \
 --disable-infobars \
 --force-device-scale-factor=$ZOOM_DPI \
 --window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT} \
 --window-position=0,0 \
 --enable-virtual-keyboard \
 --touch-events=enabled \
 --ui-enable-touch-events \
 --disable-features=TranslateUI \
 --user-data-dir=/data/chromium-profile"

# Ajout du mode sombre si activé
[ "$DARK_MODE" = "true" ] && CHROME_FLAGS="$CHROME_FLAGS --force-dark-mode"

# Construction de l'URL
FULL_URL="${HA_URL}"
[ -n "$HA_DASHBOARD" ] && FULL_URL="${HA_URL}/${HA_DASHBOARD}"

bashio::log.info "Launching Chromium → $FULL_URL"

mkdir -p /data/chromium-profile
# Lancement de Chromium
chromium $CHROME_FLAGS "$FULL_URL" >/tmp/chromium.log 2>&1 &
CHROME_PID=$!

bashio::log.info "Monitoring Chromium (PID: $CHROME_PID)..."
wait "$CHROME_PID"
