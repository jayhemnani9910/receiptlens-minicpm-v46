#!/usr/bin/env bash
set -euo pipefail

APP_PATH="build/DerivedData/Build/Products/Release-iphoneos/ReceiptLens.app"
IPA_PATH="build/ReceiptLens-unsigned.ipa"
PAYLOAD_DIR="build/Payload"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle at $APP_PATH"
  exit 1
fi

rm -rf "$PAYLOAD_DIR" "$IPA_PATH"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"

(
  cd build
  /usr/bin/zip -qry "ReceiptLens-unsigned.ipa" "Payload"
)

echo "Created $IPA_PATH"

