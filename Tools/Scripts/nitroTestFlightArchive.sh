#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || ! $1 =~ ^[0-9]+$ ]]; then
    echo "Usage: $0 <build-number>" >&2
    exit 2
fi

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_directory/../.." && pwd)
build_number=$1
build_root=${NITRO_TESTFLIGHT_BUILD_ROOT:-"$HOME/Builds/ElementX-TestFlight"}
build_directory="$build_root/$build_number"
archive_path="$build_directory/ElementX.xcarchive"
derived_data_path=${NITRO_TESTFLIGHT_DERIVED_DATA_PATH:-"$HOME/Library/Developer/Xcode/DerivedData/NitroElementXRelease"}
authentication_key_path=${NITRO_ASC_AUTH_KEY_PATH:-"$HOME/.appstoreconnect/private_keys/AuthKey_XNG7V5KX5G.p8"}
authentication_key_id=${NITRO_ASC_AUTH_KEY_ID:-XNG7V5KX5G}
authentication_key_issuer_id=${NITRO_ASC_AUTH_KEY_ISSUER_ID:-69a6de6e-8710-47e3-e053-5b8c7c11a4d1}
signing_keychain=${NITRO_SIGNING_KEYCHAIN:-"$HOME/Library/Keychains/element-nitro-build.keychain-db"}
signing_password_file=${NITRO_SIGNING_PASSWORD_FILE:-"$HOME/.config/element-nitro-release/signing-keychain-password"}
marketing_version=${NITRO_MARKETING_VERSION:-$(sed -n 's/^[[:space:]]*MARKETING_VERSION: //p' "$repository_root/project.yml" | head -1)}

if [[ -e $archive_path ]]; then
    echo "Archive already exists: $archive_path" >&2
    exit 2
fi

if [[ ! -f $authentication_key_path ]]; then
    echo "App Store Connect authentication key not found: $authentication_key_path" >&2
    exit 2
fi

if [[ -f $signing_keychain && -f $signing_password_file ]]; then
    security unlock-keychain -p "$(< "$signing_password_file")" "$signing_keychain"
fi

mkdir -p "$build_directory" "$derived_data_path"
cd "$repository_root"

xcodebuild \
    -project ElementX.xcodeproj \
    -scheme ElementX \
    -configuration Release \
    -destination generic/platform=iOS \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data_path" \
    MARKETING_VERSION="$marketing_version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$authentication_key_path" \
    -authenticationKeyID "$authentication_key_id" \
    -authenticationKeyIssuerID "$authentication_key_issuer_id" \
    archive 2>&1 | tee "$build_directory/archive.log"
