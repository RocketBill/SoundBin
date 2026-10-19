#!/bin/zsh
# Builds a notarized SoundBin release and publishes it, with its Sparkle update feed, as a GitHub release.
#
#   Tools/release.sh [release-notes.md]
#
# The Markdown release notes appear in Sparkle's update window and on the GitHub release page.
# Nothing is published until you confirm at the end.
#
# Before each release, bump both versions in the project, then commit and push:
#   MARKETING_VERSION        what users see, e.g. 1.1
#   CURRENT_PROJECT_VERSION  a whole number Sparkle compares; it must go up with every release
#
# One-time setup:
#   1. A "Developer ID Application" certificate: Xcode › Settings › Accounts › Manage Certificates › +.
#      Creating one needs the Account Holder or Admin role on the team.
#   2. Notarization credentials saved in the Keychain as the profile "SoundBin", using an
#      app-specific password from account.apple.com:
#        xcrun notarytool store-credentials SoundBin --apple-id <your Apple ID> --team-id KU39H5GRDS
#   3. Sparkle's EdDSA signing key, which is already in your login Keychain. Back it up somewhere safe
#      and offline; if it's lost, copies of SoundBin already out there can never be updated again:
#        build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>
#      (that path exists after the first run; any copy of Sparkle's generate_keys works).
#
# If macOS asks whether Sparkle's tools may use the signing key, choose Always Allow.

set -euo pipefail
cd "${0:A:h}/.."

REPO=RocketBill/SoundBin
NOTARY_PROFILE=SoundBin
OUT=build/release
NOTES=${1:-}

fail() { print -u2 "\nerror: $1"; exit 1 }
step() { print "\n==> $1" }

[[ -z $NOTES || -f $NOTES ]] || fail "Release notes file not found: $NOTES"
[[ -z $NOTES ]] || NOTES=${NOTES:A}

step "Checking versions"
settings=$(xcodebuild -project SoundBin.xcodeproj -target SoundBin -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- $settings | awk -F' = ' '/^ *MARKETING_VERSION = / { print $2; exit }')
BUILD_NUMBER=$(print -r -- $settings | awk -F' = ' '/^ *CURRENT_PROJECT_VERSION = / { print $2; exit }')
PUBLIC_KEY=$(print -r -- $settings | awk -F' = ' '/^ *SPARKLE_PUBLIC_KEY = / { print $2; exit }')
TAG=v$VERSION
[[ $BUILD_NUMBER == <-> ]] || fail "CURRENT_PROJECT_VERSION must be a whole number, not '$BUILD_NUMBER'."
print "SoundBin $VERSION ($BUILD_NUMBER)"

step "Checking the repository"
[[ -z $(git status --porcelain) ]] || fail "There are uncommitted changes. Commit them first, so the release matches a commit."
git fetch --quiet origin
[[ $(git rev-parse HEAD) == $(git rev-parse '@{u}') ]] || fail "This branch isn't in step with origin. Push or pull first."
if gh release view $TAG --repo $REPO >/dev/null 2>&1; then
    fail "$TAG has already been released. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION."
fi

step "Checking signing and notarization"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "No Developer ID Application certificate. See the setup notes at the top of this script."
xcrun notarytool history --keychain-profile $NOTARY_PROFILE >/dev/null 2>&1 \
    || fail "No notarization credentials in the Keychain profile '$NOTARY_PROFILE'. See the setup notes."

rm -rf $OUT
mkdir -p $OUT/updates

step "Checking the update signing key"
xcodebuild -resolvePackageDependencies -project SoundBin.xcodeproj -scheme SoundBin -derivedDataPath $OUT/DerivedData -quiet
SPARKLE_BIN=$OUT/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
keychain_key=$($SPARKLE_BIN/generate_keys -p 2>/dev/null | tail -1)
# A mismatch would publish an update every copy of SoundBin rejects.
[[ $keychain_key == $PUBLIC_KEY ]] \
    || fail "SPARKLE_PUBLIC_KEY in the project doesn't match the Sparkle key in your Keychain ($keychain_key)."

step "Fetching the current update feed"
# generate_appcast adds the new version to the existing feed, so earlier entries are kept.
if curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o $OUT/updates/appcast.xml 2>/dev/null; then
    latest=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' $OUT/updates/appcast.xml | grep -o '[0-9][0-9]*' | sort -n | tail -1)
    (( BUILD_NUMBER > latest )) \
        || fail "CURRENT_PROJECT_VERSION ($BUILD_NUMBER) must be higher than the last release's ($latest), or Sparkle won't offer it."
    print "Previous release is build $latest."
else
    rm -f $OUT/updates/appcast.xml
    print "No feed yet, so this is the first release."
fi

step "Archiving"
xcodebuild archive -project SoundBin.xcodeproj -scheme SoundBin -configuration Release \
    -archivePath $OUT/SoundBin.xcarchive -derivedDataPath $OUT/DerivedData -quiet

step "Signing with Developer ID"
xcodebuild -exportArchive -archivePath $OUT/SoundBin.xcarchive \
    -exportOptionsPlist Tools/ExportOptions.plist -exportPath $OUT/export -quiet
APP=$OUT/export/SoundBin.app
codesign --verify --deep --strict $APP
# The sandboxed app relies on Sparkle's downloader for network access, so it must keep its entitlement.
codesign -d --entitlements - --xml $APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc 2>/dev/null \
    | grep -q com.apple.security.network.client \
    || fail "Sparkle's downloader lost its network entitlement during signing, so updates couldn't download."

step "Notarizing (usually a few minutes)"
ditto -c -k --keepParent $APP $OUT/notarize.zip
result=$(xcrun notarytool submit $OUT/notarize.zip --keychain-profile $NOTARY_PROFILE --wait --output-format json)
notary_status=$(print -r -- $result | plutil -extract status raw -o - -)
if [[ $notary_status != Accepted ]]; then
    submission=$(print -r -- $result | plutil -extract id raw -o - -)
    xcrun notarytool log $submission --keychain-profile $NOTARY_PROFILE || true
    fail "Notarization finished with status '$notary_status'."
fi
xcrun stapler staple $APP
spctl --assess --type execute $APP || fail "Gatekeeper rejected the notarized app."

step "Packaging"
ZIP=$OUT/updates/SoundBin-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
[[ -z $NOTES ]] || cp $NOTES $OUT/updates/SoundBin-$VERSION.md

step "Signing the update feed"
$SPARKLE_BIN/generate_appcast \
    --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    $OUT/updates
# generate_appcast only warns when it can't sign an update, so make sure it did.
grep -q "SoundBin-$VERSION.zip\"[^>]*sparkle:edSignature=" $OUT/updates/appcast.xml \
    || fail "The new update in appcast.xml isn't signed, so Sparkle would refuse to install it."

step "Ready to publish SoundBin $VERSION ($BUILD_NUMBER)"
print "This creates the public GitHub release $TAG, and every copy of SoundBin will be offered it."
if ! read -q "?Publish now? [y/N] "; then
    print "\nNot published. Everything is in $OUT."
    exit 0
fi
print

notes_args=(--generate-notes)
[[ -z $NOTES ]] || notes_args=(--notes-file $NOTES)
gh release create $TAG $ZIP $OUT/updates/appcast.xml \
    --repo $REPO --target $(git rev-parse HEAD) --title "SoundBin $VERSION" $notes_args

print "\nReleased $TAG: https://github.com/$REPO/releases/tag/$TAG"
