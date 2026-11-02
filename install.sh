#!/usr/bin/env bash
# Build PhotoCraft from this checkout and install it on this Linux machine:
#
#   ./install.sh                   build (release) and install into /usr (asks for sudo)
#   ./install.sh --skip-build      install what the last build left in $CARGO_TARGET_DIR/release
#   ./install.sh --prefix DIR      install under DIR instead (e.g. ~/.local, no sudo needed)
#   ./install.sh --uninstall       remove what this script installs under the prefix
#
# Installs the same files as the deb/rpm (packaging/linux/package.sh): photocraft and
# photocraft-cli, the desktop entry, MIME types, AppStream metadata and icons, then refreshes the
# desktop, MIME and icon caches. Built like the official packages (`--features heif`). Fonts from
# a craft-fonts checkout next to this repo (../craft-fonts) are built in when present; set
# CRAFT_FONTS_DIR to use another one.
set -euo pipefail
# shellcheck source=packaging/env.sh
. "$(dirname "${BASH_SOURCE[0]}")/packaging/env.sh"
HERE="$ROOT/packaging/linux"
APP_ID=ai.storyteller.photocraft

PREFIX=/usr
SKIP_BUILD=0
UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done
PREFIX="${PREFIX%/}"
[[ -n "$PREFIX" ]] || { echo "error: --prefix must not be /" >&2; exit 2; }

# Run as root only when the prefix isn't writable as this user.
SUDO=()
probe="$PREFIX"
while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
if [[ ! -w "$probe" ]] || { [[ -e "$PREFIX/bin" ]] && [[ ! -w "$PREFIX/bin" ]]; }; then
  SUDO=(sudo)
fi

FILES=(
  "bin/photocraft"
  "bin/photocraft-cli"
  "share/applications/$APP_ID.desktop"
  "share/mime/packages/$APP_ID.xml"
  "share/metainfo/$APP_ID.metainfo.xml"
)
while IFS= read -r icon; do FILES+=("share/icons/hicolor/${icon#"$ROOT/assets/app-icon/hicolor/"}"); done \
  < <(find "$ROOT/assets/app-icon/hicolor" -type f -name "$APP_ID.*")

refresh_caches() {
  local share="$PREFIX/share"
  if command -v update-desktop-database >/dev/null 2>&1; then "${SUDO[@]}" update-desktop-database -q "$share/applications" || true; fi
  if command -v update-mime-database >/dev/null 2>&1; then "${SUDO[@]}" update-mime-database "$share/mime" || true; fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1 && [[ -f "$share/icons/hicolor/index.theme" ]]; then
    "${SUDO[@]}" gtk-update-icon-cache -q -t -f "$share/icons/hicolor" || true
  fi
}

if [[ $UNINSTALL -eq 1 ]]; then
  echo "==> Removing PhotoCraft from $PREFIX"
  for f in "${FILES[@]}"; do "${SUDO[@]}" rm -f "$PREFIX/$f"; done
  refresh_caches
  echo "done"
  exit 0
fi

if [[ $SKIP_BUILD -eq 0 ]]; then
  if [[ -z "${CRAFT_FONTS_DIR:-}" ]] && [[ -d "$ROOT/../craft-fonts" ]]; then
    CRAFT_FONTS_DIR="$(cd "$ROOT/../craft-fonts" && pwd)"
    export CRAFT_FONTS_DIR
  fi
  echo "==> Building PhotoCraft $VERSION (${PHOTOCRAFT_BUILD_SHA:0:9})${CRAFT_FONTS_DIR:+ with fonts from $CRAFT_FONTS_DIR}"
  (cd "$ROOT" && cargo build --release --locked -p photocraft -p photocraft-cli --features heif --bins)
fi

BIN="$CARGO_TARGET_DIR/release"
for b in photocraft photocraft-cli; do
  [[ -x "$BIN/$b" ]] || { echo "error: $BIN/$b is missing; run without --skip-build" >&2; exit 1; }
done

# Stage everything first, so a failure leaves the installed copy untouched.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
install -Dm755 "$BIN/photocraft" "$STAGE/bin/photocraft"
install -Dm755 "$BIN/photocraft-cli" "$STAGE/bin/photocraft-cli"
strip "$STAGE/bin/photocraft" "$STAGE/bin/photocraft-cli" 2>/dev/null || true
install -Dm644 "$HERE/$APP_ID.desktop" "$STAGE/share/applications/$APP_ID.desktop"
install -Dm644 "$HERE/$APP_ID.mime.xml" "$STAGE/share/mime/packages/$APP_ID.xml"
mkdir -p "$STAGE/share/metainfo" "$STAGE/share/icons"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$PHOTOCRAFT_BUILD_DATE/g" \
  "$HERE/$APP_ID.metainfo.xml.in" >"$STAGE/share/metainfo/$APP_ID.metainfo.xml"
cp -R "$ROOT/assets/app-icon/hicolor" "$STAGE/share/icons/"

echo "==> Installing into $PREFIX${SUDO:+ (with sudo)}"
for f in "${FILES[@]}"; do
  mode=644
  [[ $f == bin/* ]] && mode=755
  "${SUDO[@]}" install -Dm"$mode" "$STAGE/$f" "$PREFIX/$f"
done
refresh_caches

if command -v rpm >/dev/null 2>&1 && [[ "$PREFIX" == /usr ]] && owner="$(rpm -qf /usr/bin/photocraft 2>/dev/null)"; then
  echo "note: /usr/bin/photocraft also belongs to the $owner package; updating that package replaces this build"
fi
echo "==> Installed: $("$PREFIX/bin/photocraft-cli" --version 2>/dev/null || echo "$PREFIX/bin/photocraft")"
