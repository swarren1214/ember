#!/usr/bin/env bash
#
# Marketing screenshots for Ember.
#
# Builds the app (Debug) for the Simulator, opens each screen in screenshot mode (demo content,
# no iCloud or network, see Ember/App/ScreenshotMode.swift) and saves:
#
#   screenshots/<device>/<appearance>/NN-<screen>.png   full size, for the App Store and press
#   (no website copies: set WEB below to add them)
#
# Usage:
#   scripts/screenshots.sh                 every screen, light and dark
#   scripts/screenshots.sh home voice   just these screens
#   scripts/screenshots.sh --list-screens   the screen names, in order
#   scripts/screenshots.sh --list-watch-screens   the Apple Watch app's screen names (none: no watch app)
#
# Options (environment variables):
#   DEVICE_TYPE="iPhone 17 Pro Max"   Simulator model. Default: one with the 6.9" screen App Store
#                                     Connect asks for (1320 × 2868), or else the biggest iPhone screen.
#   DEVICE_TYPE="iPad Pro 13-inch (M5)"
#                                     Any Simulator model works, iPads included.
#   DEVICE_TYPE="iPhone Duo"          The foldable: captures its outer display (folded) and its inner
#                                     display (unfolded), in <device>-Outer and <device>-Inner folders.
#                                     Folding uses app-manager/tools/duo-hinge.m (built with clang).
#   DEVICE_TYPE="Apple Watch Ultra 3 (49mm)"
#                                     An Apple Watch: captures the watch app's screens (watchOS is
#                                     always dark). Screen names given are the watch app's.
#   APPEARANCES="light"               "light", "dark" or "light dark" (default).
#   ORIENTATIONS="portrait landscape" "portrait" (default), "landscape" or both. Landscape is
#                                     for iPads (the app is portrait only on iPhone) and saved in
#                                     <appearance>-landscape folders. It turns the Simulator
#                                     through its Device menu, which needs Accessibility access.
#   SHUTDOWN=1                        Shut the Simulator down when done.
#   WARMUP=12                         Seconds the warm-up launch gets before capturing starts.
#   FIRST_EXTRA=4                     Extra seconds for the first screen after an appearance change,
#                                     a rotation or a fold.
#   PAGE_PAUSE=2                      Extra seconds after each screen's settle time, before capturing.
#   STILL_MAX=8                       Then captures a second apart until two match (the screen has
#                                     stopped moving), for at most this many seconds.
#   SHOT_EVENTS=1                     Also print @@SHOT progress lines (Hearth Ship reads them).
#   SKIP_BUILD=1                      Reuse the last build.
#   WEB_WIDTH=720                     Width of the website copies, in pixels.
#   TEXT_SIZE=accessibility-extra-extra-extra-large
#                                     Capture at another text size, to check large-text layouts. Any
#                                     size the Simulator knows (extra-small … extra-extra-extra-large,
#                                     accessibility-medium … accessibility-extra-extra-extra-large).
#                                     Saved in a folder of its own; no website copies.
#
# Needs Xcode and its command line tools. Uses its own Simulator ("Ember Screenshots"), so
# your other simulators and their data are untouched.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# MARK: This app

APP_NAME="Ember"
PROJECT="$ROOT/Ember.xcodeproj"
SCHEME="Ember"
BUNDLE_ID="com.stephenwarren.ember"
PRODUCT="Ember.app"
# Launch arguments that turn on screenshot mode; the screen name follows SCREEN_ARGUMENT.
MODE_ARGUMENT="-Screenshots"
SCREEN_ARGUMENT="-Screen"
# Where resized copies go for a website ("" for none): <screen>.png from light mode, and with
# WEB_DARK=1 also <screen>-dark.png from dark mode, for a site with a dark theme.
WEB=""
WEB_DARK=""

# Screens in the order they're numbered, and how long each needs to settle (seconds).
ALL_SCREENS=(home conversation voice voiceanswer)
settle_time() {
  case "$1" in
    voice|voiceanswer) echo 6 ;;                       # the voice screen slides up over Home
    *) echo 4 ;;
  esac
}

# The Apple Watch app ("" when there isn't one): its bundle id, its product (inside
# $PRODUCT/Watch), and its screens in order, opened with -Screenshots -Screen <name>.
WATCH_BUNDLE_ID="com.stephenwarren.ember.watchkitapp"
WATCH_PRODUCT="EmberWatch.app"
WATCH_SCREENS=(face listening answer)
watch_settle_time() {
  case "$1" in
    *) echo 4 ;;
  esac
}

# Real recipe photos for the demo recipes: a list of demo recipe ids and production recipe
# ids ("" for none). See MARK: Recipe photos.
PHOTOS=""

# MARK: Setup

DERIVED="$ROOT/build/screenshots"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$PRODUCT"
OUT="$ROOT/screenshots"
SIM_NAME="$APP_NAME Screenshots"
APPEARANCES="${APPEARANCES:-light dark}"
TEXT_SIZE="${TEXT_SIZE:-}"
WEB_WIDTH="${WEB_WIDTH:-720}"
ORIENTATIONS="${ORIENTATIONS:-portrait}"
WARMUP="${WARMUP:-12}"
FIRST_EXTRA="${FIRST_EXTRA:-4}"
PAGE_PAUSE="${PAGE_PAUSE:-2}"
STILL_MAX="${STILL_MAX:-8}"
# Turns the Simulator's landscape screenshots upright, when simctl saves them sideways
# (sips rotates clockwise by this many degrees). Only used when a capture comes out portrait.
LANDSCAPE_ROTATION="${LANDSCAPE_ROTATION:-270}"
# The same for the iPhone Duo's inner display, which is landscape natively: only used when
# its capture comes out wider than tall.
DUO_INNER_ROTATION="${DUO_INNER_ROTATION:-90}"
PHOTO_API="${PHOTO_API:-https://api.hearthapps.com}"

case "${1:-}" in
  --list-screens) printf '%s\n' "${ALL_SCREENS[@]}"; exit 0 ;;
  --list-watch-screens)
    if [[ -n "$WATCH_BUNDLE_ID" && ${#WATCH_SCREENS[@]} -gt 0 ]]; then printf '%s\n' "${WATCH_SCREENS[@]}"; fi
    exit 0 ;;
esac
for orientation in $ORIENTATIONS; do
  [[ "$orientation" == portrait || "$orientation" == landscape ]] || { echo "Unknown orientation: $orientation (portrait or landscape)" >&2; exit 1; }
done

# An Apple Watch run captures the watch app's own screens.
WATCH=""
if [[ "${DEVICE_TYPE:-}" == "Apple Watch"* ]]; then
  WATCH=1
  if [[ -z "$WATCH_BUNDLE_ID" || ${#WATCH_SCREENS[@]} -eq 0 ]]; then
    echo "$APP_NAME has no Apple Watch app to capture." >&2
    exit 1
  fi
  CATALOG=("${WATCH_SCREENS[@]}")
  APPEARANCES="dark"   # watchOS is always dark
  LAUNCH_ID="$WATCH_BUNDLE_ID"
  LAUNCH_MODE="-Screenshots"
  LAUNCH_SCREEN="-Screen"
else
  CATALOG=("${ALL_SCREENS[@]}")
  LAUNCH_ID="$BUNDLE_ID"
  LAUNCH_MODE="$MODE_ARGUMENT"
  LAUNCH_SCREEN="$SCREEN_ARGUMENT"
fi

if [[ $# -gt 0 ]]; then SCREENS=("$@"); else SCREENS=("${CATALOG[@]}"); fi
for screen in "${SCREENS[@]}"; do
  [[ " ${CATALOG[*]} " == *" $screen "* ]] || { echo "Unknown screen: $screen (choose from: ${CATALOG[*]})" >&2; exit 1; }
done

settle() {
  if [[ -n "$WATCH" ]]; then watch_settle_time "$1"; else settle_time "$1"; fi
}

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Progress lines for Hearth Ship (SHOT_EVENTS=1): @@SHOT<tab>event<tab>fields…
event() {
  [[ -n "${SHOT_EVENTS:-}" ]] || return 0
  local IFS=$'\t'
  printf '@@SHOT\t%s\n' "$*"
}

# MARK: Simulator

json() { xcrun simctl list "$1" -j; }

# Helpers in Python, written to files rather than inline: macOS's bash 3.2 misreads Python
# (comments, quotes, parentheses) inside $( ... ).
HELPERS="$(mktemp -d)"
UDID=""
ROTATED=""
UNFOLDED=""
HINGE=""
SHUTDOWN_AFTER="${SHUTDOWN:-}"
cleanup() {
  trap '' TERM INT   # a second stop signal mustn't cut the cleanup short
  if [[ -n "$ROTATED" ]]; then rotate portrait || true; fi
  if [[ -n "$UNFOLDED" ]]; then fold closed || true; fi
  if [[ -n "$UDID" ]]; then
    xcrun simctl terminate "$UDID" "$LAUNCH_ID" 2>/dev/null || true
    if [[ -n "$SHUTDOWN_AFTER" ]]; then xcrun simctl shutdown "$UDID" 2>/dev/null || true; fi
  fi
  rm -rf "$HELPERS"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# Turns the Simulator window with this device (the one `open -a Simulator` just brought
# forward) to portrait or landscape, through the Simulator's Device menu. macOS asks once to
# let Hearth Ship (or Terminal) control the computer for this: System Settings › Privacy &
# Security › Accessibility.
rotate() {
  local item
  if [[ "$1" == landscape ]]; then
    [[ -z "$ROTATED" ]] || return 0
    item="Rotate Left"
  else
    [[ -n "$ROTATED" ]] || return 0
    item="Rotate Right"
  fi
  open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
  sleep 1
  if ! osascript \
      -e 'tell application "Simulator" to activate' \
      -e "tell application \"System Events\" to tell process \"Simulator\" to click menu item \"$item\" of menu \"Device\" of menu bar 1" \
      >/dev/null 2>&1; then
    echo "Couldn't turn the Simulator ($item). Allow control in System Settings › Privacy & Security › Accessibility, then try again." >&2
    return 1
  fi
  if [[ "$1" == landscape ]]; then ROTATED=1; else ROTATED=""; fi
  sleep 2   # the rotation animates
}

# Folds or unfolds the iPhone Duo ("closed" shows the outer display, "flat" the inner one).
# Xcode has no command for this, so it uses duo-hinge (app-manager/tools/duo-hinge.m), which
# sends the Simulator the same message Device Hub's fold controls do. It's built with clang
# the first time. DUO_HINGE can point at another build of it.
fold() {
  if [[ -z "$HINGE" ]]; then
    if [[ -n "${DUO_HINGE:-}" ]]; then
      HINGE="$DUO_HINGE"
    else
      local source="$ROOT/../app-manager/tools/duo-hinge.m"
      local cache="$HOME/Library/Caches/HearthShip"
      HINGE="$cache/duo-hinge"
      if [[ ! -f "$source" ]]; then
        echo "Can't fold the iPhone Duo: $source is missing." >&2
        HINGE=""
        return 1
      fi
      if [[ ! -x "$HINGE" || "$source" -nt "$HINGE" ]]; then
        mkdir -p "$cache"
        if ! clang -fobjc-arc -framework Foundation -o "$HINGE" "$source" >&2; then
          echo "Can't fold the iPhone Duo: duo-hinge didn't build." >&2
          HINGE=""
          return 1
        fi
      fi
    fi
  fi
  if ! "$HINGE" -d "$UDID" "$1" >/dev/null; then
    echo "Couldn't set the iPhone Duo's hinge ($1)." >&2
    return 1
  fi
  if [[ "$1" == closed ]]; then UNFOLDED=""; else UNFOLDED=1; fi
  sleep 3   # the fold animates, and the app moves to the other display
}

# One capture of the screen into $1. On the iPhone Duo, $2 picks the display: "inner" (the
# big one, shown when unfolded) or the outer one by default.
shot() {
  local file="$1" display="${2:-}"
  if [[ "$display" == inner ]]; then
    xcrun simctl io "$UDID" screenshot --type=png --display=primary-1 "$file" >/dev/null 2>&1 ||
      xcrun simctl io "$UDID" screenshot --type=png --display=3 "$file" >/dev/null 2>&1
  else
    xcrun simctl io "$UDID" screenshot --type=png "$file" >/dev/null 2>&1
  fi
}

# Saves the screen to $1 once it has stopped changing: captures a second apart until two
# match, so a page still sliding in, a sheet still rising or a photo still fading in isn't
# caught halfway. Gives up after STILL_MAX seconds (something on screen keeps moving) and
# keeps the last capture.
capture_still() {
  local file="$1" display="${2:-}" previous="$HELPERS/still-a.png" next="$HELPERS/still-b.png" waited=0
  rm -f "$previous" "$next"
  shot "$previous" "$display" || true
  while (( waited < STILL_MAX )); do
    sleep 1
    waited=$((waited + 1))
    shot "$next" "$display" || continue
    if [[ -s "$previous" ]] && cmp -s "$previous" "$next"; then break; fi
    mv -f "$next" "$previous"
  done
  [[ -s "$previous" ]] || return 1
  mv -f "$previous" "$file"
  rm -f "$next"
  if (( waited >= STILL_MAX )); then echo "  (still moving after ${STILL_MAX}s; kept the last capture)"; fi
  return 0
}

cat > "$HELPERS/pick.py" <<'PY'
import json, os, plistlib, re, sys

# Picks the Simulator runtime and model. Every installed runtime for the platform is considered,
# newest first, because a runtime made for one new device (an iOS x.1 built only for a new
# model) may support nothing else. Choice: DEVICE_TYPE if given; otherwise a model with the
# 6.9-inch App Store screen (1320 x 2868) or the biggest tall iPhone screen, when Xcode reports
# sizes; otherwise the highest-numbered Pro Max.
platform = os.environ.get("PLATFORM") or "iOS"
runtimes_text, types_text = sys.stdin.read().split("<<SPLIT>>")
runtimes = [r for r in json.loads(runtimes_text)["runtimes"] if r.get("platform") == platform and r.get("isAvailable")]
if not runtimes:
    print("ERROR\tNo " + platform + " Simulator runtime is installed. Add one in Xcode > Settings > Components.")
    sys.exit()
runtimes.sort(key=lambda r: [int(p) for p in re.findall(r"\d+", r.get("version", "0"))], reverse=True)
listed = {t["identifier"]: t for t in json.loads(types_text)["devicetypes"]}


def models(runtime, kind="iPhone"):
    # kind="" matches every model (DEVICE_TYPE may name an iPad or a watch).
    supported = runtime.get("supportedDeviceTypes")
    if supported is None:
        return [t for t in listed.values() if kind in t.get("name", "")]
    return [listed.get(t["identifier"], t) for t in supported if kind in t.get("name", "")]


def screen(t):
    try:
        with open(os.path.join(t.get("bundlePath", ""), "Contents/Resources/profile.plist"), "rb") as f:
            profile = plistlib.load(f)
        w, h = int(profile["mainScreenWidth"]), int(profile["mainScreenHeight"])
        return (min(w, h), max(w, h))
    except Exception:
        return (0, 0)


def tall(t):
    w, h = screen(t)
    return w > 0 and h / w > 2.0


def number(t):
    return [int(n) for n in re.findall(r"\d+", t["name"])] or [0]


def choose():
    wanted = os.environ.get("DEVICE_TYPE")
    if wanted:
        for runtime in runtimes:
            for t in models(runtime, ""):
                if t["name"] == wanted:
                    return runtime, t
        return None
    # By screen size, where Xcode tells us: the 6.9-inch App Store size, else the biggest tall screen.
    for runtime in runtimes:
        exact = [t for t in models(runtime) if screen(t) == (1320, 2868)]
        if exact:
            return runtime, exact[-1]
    for runtime in runtimes:
        candidates = sorted([t for t in models(runtime) if tall(t)], key=lambda t: screen(t)[0] * screen(t)[1])
        if candidates:
            return runtime, candidates[-1]
    # Otherwise by name: the highest-numbered Pro Max (the largest regular iPhone each year).
    for runtime in runtimes:
        candidates = sorted([t for t in models(runtime) if t["name"].endswith("Pro Max")], key=number)
        if candidates:
            return runtime, candidates[-1]
    return None

picked = choose()
if picked:
    runtime, model = picked
    size = screen(model)
    print("OK\t" + runtime["identifier"] + "\t" + model["identifier"] + "\t" + model["name"] + "\t"
          + ("%d x %d" % size if size[0] else "size unknown"))
else:
    lines = []
    for runtime in runtimes:
        names = ", ".join(sorted({t["name"] for t in models(runtime, "" if os.environ.get("DEVICE_TYPE") else "iPhone")})) or "none"
        lines.append("  " + platform + " " + runtime.get("version", "?") + ": " + names)
    wanted = os.environ.get("DEVICE_TYPE")
    print("ERROR\t" + ((wanted + " isn't available") if wanted else "No regular iPhone model found")
          + " in your installed Simulator runtimes:\n" + "\n".join(lines)
          + "\nAdd a " + platform + " runtime in Xcode > Settings > Components, or pass DEVICE_TYPE=\"<one of these>\".")
PY

cat > "$HELPERS/udid.py" <<'PY'
import json, os, sys
devices = json.load(sys.stdin)["devices"].get(os.environ["RUNTIME"], [])
print(next((d["udid"] for d in devices if d["name"] == os.environ["SIM"] and d.get("isAvailable")), ""))
PY

cat > "$HELPERS/image_url.py" <<'PY'
import json, sys
try:
    print(json.load(sys.stdin).get("imageUrl") or "")
except Exception:
    pass
PY

# The runtime and model to run on (see pick.py above).
PLATFORM="iOS"
[[ -n "$WATCH" ]] && PLATFORM="watchOS"
PICK="$( (json runtimes; echo; echo '<<SPLIT>>'; json devicetypes) | PLATFORM="$PLATFORM" DEVICE_TYPE="${DEVICE_TYPE:-}" /usr/bin/python3 "$HELPERS/pick.py")"
if [[ "$PICK" != OK$'\t'* ]]; then echo "${PICK#*$'\t'}" >&2; exit 1; fi
PICK="${PICK#OK$'\t'}"
RUNTIME="${PICK%%$'\t'*}"
DEVICE_TYPE_ID="${PICK#*$'\t'}"
DEVICE_NAME="${DEVICE_TYPE_ID#*$'\t'}"
DEVICE_TYPE_ID="${DEVICE_TYPE_ID%%$'\t'*}"
DEVICE_SIZE="${DEVICE_NAME#*$'\t'}"
DEVICE_NAME="${DEVICE_NAME%%$'\t'*}"
echo "Using $DEVICE_NAME ($DEVICE_SIZE) on ${RUNTIME##*.}"
event device "$DEVICE_NAME" "$DEVICE_SIZE"
SIM="$SIM_NAME ($DEVICE_NAME)"
DUO=""
[[ "$DEVICE_NAME" == *"iPhone Duo"* ]] && DUO=1

UDID="$(json devices | SIM="$SIM" RUNTIME="$RUNTIME" /usr/bin/python3 "$HELPERS/udid.py")"
if [[ -z "$UDID" ]]; then
  log "Creating the \"$SIM\" Simulator"
  UDID="$(xcrun simctl create "$SIM" "$DEVICE_TYPE_ID" "$RUNTIME")"
fi

log "Booting $SIM"
event phase booting
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true

# MARK: Build and install

if [[ -z "${SKIP_BUILD:-}" || ! -d "$APP" ]]; then
  schemes="$(xcodebuild -list -project "$PROJECT" 2>/dev/null | sed -n '/Schemes:/,$p' || true)"
  if ! grep -qx "[[:space:]]*$SCHEME" <<< "$schemes"; then
    echo "The \"$SCHEME\" scheme wasn't found. Open $(basename "$PROJECT") in Xcode once (it creates the scheme)," >&2
    echo "or share it: Product › Scheme › Manage Schemes…, then tick Shared for $SCHEME." >&2
    exit 1
  fi
  # The iPhone app (with its watch app inside). For a watch there's no iPhone Simulator to
  # build for, so it's built for any one.
  destination="platform=iOS Simulator,id=$UDID"
  [[ -n "$WATCH" ]] && destination="generic/platform=iOS Simulator"
  log "Building $APP_NAME (Debug, Simulator)"
  event phase building
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build
fi

log "Installing"
event phase installing
xcrun simctl terminate "$UDID" "$LAUNCH_ID" 2>/dev/null || true
if [[ -n "$WATCH" ]]; then
  WATCH_APP="$APP/Watch/$WATCH_PRODUCT"
  [[ -d "$WATCH_APP" ]] || WATCH_APP="$DERIVED/Build/Products/Debug-watchsimulator/$WATCH_PRODUCT"
  if [[ ! -d "$WATCH_APP" ]]; then
    echo "The watch app wasn't built ($WATCH_PRODUCT isn't inside $PRODUCT). Run without SKIP_BUILD." >&2
    exit 1
  fi
  xcrun simctl install "$UDID" "$WATCH_APP"
  # The watch shows only the time.
  xcrun simctl status_bar "$UDID" override --time "9:41" 2>/dev/null || true
else
  xcrun simctl install "$UDID" "$APP"
  # The status bar Apple uses in its own screenshots.
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" \
    --batteryState charged --batteryLevel 100
fi

# The text size: the one asked for, or the standard one (in case an earlier run changed it).
xcrun simctl ui "$UDID" content_size "${TEXT_SIZE:-large}" 2>/dev/null || [[ -n "$WATCH" ]]

# MARK: Recipe photos

# Real photos for the demo recipes (apps with a PHOTOS list): each comes from a published
# recipe in production, through the Hearth API's public preview endpoint, is cached in
# build/screenshots/photos and is copied into the app's Documents/ScreenshotPhotos, where
# screenshot mode looks for it. PHOTOS_OFF=1 keeps the drawn art; PHOTOS_REFRESH=1 fetches
# every photo again.
if [[ -n "$PHOTOS" && -f "$PHOTOS" && -z "$WATCH" && -z "${PHOTOS_OFF:-}" ]]; then
  log "Fetching recipe photos"
  event phase photos
  cache="$DERIVED/photos"
  mkdir -p "$cache"
  container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
  photos_dir="$container/Documents/ScreenshotPhotos"
  rm -rf "$photos_dir"
  mkdir -p "$photos_dir"
  found=0
  while read -r demo recipe _; do
    [[ -z "$demo" || "$demo" == \#* || -z "$recipe" ]] && continue
    cached="$(ls "$cache/$demo".* 2>/dev/null | head -n 1 || true)"
    if [[ -z "$cached" || -n "${PHOTOS_REFRESH:-}" ]]; then
      url="$(curl -fsS --max-time 15 "$PHOTO_API/v1/bigtable/recipes/$recipe/og" 2>/dev/null | /usr/bin/python3 "$HELPERS/image_url.py" || true)"
      if [[ -n "$url" ]]; then
        ext="$(echo "${url%%\?*}" | sed -E 's/.*\.([A-Za-z0-9]+)$/\1/' | tr '[:upper:]' '[:lower:]')"
        case "$ext" in jpg|jpeg|png|webp|heic) ;; *) ext="jpg" ;; esac
        if curl -fsSL --max-time 30 "$url" -o "$cache/$demo.download" 2>/dev/null; then
          rm -f "$cache/$demo.jpg" "$cache/$demo.jpeg" "$cache/$demo.png" "$cache/$demo.webp" "$cache/$demo.heic"
          mv -f "$cache/$demo.download" "$cache/$demo.$ext"
          # Big enough for the largest card; keeps the app from decoding huge originals.
          sips -Z 1400 "$cache/$demo.$ext" >/dev/null 2>&1 || true
          cached="$cache/$demo.$ext"
        else
          rm -f "$cache/$demo.download"
        fi
      fi
    fi
    if [[ -n "$cached" && -f "$cached" ]]; then
      cp "$cached" "$photos_dir/"
      found=$((found + 1))
    else
      echo "  No photo for $demo (recipe $recipe); it keeps its drawn art."
    fi
  done < "$PHOTOS"
  echo "  $found recipe photos ready"
fi

# A warm-up launch. The first launch after installing is the slowest (cold caches, the
# splash screen stays up longer), and the first screenshot used to catch the splash still
# fading out, tinted in the app's color.
log "Warming up"
event phase warming
xcrun simctl launch "$UDID" "$LAUNCH_ID" "$LAUNCH_MODE" "$LAUNCH_SCREEN" "${SCREENS[0]}" >/dev/null 2>&1 || true
sleep "$WARMUP"
xcrun simctl terminate "$UDID" "$LAUNCH_ID" 2>/dev/null || true

# MARK: Capture

device_dir="$(echo "$DEVICE_NAME" | tr ' ' '-')"
if [[ -n "$WEB" ]]; then WEB="$(mkdir -p "$WEB" && cd "$WEB" && pwd)"; fi

# What each pass captures: the orientations asked for, or on the iPhone Duo its two
# displays (outer folded, inner unfolded), in portrait.
if [[ -n "$DUO" ]]; then
  PASSES="outer inner"
  [[ " $ORIENTATIONS " == *" portrait "* ]] || PASSES=""
  [[ -n "$PASSES" ]] || { echo "The iPhone Duo is captured in portrait. Add portrait to ORIENTATIONS."; event skipped landscape "$DEVICE_NAME"; }
else
  PASSES="$ORIENTATIONS"
fi

for pass in $PASSES; do
  orientation="$pass"
  display=""
  folder="$OUT/$device_dir"
  suffix=""
  case "$pass" in
    landscape)
      if [[ -n "$WATCH" || "$DEVICE_NAME" == iPhone* ]]; then
        echo "Skipping landscape on $DEVICE_NAME: $APP_NAME runs in portrait there."
        event skipped landscape "$DEVICE_NAME"
        continue
      fi
      rotate landscape
      suffix="-landscape"
      ;;
    portrait)
      rotate portrait
      ;;
    outer)
      fold closed || echo "  (couldn't confirm the iPhone Duo is folded; capturing the outer display anyway)"
      folder="$OUT/$device_dir-Outer"
      ;;
    inner)
      if ! fold flat; then
        echo "Skipping the iPhone Duo's inner display: it couldn't be unfolded."
        event skipped inner "$DEVICE_NAME"
        continue
      fi
      display="inner"
      folder="$OUT/$device_dir-Inner"
      ;;
  esac

  for appearance in $APPEARANCES; do
    log "Capturing ($appearance, $orientation)"
    event phase capturing "$appearance" "$orientation"
    [[ -n "$WATCH" ]] || xcrun simctl ui "$UDID" appearance "$appearance"
    dir="$folder/$appearance$suffix${TEXT_SIZE:+-$TEXT_SIZE}"
    mkdir -p "$dir"
    first=1   # the first launch after a rotation, fold or appearance change gets extra time

    for screen in "${SCREENS[@]}"; do
      number=0
      for i in "${!CATALOG[@]}"; do [[ "${CATALOG[$i]}" == "$screen" ]] && number=$((i + 1)); done
      file="$dir/$(printf '%02d' "$number")-$screen.png"

      xcrun simctl terminate "$UDID" "$LAUNCH_ID" 2>/dev/null || true
      xcrun simctl launch "$UDID" "$LAUNCH_ID" "$LAUNCH_MODE" "$LAUNCH_SCREEN" "$screen" >/dev/null
      sleep "$(settle "$screen")"
      if [[ -n "$first" ]]; then sleep "$FIRST_EXTRA"; first=""; fi
      # A pause after the app opens its page, then wait for the screen to stop moving.
      sleep "$PAGE_PAUSE"
      if ! capture_still "$file" "$display"; then
        echo "Couldn't capture $screen." >&2
        exit 1
      fi

      width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')"
      height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')"
      if [[ -n "$width" && -n "$height" ]]; then
        if [[ "$orientation" == landscape && "$height" -gt "$width" ]]; then
          sips --rotate "$LANDSCAPE_ROTATION" "$file" >/dev/null
        elif [[ "$orientation" == inner && "$width" -gt "$height" ]]; then
          sips --rotate "$DUO_INNER_ROTATION" "$file" >/dev/null
        fi
      fi
      echo "  $screen  →  ${file#$ROOT/}"
      event saved "$screen" "$appearance" "$orientation" "$file"

      # Website copies come from a regular iPhone in portrait, at the standard text size.
      if [[ -n "$TEXT_SIZE" || "$orientation" != portrait || "$DEVICE_NAME" != iPhone* || -n "$DUO" ]]; then
        :
      elif [[ -n "$WEB" && "$appearance" == "light" ]]; then
        sips --resampleWidth "$WEB_WIDTH" "$file" --out "$WEB/$screen.png" >/dev/null
      elif [[ -n "$WEB" && -n "$WEB_DARK" && "$appearance" == "dark" ]]; then
        sips --resampleWidth "$WEB_WIDTH" "$file" --out "$WEB/$screen-dark.png" >/dev/null
      fi
    done
  done
done
rotate portrait || true
if [[ -n "$UNFOLDED" ]]; then fold closed || true; fi

xcrun simctl terminate "$UDID" "$LAUNCH_ID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
xcrun simctl ui "$UDID" content_size large 2>/dev/null || true

event done "$OUT"
log "Done"
echo "Full size:  ${OUT#$ROOT/}/"
[[ -n "$WEB" ]] && echo "Website:    $WEB/"
exit 0
