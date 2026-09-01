#!/usr/bin/env bash
set -euo pipefail

# FoodTruck's PRODUCER for the stuffbucket/macos-builder pipeline.
#
# CONTRACT (see macos-builder README, "Shared contract"):
#   Build the .app and leave it at the config's `app_path` (dist/FoodTruck.app).
#   That is ALL. This script must NOT sign the top-level bundle, build a
#   .dmg/.pkg, notarize, staple, or write to $OUTPUT_DIR — the builder owns that
#   entire tail via lib/package-macos.sh. It is never handed APPLE_* or
#   KEYCHAIN_PASSWORD.
#
#   Unlike an Electron app (nested Helper apps + frameworks needing inside-out
#   signing), FoodTruck is a single flat Mach-O executable, so there is nothing
#   to inner-sign here. The builder's top-level sign is sufficient, and this
#   producer deliberately never invokes codesign at all.
#
# Builder-supplied env consumed: TAG, ARCH.
# Runnable standalone for local verification:
#     TAG=v0.0.0-local ./.macos-builder/build.sh
# so the code path proven on a laptop is byte-identical to the one the signing
# Mac runs.

TAG="${TAG:?TAG is required (e.g. v0.1.0)}"
ARCH="${ARCH:-arm64}"

# 0.1.0-rc.1 -> VERSION=0.1.0-rc.1, NUMERIC=0.1.0.
# CFBundleShortVersionString / CFBundleVersion must be 1-3 dot-separated
# integers or notarization rejects the bundle, so the plist gets NUMERIC while
# the human-facing tag may carry a prerelease suffix.
VERSION="${TAG#v}"
NUMERIC="${VERSION%%-*}"

if ! printf '%s' "$NUMERIC" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then
  echo "::error::Tag '${TAG}' does not yield a valid CFBundleVersion (got '${NUMERIC}')." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/FoodTruck.app"
MACOS_DIR="${APP}/Contents/MacOS"
RES_DIR="${APP}/Contents/Resources"

echo "Producing FoodTruck.app for ${TAG} (version ${NUMERIC}, ${ARCH})"

# The builder's runner reuses its workspace across builds; never trust a stale
# dist/ to have been regenerated from the current tag.
rm -rf dist
mkdir -p "$MACOS_DIR" "$RES_DIR"

# Pin the deployment target to LSMinimumSystemVersion so the binary cannot
# silently require a newer macOS than the plist advertises.
swiftc \
  -O \
  -target "${ARCH}-apple-macos12.0" \
  -framework AppKit \
  -o "${MACOS_DIR}/FoodTruck" \
  src/main.swift

cp src/Info.plist "${APP}/Contents/Info.plist"

# Stamp the release version, then ASSERT the stamp took — a silently unstamped
# bundle would ship as 0.0.0.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NUMERIC}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NUMERIC}" "${APP}/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Assert the bundle before handing it to the builder. Failing here is far
# cheaper than failing after notarization.
# ---------------------------------------------------------------------------
plutil -lint "${APP}/Contents/Info.plist"

BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")"
if [ "$BUILT_ID" != "co.stuffbucket.foodtruck" ]; then
  echo "::error::CFBundleIdentifier '${BUILT_ID}' != co.stuffbucket.foodtruck (the builder's policy gate would reject this)." >&2
  exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$NUMERIC" ]; then
  echo "::error::Bundle version '${BUILT_VERSION}' != '${NUMERIC}'. Stale build?" >&2
  exit 1
fi

if [ ! -x "${MACOS_DIR}/FoodTruck" ]; then
  echo "::error::Executable missing or not executable at ${MACOS_DIR}/FoodTruck" >&2
  exit 1
fi

file "${MACOS_DIR}/FoodTruck"
echo "Bundle id:      ${BUILT_ID}"
echo "Bundle version: ${BUILT_VERSION}"
ls -la "${APP}/Contents"

echo "Producer done — ${APP} is ready for the builder (sign -> dmg -> notarize -> staple -> sha256)."
