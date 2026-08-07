#!/bin/bash
. /usr/lib/bashio/bashio.sh
# shellcheck shell=bash
################################################################################
# Add-on: HAOS Kiosk Display (haoskiosk)
# File: run.sh
# Version: 1.3.2 (Modified for Chromium)
# Copyright Jeff Kosowsky / Customization for Chromium
# Date: April 2026
#
#  Code does the following:
#     - Import and sanity-check the following variables from HA/config.yaml
#         HA_USERNAME
#         HA_PASSWORD
#         HA_URL
#         HA_DASHBOARD
#         LOGIN_DELAY
#         ZOOM_LEVEL
#         BROWSER_REFRESH
#         SCREEN_TIMEOUT
#         OUTPUT_NUMBER
#         DARK_MODE
#         HA_SIDEBAR
#         HA_THEME
#         ROTATE_DISPLAY
#         MAP_TOUCH_INPUTS
#         CURSOR_TIMEOUT
#         KEYBOARD_LAYOUT
#         ONSCREEN_KEYBOARD
#         SAVE_ONSCREEN_CONFIG
#         XORG_CONF
#         XORG_APPEND_REPLACE
#         AUDIO_SINK
#         REST_PORT
#         REST_IP
#         REST_BEARER_TOKEN
#         COMMAND_WHITELIST
#         VNC_SERVER
#         DEBUG_MODE
#
#     - Hack to delete (and later restore) /dev/tty0 (needed for X to start
#       and to prevent udev permission errors))
#     - Start udev
#     - Hack to manually tag USB input devices (in /dev/input) for libinput
#     - Start X window system
#     - Stop console cursor blinking
#     - Start Openbox window manager
#     - Set up (enable/disable) screen timeouts
#     - Rotate screen per configuration
#     - Map touch inputs per configuration
#     - Set keyboard layout and language
#     - Set up onscreen keyboard per configuration
#     - Set audio sink
#     - Start Xinput parsing...
#     - Start REST API server
#     - Launch browser for url: $HA_URL/$HA_DASHBOARD
#       [If not in DEBUG_MODE; Otherwise, just sleep]
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

# Créer un faux dbus-launch pour éviter l'erreur "No such file or directory"
mkdir -p /tmp/bin
cat << 'EOF' > /tmp/bin/dbus-launch
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --sh-syntax|--csh-syntax|--exit-with-session) shift ;;
        *) break ;;
    esac
    shift
done
if [ $# -gt 0 ]; then
    exec "$@"
else
    echo "DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus_socket"
    echo "DBUS_SESSION_BUS_PID=12345"
fi
EOF
chmod +x /tmp/bin/dbus-launch
export PATH="/tmp/bin:$PATH"

################################################################################
echo "."  # Almost blank line (Note totally blank or white space lines are swallowed)
printf '%*s\n' 80 '' | tr ' ' '#'  # Separator
bashio::log.info "######## Starting HAOSKiosk (Chromium Edition) ########"
# bashio::log.info "$(date) [Version: ${ADDON_VERSION:-unknown}]"
bashio::log.info "$(uname -a)"
# ha_info=$(bashio::info)
# bashio::log.info "Core=$(echo "$ha_info" | jq -r '.homeassistant')  HAOS=$(echo "$ha_info" | jq -r '.hassos')  MACHINE=$(echo "$ha_info" | jq -r '.machine')  ARCH=$(echo "$ha_info" | jq -r '.arch')"

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
BROWSER_FLAGS="--no-sandbox --kiosk --disable-infobars --disable-session-crashed-bubble --overscroll-history-navigation=0 --enable-features=UseOzonePlatform --ozone-platform=x11"

################################################################################
#### Get config variables from HA add-on & set environment variables
load_config_var() {
    local var_name="$1"
    local default_val="${2:-}"
    local mask="${3:-}"

    # Lecture directe dans le fichier de configuration local du conteneur (sans API)
    # Convertit le nom de la variable en minuscules pour correspondre aux clés du JSON
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

    # Exporte la variable pour qu'elle soit dispo dans le script
    export "$var_name"="$val"
}

load_config_var HA_USERNAME
load_config_var HA_PASSWORD "" 1  #Mask password in log
load_config_var HA_URL "http://localhost:8123"
load_config_var HA_DASHBOARD ""
load_config_var LOGIN_DELAY 1.0
load_config_var ZOOM_LEVEL 100
load_config_var BROWSER_REFRESH 600
load_config_var SCREEN_TIMEOUT 600  # Default to 600 seconds
load_config_var OUTPUT_NUMBER 1  # Which *CONNECTED* Physical video output to use (Defaults to 1)
#NOTE: By only considering *CONNECTED* output, this maximizes the chance of finding an output
#      without any need to change configs. Set to 1, unless you have multiple video outputs connected.
load_config_var DARK_MODE true
load_config_var HA_THEME ""
load_config_var HA_SIDEBAR "none"
load_config_var ROTATE_DISPLAY normal
load_config_var MAP_TOUCH_INPUTS true
load_config_var CURSOR_TIMEOUT 5  # Default to 5 seconds
load_config_var KEYBOARD_LAYOUT us
load_config_var ONSCREEN_KEYBOARD false
load_config_var SAVE_ONSCREEN_CONFIG true
load_config_var XORG_CONF ""
load_config_var XORG_APPEND_REPLACE append
load_config_var AUDIO_SINK auto
load_config_var REST_PORT 8080
load_config_var REST_IP "127.0.0.1"
load_config_var REST_BEARER_TOKEN "" 1  # Mask token in log
load_config_var COMMAND_WHITELIST "^$"  # Default is no commands allowed
load_config_var DEBUG_MODE false
load_config_var VNC_SERVER ""  1 #Mask password in log

# Validate environment variables set by config.yaml
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
export GTK_CSD=0                      # Disable client side decorations (???)
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
#### Hack to get writable /dev/tty0 for X
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

#### Start udev (used by X)
bashio::log.info "Starting 'udevd' and (re-)triggering..."
if ! udevd --daemon || ! udevadm trigger; then
    bashio::log.warning "WARNING: Failed to start udevd or trigger udev, input devices may not work"
fi
udevadm settle --timeout=10  #Wait for udev event processing to complete

echo "/dev/input event devices:"
mapfile -t devices < <(find /dev/input/event* -type c 2>/dev/null | sort -V)
if [ ${#devices[@]} -eq 0 ]; then
    bashio::log.warning "WARNING: No character input event devices found"
else
    for dev in "${devices[@]}"; do
        devpath=""
        for _ in {1..25}; do  # Retry and give time to settle if not successful initially
            if devpath=$(udevadm info --query=path --name="$dev" 2>/dev/null); then
                break
            fi
            sleep 0.2
        done
        if [ -z "$devpath" ]; then
            echo "  $dev: Failed to get device path"
            continue
        fi
        echo "  $dev: $devpath"
        udevadm test "$devpath" >/dev/null 2>&1 || echo "$dev: No valid udev rule found..."
    done
fi
udevadm settle --timeout=10

## Determine main display card
bashio::log.info "DRM video cards:"
find /dev/dri/ -maxdepth 1 -type c -name 'card[0-9]*' 2>/dev/null | sed 's/^/  /'
bashio::log.info "DRM video card driver and connection status:"
selected_card=""
for status_path in /sys/class/drm/card[0-9]*-*/status; do
    [ -e "$status_path" ] || continue  # Skip if status file doesn't exist

    status=$(cat "$status_path")
    card_port=$(basename "$(dirname "$status_path")")
    card=${card_port%%-*}
    driver=$(basename "$(readlink "/sys/class/drm/$card/device/driver")")
    if [ -z "$selected_card" ]  && [ "$status" = "connected" ]; then
        selected_card="$card"  # Select first connected card
        printf "  *"
    else
        printf "   "
    fi
    printf "%-25s%-20s%s\n" "$card_port" "$driver" "$status"
done
if [ -z "$selected_card" ]; then
    bashio::log.info "ERROR: No connected video card detected. Exiting.."
    exit 1
fi

#### Start Xorg in the background
rm -rf /tmp/.X*-lock  #Cleanup old versions

export DISPLAY=:0

if [[ -n "$XORG_CONF" && "${XORG_APPEND_REPLACE}" = "replace" ]]; then
    bashio::log.info "Replacing default 'xorg.conf'..."
    echo "${XORG_CONF}" >| /etc/X11/xorg.conf
else
    cp -a /etc/X11/xorg.conf{.default,}
    sed -i "/Option[[:space:]]\+\"DRI\"[[:space:]]\+\"3\"/a\    Option     \t\t\"kmsdev\" \"/dev/dri/$selected_card\"" /etc/X11/xorg.conf

    if [ -z "$XORG_CONF" ]; then
        bashio::log.info "No user 'xorg.conf' data provided, using default..."
    elif [ "${XORG_APPEND_REPLACE}" = "append" ]; then
        bashio::log.info "Appending onto default 'xorg.conf'..."
        echo -e "\n#\n${XORG_CONF}" >> /etc/X11/xorg.conf
    fi
fi

echo "."
printf '%*s xorg.conf %*s\n' 35 '' 34 '' | tr ' ' '#'
cat /etc/X11/xorg.conf
printf '%*s\n' 80 '' | tr ' ' '#'
echo "."

bashio::log.info "Starting X on DISPLAY=$DISPLAY..."
NOCURSOR=""
[ "$CURSOR_TIMEOUT" -lt 0 ] && NOCURSOR="-nocursor"
Xorg $NOCURSOR </dev/null 2>&1 | grep -v "Could not resolve keysym XF86\|Errors from xkbcomp are not fatal\|XKEYBOARD keymap compiler (xkbcomp) reports" &

XSTARTUP=30
for ((i=0; i<=XSTARTUP; i++)); do
    if xset q >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if [ -n "$TTY0_DELETED" ]; then
    if mknod -m 620 /dev/tty0 c 4 0; then
        bashio::log.info "Restored /dev/tty0 successfully..."
    else
        bashio::log.error "Failed to restore /dev/tty0..."
    fi
fi

if ! xset q >/dev/null 2>&1; then
    bashio::log.error "Error: X server failed to start within $XSTARTUP seconds."
    exit 1
fi
bashio::log.info "X server started successfully after $i seconds..."

echo "xinput list:"
xinput list | sed 's/^/  /'

echo -e "\033[?25l" > /dev/console

if [ "$CURSOR_TIMEOUT" -gt 0 ]; then
    unclutter-xfixes --start-hidden --hide-on-touch --fork --timeout "$CURSOR_TIMEOUT"
fi

#### Start Window manager in the background
WINMGR=Openbox
mkdir -p ~/.config/openbox
RC_XML=~/.config/openbox/rc.xml
cp -a /etc/xdg/openbox/rc.xml "$RC_XML"
awk 'BEGIN{skip=0} /<keybind key="(C-A-Left|C-A-Right)">/{skip=1} /<\/keybind>/ && skip{skip=0; next} !skip{print}' "$RC_XML" > /tmp/rc.new.xml
mv /tmp/rc.new.xml "$RC_XML"

cat <<'EOF' > /tmp/new_keybinds.xml
  <!-- Toggle Onboard onscreen keyboard: Ctrl+Alt+o -->
  <keybind key="C-A-o">
    <action name="Execute">
      <command>dbus-send --type=method_call --dest=org.onboard.Onboard /org/onboard/Onboard/Keyboard org.onboard.Onboard.Keyboard.ToggleVisible</command>
    </action>
  </keybind>

  <!-- Take screenshot: Ctrl+Alt+k -->
  <keybind key="C-A-k">
    <action name="Execute">
      <command>sh -c 'scrot /media/screenshots/haoskiosk-$(date +"%Y%m%d_%H%M%S").jpg -q 90'</command>
    </action>
  </keybind>

  <!-- Next window: Ctrl+Alt+Shift+Right -->
  <keybind key="C-A-S-Right">
    <action name="NextWindow">
      <finalactions>
        <action name="Focus"/>
        <action name="Raise"/>
        <action name="Unshade"/>
      </finalactions>
    </action>
  </keybind>

  <!-- Previous window: Ctrl+Alt+Shift+Left -->
  <keybind key="C-A-S-Left">
    <action name="PreviousWindow">
      <finalactions>
        <action name="Focus"/>
        <action name="Raise"/>
        <action name="Unshade"/>
      </finalactions>
    </action>
  </keybind>

EOF
awk -v f=/tmp/new_keybinds.xml '/<\/keyboard>/ { system("cat " f) } { print }' \
    "$RC_XML" > /tmp/rc.new.xml
mv /tmp/rc.new.xml "$RC_XML"
rm /tmp/new_keybinds.xml

openbox &

O_PID=$!
sleep 0.5
if ! kill -0 "$O_PID" 2>/dev/null; then
    bashio::log.error "Failed to start $WINMGR window manager"
    exit 1
fi
bashio::log.info "$WINMGR window manager started successfully..."

xset +dpms
xset s "$SCREEN_TIMEOUT"
xset dpms "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT"
if [ "$SCREEN_TIMEOUT" -eq 0 ]; then
    bashio::log.info "Screen timeout disabled..."
else
    bashio::log.info "Screen timeout after $SCREEN_TIMEOUT seconds..."
fi

readarray -t ALL_OUTPUTS < <(xrandr --query | awk '/^[[:space:]]*[A-Za-z0-9-]+/ {print $1}')
bashio::log.info "All video outputs: ${ALL_OUTPUTS[*]}"

readarray -t OUTPUTS < <(xrandr --query | awk '/ connected/ {print $1}')
if [ ${#OUTPUTS[@]} -eq 0 ]; then
    bashio::log.info "ERROR: No connected outputs detected. Exiting.."
    exit 1
fi

if [ "$OUTPUT_NUMBER" -gt "${#OUTPUTS[@]}" ]; then
    OUTPUT_NUMBER=${#OUTPUTS[@]}
fi
bashio::log.info "Connected video outputs: (Selected output marked with '*')"
for i in "${!OUTPUTS[@]}"; do
    marker=" "
    [ "$i" -eq "$((OUTPUT_NUMBER - 1))" ] && marker="*"
    bashio::log.info "  ${marker}[$((i + 1))] ${OUTPUTS[$i]}"
done
OUTPUT_NAME="${OUTPUTS[$((OUTPUT_NUMBER - 1))]}"

for OUTPUT in "${OUTPUTS[@]}"; do
    if [ "$OUTPUT" = "$OUTPUT_NAME" ]; then
        if [ "$ROTATE_DISPLAY" = normal ]; then
            xrandr --output "$OUTPUT_NAME" --primary --auto
        else
            xrandr --output "$OUTPUT_NAME" --primary --rotate "${ROTATE_DISPLAY}"
            bashio::log.info "Rotating $OUTPUT_NAME: ${ROTATE_DISPLAY}"
        fi
    else
        xrandr --output "$OUTPUT" --off
    fi
done

if [ "$MAP_TOUCH_INPUTS" = true ]; then
    while IFS= read -r id; do
        name=$(xinput list --name-only "$id" 2>/dev/null)
        [[ "${name,,}" =~ (^|[^[:alnum:]_])(touch|touchscreen|stylus)([^[:alnum:]_]|$) ]] || continue
        xinput_line=$(xinput list "$id" 2>/dev/null)
        [[ "$xinput_line" =~ \[(slave|master)[[:space:]]+keyboard[[:space:]]+\([0-9]+\)\] ]] && continue
        props="$(xinput list-props "$id" 2>/dev/null)"
        [[ "$props" = *"Coordinate Transformation Matrix"* ]] ||  continue
        xinput map-to-output "$id" "$OUTPUT_NAME" && RESULT="SUCCESS" || RESULT="FAILED"
        bashio::log.info "Mapping: input device [$id|$name] -->  $OUTPUT_NAME [$RESULT]"
    done < <(xinput list --id-only | sort -n)
fi

setxkbmap "$KEYBOARD_LAYOUT"
export LANG=$KEYBOARD_LAYOUT
bashio::log.info "Setting keyboard layout and language to: $KEYBOARD_LAYOUT"
setxkbmap -query  | sed 's/^/  /'

read -r SCREEN_WIDTH SCREEN_HEIGHT < <(
    xrandr --query --current | grep "^$OUTPUT_NAME " |
    sed -n "s/^$OUTPUT_NAME connected.* \([0-9]\+\)x\([0-9]\+\)+.*$/\1 \2/p"
)

if [[ -n "$SCREEN_WIDTH" && -n "$SCREEN_HEIGHT" ]]; then
    bashio::log.info "Screen: Width=$SCREEN_WIDTH  Height=$SCREEN_HEIGHT"
else
    bashio::log.error "Could not determine screen size for output $OUTPUT_NAME"
fi

if [[ "$ONSCREEN_KEYBOARD" = true && -n "$SCREEN_WIDTH" && -n "$SCREEN_HEIGHT" ]]; then
    if (( SCREEN_WIDTH >= SCREEN_HEIGHT )); then
        MAX_DIM=$SCREEN_WIDTH
        MIN_DIM=$SCREEN_HEIGHT
        ORIENTATION="landscape"
    else
        MAX_DIM=$SCREEN_HEIGHT
        MIN_DIM=$SCREEN_WIDTH
        ORIENTATION="portrait"
    fi

    KBD_ASPECT_RATIO_X10=30
    LAND_HEIGHT=$(( MIN_DIM / 3 ))
    LAND_WIDTH=$(( (LAND_HEIGHT * KBD_ASPECT_RATIO_X10) / 10 ))
    [ $LAND_WIDTH -gt "$MAX_DIM" ] && LAND_WIDTH=$MAX_DIM
    LAND_Y_OFFSET=$(( MIN_DIM - LAND_HEIGHT ))
    LAND_X_OFFSET=$(( (MAX_DIM - LAND_WIDTH) / 2 ))

    PORT_HEIGHT=$(( MAX_DIM / 4 ))
    PORT_WIDTH=$(( (PORT_HEIGHT * KBD_ASPECT_RATIO_X10) / 10 ))
    [ $PORT_WIDTH -gt "$MIN_DIM" ] && PORT_WIDTH=$MIN_DIM
    PORT_Y_OFFSET=$(( MAX_DIM - PORT_HEIGHT ))
    PORT_X_OFFSET=$(( (MIN_DIM - PORT_WIDTH) / 2 ))

    dconf write /org/onboard/layout "'/usr/share/onboard/layouts/Small.onboard'"
    dconf write /org/onboard/theme "'/usr/share/onboard/themes/Blackboard.theme'"
    dconf write /org/onboard/theme-settings/color-scheme "'/usr/share/onboard/themes/Charcoal.colors'"
    dconf write /org/onboard/keyboard/show-click-buttons true

    dconf write /org/onboard/auto-show/enabled true
    dconf write /org/onboard/auto-show/tablet-mode-detection-enabled false
    dconf write /org/onboard/window/force-to-top true
    gsettings set org.gnome.desktop.interface toolkit-accessibility true

    dconf write /org/onboard/window/landscape/height "$LAND_HEIGHT"
    dconf write /org/onboard/window/landscape/width "$LAND_WIDTH"
    dconf write /org/onboard/window/landscape/x "$LAND_X_OFFSET"
    dconf write /org/onboard/window/landscape/y "$LAND_Y_OFFSET"

    dconf write /org/onboard/window/portrait/height "$PORT_HEIGHT"
    dconf write /org/onboard/window/portrait/width "$PORT_WIDTH"
    dconf write /org/onboard/window/portrait/x "$PORT_X_OFFSET"
    dconf write /org/onboard/window/portrait/y "$PORT_Y_OFFSET"

    if [ -f "$ONBOARD_CONFIG_FILE" ]; then
        if [ "$SAVE_ONSCREEN_CONFIG" = true ]; then
            bashio::log.info "Restoring Onboard configuration from '$ONBOARD_CONFIG_FILE'"
            dconf load /org/onboard/ < "$ONBOARD_CONFIG_FILE"
        else
            rm -f "$ONBOARD_CONFIG_FILE"
        fi
    fi

    LOG_MSG=$(
        echo "Onboard keyboard initialized for: $OUTPUT_NAME (${SCREEN_WIDTH}x${SCREEN_HEIGHT}) [$ORIENTATION]"
        echo "  Appearance: Layout=$(dconf read /org/onboard/layout)  Theme=$(dconf read /org/onboard/theme)  Color-Scheme=$(dconf read /org/onboard/theme-settings/color-scheme)"
        echo "  Behavior: Auto-Show=$(dconf read /org/onboard/auto-show/enabled)  Tablet-Mode=$(dconf read /org/onboard/auto-show/tablet-mode-detection-enabled)  Force-to-Top=$(dconf read /org/onboard/window/force-to-top)"
        echo "  Geometry: Height=$(dconf read /org/onboard/window/${ORIENTATION}/height)  Width=$(dconf read /org/onboard/window/${ORIENTATION}/width)  X-Offset=$(dconf read /org/onboard/window/${ORIENTATION}/x)  Y-Offset=$(dconf read /org/onboard/window/${ORIENTATION}/y)"
    )
    bashio::log.info "$LOG_MSG"

    bashio::log.info "Starting Onboard onscreen keyboard"
    onboard &
fi

case "$AUDIO_SINK" in
    hdmi)
        sink=$(pactl list short sinks | awk '/hdmi/ {print $2; exit}')
        ;;
    usb)
        sink=$(pactl list short sinks | awk '/usb|analog/ {print $2; exit}')
        ;;
    none)
        if ! pactl list short sinks | awk '{print $2}' | grep -qx "null"; then
            pactl load-module module-null-sink sink_name=null sink_properties=device.description=Null >/dev/null
        fi
        sink=null
        ;;
    *)
        sink=$(pactl info | awk -F': ' '/Default Sink/ {print $2}')
        if [ -z "$sink" ]; then
            sink=$(pactl list short sinks | awk '{print $2; exit}')
        fi
esac
if [ -n "$sink" ]; then
    if pactl set-default-sink "$sink" >& /dev/null; then
        bashio::log.info "Setting default audio sink to: $sink"
    else
        bashio::log.warning "Failed to set audio sink to: $sink"
    fi
else
    bashio::log.warning "No audio sink available"
fi
echo "Audio Sinks (* = default)"
pactl list short sinks | awk -v def="$sink" '{prefix = ($2 == def) ? "*" : " "; printf "  %s%s\n", prefix, $0}'

bashio::log.info "Starting Mouse & Touch input gesture command parsing..."
python3 -u /mouse_touch_inputs.py  -d 1 -w "$COMMAND_WHITELIST" &

bashio::log.info "Starting HAOSKiosk REST server..."
python3 -u /rest_server.py &

if [ -n "$VNC_SERVER" ]; then
    PRIMARY_DEV="$(ip route show | awk '/^default/ {print $5; exit}')"
    HOST_IP="$(ip route show | sed -n "/\b${PRIMARY_DEV}\b/ s/.* src \([^ ]*\).*/\1/p" | head -1)"
    VNC_PORT=5900

    X11VNC_OPTS="-display :0 -rfbport $VNC_PORT -forever -bg -shared -quiet"

    bashio::log.info "Starting x11vnc server $([[ "$VNC_SERVER" == "-" ]] && echo "WITHOUT" || echo "WITH") password on port $VNC_PORT. Access at: $HOST_IP:$VNC_PORT"

    if [ "$VNC_SERVER" != "-" ]; then
        VNC_PASSWD_FILE="/root/x11vnc.pass"
        printf '%s\n%s\ny\n' "${VNC_SERVER}" "${VNC_SERVER}" | x11vnc -storepasswd "$VNC_PASSWD_FILE" > /dev/null 2>&1
        chown root:root "$VNC_PASSWD_FILE"
        chmod 600 "$VNC_PASSWD_FILE"
        X11VNC_OPTS="$X11VNC_OPTS -rfbauth $VNC_PASSWD_FILE"
    else
        X11VNC_OPTS="$X11VNC_OPTS -nopw"
    fi

    x11vnc $X11VNC_OPTS 2> >(grep -v 'The VNC desktop is:' >&2)
fi

if [ "$DEBUG_MODE" != true ]; then
    $BROWSER ${BROWSER_FLAGS:+$BROWSER_FLAGS} "$HA_URL/$HA_DASHBOARD" &
    bashio::log.info "Launching $BROWSER browser(PID=$!): $HA_URL/$HA_DASHBOARD"

    count=0
    while true; do
        if pgrep -f -- "^$BROWSER " > /dev/null 2>&1; then
            count=0
        else
            count=$((count + 1))
        fi
        [ $count -ge 3 ] && break
        sleep 5
    done
    bashio::log.info "No $BROWSER instances remaining... exiting 'run.sh'..."

else
    bashio::log.info "Entering debug mode (X & $WINMGR window manager but no $BROWSER browser)..."
    exec sleep infinite
fi
