#!/bin/zsh
# Builds a notarized SoundBin release and publishes it, with its Sparkle update feed, as a GitHub release.
# The release is a disk image with an Applications shortcut; people download it, and Sparkle updates from it.
#
#   Tools/release.sh [--dry-run] [release-notes.md]
#
# The Markdown release notes appear in Sparkle's update window and on the GitHub release page.
# Nothing is published until you confirm at the end. --dry-run does everything except publishing,
# including signing and notarizing, and works with uncommitted changes, to test a release first.
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
#
# The disk image's window (background and icon layout) comes from Tools/dmg. It's made with dmgbuild,
# which the script installs into build/tools on first use, using the Python 3 that comes with Xcode.

set -euo pipefail
cd "${0:A:h}/.."

REPO=RocketBill/SoundBin
TEAM=KU39H5GRDS
NOTARY_PROFILE=SoundBin
OUT=build/release
DRY_RUN=false
if [[ ${1:-} == --dry-run ]]; then
    DRY_RUN=true
    shift
fi
NOTES=${1:-}

fail() { print -u2 "\nerror: $1"; exit 1 }
step() { print "\n==> $1" }

# Submits a file to Apple's notary service and waits for the verdict, printing Apple's log if it's rejected.
notarize() {
    local result notary_status
    result=$(xcrun notarytool submit $1 --keychain-profile $NOTARY_PROFILE --wait --output-format json)
    notary_status=$(print -r -- $result | plutil -extract status raw -o - -)
    if [[ $notary_status != Accepted ]]; then
        xcrun notarytool log $(print -r -- $result | plutil -extract id raw -o - -) --keychain-profile $NOTARY_PROFILE || true
        fail "Notarizing ${1:t} finished with status '$notary_status'."
    fi
}

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
if $DRY_RUN; then
    print "Dry run: uncommitted changes are allowed, and nothing will be published."
else
    [[ -z $(git status --porcelain) ]] || fail "There are uncommitted changes. Commit them first, so the release matches a commit."
    git fetch --quiet origin
    [[ $(git rev-parse HEAD) == $(git rev-parse '@{u}') ]] || fail "This branch isn't in step with origin. Push or pull first."
fi
if gh release view $TAG --repo $REPO >/dev/null 2>&1; then
    fail "$TAG has already been released. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION."
fi

step "Checking signing and notarization"
IDENTITY=$(security find-identity -v -p codesigning | awk "/Developer ID Application/ && /\\($TEAM\\)/ { print \$2; exit }")
[[ -n $IDENTITY ]] || fail "No Developer ID Application certificate for team $TEAM. See the setup notes at the top of this script."
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
    -destination 'generic/platform=macOS' \
    -archivePath $OUT/SoundBin.xcarchive -derivedDataPath $OUT/DerivedData -quiet

step "Signing with Developer ID"
xcodebuild -exportArchive -archivePath $OUT/SoundBin.xcarchive \
    -exportOptionsPlist Tools/ExportOptions.plist -exportPath $OUT/export -quiet
APP=$OUT/export/SoundBin.app
codesign --verify --deep --strict $APP
# The sandboxed app relies on Sparkle's downloader for network access. Sparkle ships it unsandboxed;
# if it were ever signed with a sandbox, it would also need the network entitlement.
downloader=$(codesign -d --entitlements - --xml $APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc 2>/dev/null)
if [[ $downloader == *com.apple.security.app-sandbox* && $downloader != *com.apple.security.network.client* ]]; then
    fail "Sparkle's downloader is sandboxed without network access, so updates couldn't download."
fi

step "Notarizing the app (usually a few minutes)"
# Stapling the app as well as the disk image lets it pass Gatekeeper offline once it's copied out.
ditto -c -k --keepParent $APP $OUT/notarize.zip
notarize $OUT/notarize.zip
xcrun stapler staple $APP
spctl --assess --type execute $APP || fail "Gatekeeper rejected the notarized app."

step "Making the disk image"
# An app opened straight from a download runs from a temporary copy that Sparkle can't update.
# The disk image's window shows people to drag SoundBin into Applications instead.
[[ ! -e /Volumes/SoundBin ]] \
    || fail "Eject the disk called SoundBin first. The new disk image is briefly mounted under that name while its window is laid out."
DMGBUILD=build/tools/dmgbuild
if [[ ! -x $DMGBUILD/bin/dmgbuild ]]; then
    python3 -m venv $DMGBUILD
    $DMGBUILD/bin/pip install --quiet --disable-pip-version-check dmgbuild==1.6.5
fi
DMG=$OUT/updates/SoundBin-$VERSION.dmg
$DMGBUILD/bin/dmgbuild -s Tools/dmg/settings.py -D app=$APP SoundBin $DMG >/dev/null
codesign --sign $IDENTITY --timestamp $DMG
[[ -z $NOTES ]] || cp $NOTES $OUT/updates/SoundBin-$VERSION.md

step "Notarizing the disk image"
notarize $DMG
xcrun stapler staple $DMG
spctl --assess --type open --context context:primary-signature $DMG || fail "Gatekeeper rejected the disk image."

step "Signing the update feed"
$SPARKLE_BIN/generate_appcast \
    --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    $OUT/updates
# generate_appcast only warns when it can't sign an update, so make sure it did.
grep -q "SoundBin-$VERSION.dmg\"[^>]*sparkle:edSignature=" $OUT/updates/appcast.xml \
    || fail "The new update in appcast.xml isn't signed, so Sparkle would refuse to install it."

if $DRY_RUN; then
    print "\nDry run finished. The notarized app and signed feed for $VERSION ($BUILD_NUMBER) are in $OUT."
    exit 0
fi

step "Ready to publish SoundBin $VERSION ($BUILD_NUMBER)"
print "This creates the public GitHub release $TAG, and every copy of SoundBin will be offered it."
if ! read -q "?Publish now? [y/N] "; then
    print "\nNot published. Everything is in $OUT."
    exit 0
fi
print

notes_args=(--generate-notes)
[[ -z $NOTES ]] || notes_args=(--notes-file $NOTES)
gh release create $TAG $DMG $OUT/updates/appcast.xml \
    --repo $REPO --target $(git rev-parse HEAD) --title "SoundBin $VERSION" $notes_args

print "\nReleased $TAG: https://github.com/$REPO/releases/tag/$TAG"
