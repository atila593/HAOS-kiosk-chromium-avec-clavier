#!/bin/bash
. /usr/lib/bashio/bashio.sh
# shellcheck shell=bash
################################################################################
# Add-on: HAOS Kiosk Display (haoskiosk)
# File: run.sh
# Version: 1.3.3 (Modified for Chromium & Onboard AT-SPI fix)
# Copyright Jeff Kosowsky / Customization for Chromium
# Date: April 2026
#
#  Code does the following:
#      - Import and sanity-check the following variables from HA/config.yaml
#          HA_USERNAME
#          HA_PASSWORD
#          HA_URL
#          HA_DASHBOARD
#          LOGIN_DELAY
#          ZOOM_LEVEL
#          BROWSER_REFRESH
#          SCREEN_TIMEOUT
#          OUTPUT_NUMBER
#          DARK_MODE
#          HA_SIDEBAR
#          HA_THEME
#          ROTATE_DISPLAY
#          MAP_TOUCH_INPUTS
#          CURSOR_TIMEOUT
#          KEYBOARD_LAYOUT
#          ONSCREEN_KEYBOARD
#          SAVE_ONSCREEN_CONFIG
#          XORG_CONF
#          XORG_APPEND_REPLACE
#          AUDIO_SINK
#          REST_PORT
#          REST_IP
#          REST_BEARER_TOKEN
#          COMMAND_WHITELIST
#          VNC_SERVER
#          DEBUG_MODE
#
#      - Hack to delete (and later restore) /dev/tty0 (needed for X to start
#        and to prevent udev permission errors))
#      - Start udev
#      - Hack to manually tag USB input devices (in /dev/input) for libinput
#      - Start X window system
#      - Stop console cursor blinking
#      - Start Openbox window manager
#      - Set up (enable/disable) screen timeouts
#      - Rotate screen per configuration
#      - Map touch inputs per configuration
#      - Set keyboard layout and language
#      - Set up onscreen keyboard per configuration
#      - Set audio sink
#      - Start Xinput parsing...
#      - Start REST API server
#      - Launch browser for url: $HA_URL/$HA_DASHBOARD
#        [If not in DEBUG_MODE; Otherwise, just sleep]
#

# Générer un machine-id si absent pour éviter le crash de D-Bus
if [ ! -f /etc/machine-id ]; then
    if command -v dbus-uuidgen &> /dev/null; then
        dbus-uuidgen > /etc/machine-id
    else
        echo "dad4f339155a4f13a44c3ca4adb2fa13" > /etc/machine-id
    fi
fi
mkdir -p /var/lib/dbus
if [ ! -f /var/lib/dbus/machine-id ]; then
    ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi

# Créer un faux dbus-launch avec un émulateur de protocole D-Bus en Python
mkdir -p /tmp/bin
cat << 'EOF' > /tmp/bin/dbus-launch
#!/bin/bash
rm -f /tmp/dbus_socket /tmp/dbus_ready
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('/tmp/dbus_socket')
s.listen(5)
with open('/tmp/dbus_ready', 'w') as f:
    f.write('1')
while True:
    try:
        conn, _ = s.accept()
        # Répondre au protocole de handshake D-Bus initial pour valider la connexion
        data = conn.recv(1024)
        if data:
            conn.sendall(b'OK 1234567890abcdef1234567890abcdef\r\n')
        while True:
            chunk = conn.recv(1024)
            if not chunk:
                break
            # Accepter les requêtes sans broncher
            conn.sendall(b'\r\n')
    except:
        pass
" &> /dev/null &

# Attendre que le socket soit prêt
while [ ! -f /tmp/dbus_ready ]; do
    sleep 0.05
done

printf "unix:path=/tmp/dbus_socket\n"
exit 0
EOF
chmod +x /tmp/bin/dbus-launch
export PATH="/tmp/bin:$PATH"

################################################################################
echo "."  # Almost blank line (Note totally blank or white space lines are swallowed)
printf '%*s\n' 80 '' | tr ' ' '#'  # Separator
bashio::log.info "######## Starting HAOSKiosk (Chromium Edition) ########"
bashio::log.info "$(uname -a)"

#### Clean up on exit:
TTY0_DELETED=""  #Need to set to empty string since runs with nounset=on (like set -u)
ONBOARD_CONFIG_FILE="/config/onboard-settings.dconf"
cleanup() {
    local exit_code=$?
    bashio::log.info "Cleaning up and exiting..."
    if [ "$SAVE_ONSCREEN_CONFIG" = true ]; then
        dconf dump /org/onboard/ > "$ONBOARD_CONFIG_FILE"
    fi
    jobs -p | xargs -r kill
    [ -n "$TTY0_DELETED" ] && mknod -m 620 /dev/tty0 c 4 0
    exit "$exit_code"
}
trap cleanup HUP INT QUIT ABRT TERM EXIT

################################################################################
#### Variables (Modifiées pour Chromium)
BROWSER="chromium"
BROWSER_FLAGS="--no-sandbox --kiosk --disable-infobars --disable-session-crashed-bubble --overscroll-history-navigation=0 --enable-features=UseOzonePlatform --ozone-platform=x11 --user-data-dir=/data/chromium-profile --password-store=basic --disable-gpu"

################################################################################
#### Get config variables from HA add-on & set environment variables
load_config_var() {
    local var_name="$1"
    local default_val="${2:-}"
    local mask="${3:-}"

    local json_key="${var_name,,}"
    local val
    val=$(jq --raw-output --arg key "$json_key" '.[$key] // empty' /data/options.json)

    if [ -z "$val" ]; then
        val="$default_val"
        echo "[WARNING] Config key '$var_name' unset, setting to default: '$val'"
    else
        if [ "$mask" = "1" ]; then
            echo "[INFO] $var_name=XXXXXX"
        else
            echo "[INFO] $var_name=$val"
        fi
    fi

    export "$var_name"="$val"
}

load_config_var HA_USERNAME
load_config_var HA_PASSWORD "" 1  #Mask password in log
load_config_var HA_URL "http://localhost:8123"
load_config_var HA_DASHBOARD ""
load_config_var LOGIN_DELAY 1.0
load_config_var ZOOM_LEVEL 100
load_config_var BROWSER_REFRESH 600
load_config_var SCREEN_TIMEOUT 600
load_config_var OUTPUT_NUMBER 1
load_config_var DARK_MODE true
load_config_var HA_THEME ""
load_config_var HA_SIDEBAR "none"
load_config_var ROTATE_DISPLAY normal
load_config_var MAP_TOUCH_INPUTS true
load_config_var CURSOR_TIMEOUT 5
load_config_var KEYBOARD_LAYOUT us
load_config_var ONSCREEN_KEYBOARD false
load_config_var SAVE_ONSCREEN_CONFIG true
load_config_var XORG_CONF ""
load_config_var XORG_APPEND_REPLACE append
load_config_var AUDIO_SINK auto
load_config_var REST_PORT 8080
load_config_var REST_IP "127.0.0.1"
load_config_var REST_BEARER_TOKEN "" 1
load_config_var COMMAND_WHITELIST "^$"
load_config_var DEBUG_MODE false
load_config_var VNC_SERVER "" 1

if [ -z "$HA_USERNAME" ] || [ -z "$HA_PASSWORD" ]; then
    bashio::log.error "Error: HA_USERNAME and HA_PASSWORD must be set"
    exit 1
fi

################################################################################
### GTK and DBUS-related environment variables to improve stability

export NO_AT_BRIDGE=1                 # Stop GTK from touching at-spi bus
export GTK_USE_PORTAL=0               # Disable portals
export GIO_USE_VFS=local              # Local-only GIO
export DBUS_SESSION_BUS_TIMEOUT=5000  # Shorten DBUS timeouts
export GTK_CSD=0                      # Disable client side decorations

################################################################################
#### Start Dbus
DBUS_SESSION_BUS_ADDRESS=""
if command -v dbus-daemon &> /dev/null; then
    DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
else
    bashio::log.warning "WARNING: dbus-daemon not found in container, skipping..."
fi

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    bashio::log.warning "WARNING: Failed to start dbus-daemon"
else
    bashio::log.info "DBus started with: DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
    export DBUS_SESSION_BUS_ADDRESS
    echo "$DBUS_SESSION_BUS_ADDRESS" >| /tmp/DBUS_SESSION_BUS_ADDRESS
    echo "export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'" >> "$HOME/.profile"
fi

if [ -e "/dev/tty0" ]; then
    bashio::log.info "Attempting to remount /dev as 'rw' so we can (temporarily) delete /dev/tty0..."
    mount -o remount,rw /dev
    if ! mount -o remount,rw /dev ; then
        bashio::log.error "Failed to remount /dev as read-write..."
        exit 1
    fi
    if  ! rm -f /dev/tty0 ; then
        bashio::log.error "Failed to delete /dev/tty0..."
        exit 1
    fi
    TTY0_DELETED=1
    bashio::log.info "Deleted /dev/tty0 successfully..."
fi

bashio::log.info "Starting 'udevd' and (re-)triggering..."
if ! udevd --daemon || ! udevadm trigger; then
    bashio::log.warning "WARNING: Failed to start udevd or trigger udev, input devices may not work"
fi
udevadm settle --timeout=10

echo "/dev/input event devices:"
mapfile -t devices < <(find /dev/input/event* -type c 2>/dev/null | sort -V)
if [ ${#devices[@]} -eq 0 ]; then
    bashio::log.warning "WARNING: No character input event devices found"
else
    for dev in "${devices[@]}"; do
        devpath=""
        for _ in {1..25}; do
            if devpath=$(udevadm info --query=path --name="$dev" 2>/dev/null); then
                break
            fi
            sleep 0.2
        done
        [ -z "$devpath" ] && continue
        udevadm test "$devpath" >/dev/null 2>&1 || true
    done
fi
udevadm settle --timeout=10

selected_card=""
for status_path in /sys/class/drm/card[0-9]*-*/status; do
    [ -e "$status_path" ] || continue
    status=$(cat "$status_path")
    card_port=$(basename "$(dirname "$status_path")")
    card=${card_port%%-*}
    if [ -z "$selected_card" ] && [ "$status" = "connected" ]; then
        selected_card="$card"
        break
    fi
done
if [ -z "$selected_card" ]; then
    bashio::log.info "ERROR: No connected video card detected. Exiting.."
    exit 1
fi

rm -rf /tmp/.X*-lock
export DISPLAY=:0

if [[ -n "$XORG_CONF" && "${XORG_APPEND_REPLACE}" = "replace" ]]; then
    echo "${XORG_CONF}" >| /etc/X11/xorg.conf
else
    cp -a /etc/X11/xorg.conf{.default,}
    sed -i "/Option[[:space:]]\+\"DRI\"[[:space:]]\+\"3\"/a\    Option      \t\t\"kmsdev\" \"/dev/dri/$selected_card\"" /etc/X11/xorg.conf
    if [ "${XORG_APPEND_REPLACE}" = "append" ] && [ -n "$XORG_CONF" ]; then
        echo -e "\n#\n${XORG_CONF}" >> /etc/X11/xorg.conf
    fi
fi

bashio::log.info "Starting X on DISPLAY=$DISPLAY..."
NOCURSOR=""
[ "$CURSOR_TIMEOUT" -lt 0 ] && NOCURSOR="-nocursor"
Xorg $NOCURSOR </dev/null 2>&1 | grep -v "Could not resolve keysym XF86\|Errors from xkbcomp are not fatal\|XKEYBOARD keymap compiler (xkbcomp) reports" &

XSTARTUP=30
for ((i=0; i<=XSTARTUP; i++)); do
    xset q >/dev/null 2>&1 && break
    sleep 1
done

if [ -n "$TTY0_DELETED" ]; then
    mknod -m 620 /dev/tty0 c 4 0 || true
fi

if ! xset q >/dev/null 2>&1; then
    bashio::log.error "Error: X server failed to start within $XSTARTUP seconds."
    exit 1
fi

echo -e "\033[?25l" > /dev/console

if [ "$CURSOR_TIMEOUT" -gt 0 ]; then
    unclutter-xfixes --start-hidden --hide-on-touch --fork --timeout "$CURSOR_TIMEOUT"
fi

WINMGR=Openbox
mkdir -p ~/.config/openbox
RC_XML=~/.config/openbox/rc.xml
cp -a /etc/xdg/openbox/rc.xml "$RC_XML"

cat <<'EOF' > /tmp/new_keybinds.xml
  <keybind key="C-A-o">
    <action name="Execute">
      <command>dbus-send --type=method_call --dest=org.onboard.Onboard /org/onboard/Onboard/Keyboard org.onboard.Onboard.Keyboard.ToggleVisible</command>
    </action>
  </keybind>
  <keybind key="C-A-k">
    <action name="Execute">
      <command>sh -c 'scrot /media/screenshots/haoskiosk-$(date +"%Y%m%d_%H%M%S").jpg -q 90'</command>
    </action>
  </keybind>
EOF
awk -v f=/tmp/new_keybinds.xml '/<\/keyboard>/ { system("cat " f) } { print }' "$RC_XML" > /tmp/rc.new.xml
mv /tmp/rc.new.xml "$RC_XML"
rm /tmp/new_keybinds.xml

openbox &
sleep 0.5

xset +dpms
xset s "$SCREEN_TIMEOUT"
xset dpms "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT"

readarray -t OUTPUTS < <(xrandr --query | awk '/ connected/ {print $1}')
OUTPUT_NAME="${OUTPUTS[0]}"
xrandr --output "$OUTPUT_NAME" --primary --auto

if [ "$MAP_TOUCH_INPUTS" = true ]; then
    while IFS= read -r id; do
        name=$(xinput list --name-only "$id" 2>/dev/null)
        [[ "${name,,}" =~ (^|[^[:alnum:]_])(touch|touchscreen|stylus)([^[:alnum:]_]|$) ]] || continue
        xinput map-to-output "$id" "$OUTPUT_NAME" 2>/dev/null || true
    done < <(xinput list --id-only | sort -n)
fi

setxkbmap "$KEYBOARD_LAYOUT"
export LANG=$KEYBOARD_LAYOUT

read -r SCREEN_WIDTH SCREEN_HEIGHT < <(
    xrandr --query --current | grep "^$OUTPUT_NAME " |
    sed -n "s/^$OUTPUT_NAME connected.* \([0-9]\+\)x\([0-9]\+\)+.*$/\1 \2/p"
)

if [[ "$ONSCREEN_KEYBOARD" = true && -n "$SCREEN_WIDTH" && -n "$SCREEN_HEIGHT" ]]; then
    if (( SCREEN_WIDTH >= SCREEN_HEIGHT )); then
        MAX_DIM=$SCREEN_WIDTH
        MIN_DIM=$SCREEN_HEIGHT
    else
        MAX_DIM=$SCREEN_HEIGHT
        MIN_DIM=$SCREEN_WIDTH
    fi

    KBD_ASPECT_RATIO_X10=30
    LAND_HEIGHT=$(( MIN_DIM / 3 ))
    LAND_WIDTH=$(( (LAND_HEIGHT * KBD_ASPECT_RATIO_X10) / 10 ))
    LAND_Y_OFFSET=$(( MIN_DIM - LAND_HEIGHT ))
    LAND_X_OFFSET=$(( (MAX_DIM - LAND_WIDTH) / 2 ))

    PORT_HEIGHT=$(( MAX_DIM / 4 ))
    PORT_WIDTH=$(( (PORT_HEIGHT * KBD_ASPECT_RATIO_X10) / 10 ))
    PORT_Y_OFFSET=$(( MAX_DIM - PORT_HEIGHT ))
    PORT_X_OFFSET=$(( (MIN_DIM - PORT_WIDTH) / 2 ))

    set +e
    dconf write /org/onboard/layout "'/usr/share/onboard/layouts/Small.onboard'" 2>/dev/null || true
    dconf write /org/onboard/theme "'/usr/share/onboard/themes/Blackboard.theme'" 2>/dev/null || true
    dconf write /org/onboard/auto-show/enabled true 2>/dev/null || true
    dconf write /org/onboard/window/force-to-top true 2>/dev/null || true
    gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true

    dconf write /org/onboard/window/landscape/height "$LAND_HEIGHT" 2>/dev/null || true
    dconf write /org/onboard/window/landscape/width "$LAND_WIDTH" 2>/dev/null || true
    dconf write /org/onboard/window/landscape/x "$LAND_X_OFFSET" 2>/dev/null || true
    dconf write /org/onboard/window/landscape/y "$LAND_Y_OFFSET" 2>/dev/null || true

    if [ -f "$ONBOARD_CONFIG_FILE" ] && [ "$SAVE_ONSCREEN_CONFIG" = true ]; then
        dconf load /org/onboard/ < "$ONBOARD_CONFIG_FILE" 2>/dev/null || true
    fi
    set -e

    export NO_AT_BRIDGE=1
    bashio::log.info "Starting Onboard onscreen keyboard"
    NO_AT_BRIDGE=1 onboard &
fi

set +e
sink=$(pactl list short sinks 2>/dev/null | awk '{print $2; exit}')
[ -n "$sink" ] && pactl set-default-sink "$sink" >& /dev/null
set -e

bashio::log.info "Starting Mouse & Touch input gesture command parsing..."
python3 -u /mouse_touch_inputs.py -d 1 -w "$COMMAND_WHITELIST" &

bashio::log.info "Starting HAOSKiosk REST server..."
python3 -u /rest_server.py &

if [ -n "$VNC_SERVER" ]; then
    X11VNC_OPTS="-display :0 -rfbport 5900 -forever -bg -shared -quiet"
    if [ "$VNC_SERVER" != "-" ]; then
        VNC_PASSWD_FILE="/root/x11vnc.pass"
        printf '%s\n%s\ny\n' "${VNC_SERVER}" "${VNC_SERVER}" | x11vnc -storepasswd "$VNC_PASSWD_FILE" > /dev/null 2>&1
        X11VNC_OPTS="$X11VNC_OPTS -rfbauth $VNC_PASSWD_FILE"
    else
        X11VNC_OPTS="$X11VNC_OPTS -nopw"
    fi
    x11vnc $X11VNC_OPTS 2>/dev/null || true
fi

if [ "$DEBUG_MODE" != true ]; then
    $BROWSER ${BROWSER_FLAGS:+$BROWSER_FLAGS} "$HA_URL/$HA_DASHBOARD" &
    bashio::log.info "Launching $BROWSER browser: $HA_URL/$HA_DASHBOARD"
    exec sleep infinite
else
    bashio::log.info "Entering debug mode..."
    exec sleep infinite
fi
