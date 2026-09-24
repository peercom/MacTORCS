#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 || -z "${TORCS_SIGN_IDENTITY:-}" ]]; then
    echo 'Usage: TORCS_SIGN_IDENTITY="Developer ID Application: …" Scripts/notarize.sh KEYCHAIN_PROFILE' >&2
    exit 2
fi
Scripts/build-app.sh
ditto -c -k --keepParent build/TORCSMac.app build/TORCSMac.zip
xcrun notarytool submit build/TORCSMac.zip --keychain-profile "$1" --wait
xcrun stapler staple build/TORCSMac.app
xcrun stapler validate build/TORCSMac.app
# Repack after stapling so the distributable zip includes the ticket.
ditto -c -k --keepParent build/TORCSMac.app build/TORCSMac.zip
