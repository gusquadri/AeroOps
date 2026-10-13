#!/bin/bash
# Builds a notarized AeroOps release: Developer ID archive and export, notarization and
# stapling, the Sparkle update zip and a signed DMG. Then prints the generate_appcast step.
# .github/workflows/release.yml runs it on every vX.Y.Z tag.
#
#   Scripts/release.sh \
#       --identity "Developer ID Application: Jane Doe (VUDQQS32NW)" \
#       --notary-profile aeroops-notary \
#       --feed-url https://example.com/aeroops/appcast.xml \
#       --public-key <SUPublicEDKey from generate_keys -p>
#
#   Scripts/release.sh --dry-run ...   # validate the inputs and print every command, run nothing
#
# This script never sees a secret. Notarization credentials stay in the Keychain under the
# notarytool profile name; the Developer ID private key stays in the Keychain and codesign uses
# it by identity name; the Sparkle private key is only used later, by generate_appcast, which
# reads it from the Keychain. Do not add `set -x`.
#
# Options (each can also come from the environment variable in brackets):
#   --identity NAME          Developer ID Application identity, name or SHA-1 [AEROOPS_SIGNING_IDENTITY]
#   --notary-profile NAME    notarytool keychain profile (store-credentials) [AEROOPS_NOTARY_PROFILE]
#   --notary-keychain PATH   keychain that holds the notarytool profile (default: the search
#                            list; CI uses a temporary one) [AEROOPS_NOTARY_KEYCHAIN]
#   --version X.Y.Z          marketing version (default: MARKETING_VERSION in project.yml) [AEROOPS_VERSION]
#   --build N                build number, compared by Sparkle (default: the number of commits
#                            in HEAD, so it grows with every commit) [AEROOPS_BUILD]
#   --feed-url URL           https appcast URL, becomes SUFeedURL [AEROOPS_FEED_URL]
#   --public-key KEY         Sparkle EdDSA public key, becomes SUPublicEDKey [AEROOPS_SPARKLE_PUBLIC_KEY]
#   --team ID                Apple team ID (default VUDQQS32NW) [AEROOPS_TEAM_ID]
#   --download-url-prefix U  where the update zips are served (default: the feed URL's
#                            directory) [AEROOPS_DOWNLOAD_URL_PREFIX]
#   --sparkle-account NAME   Keychain account of the Sparkle private key, for the printed
#                            generate_appcast step (default app.aeroops) [AEROOPS_SPARKLE_ACCOUNT]
#   --updates-dir DIR        persistent directory of update zips and appcast.xml that
#                            generate_appcast maintains (default build/updates) [AEROOPS_UPDATES_DIR]
#   --output DIR             build output (default build/release)
#   --dry-run                check the inputs, print the commands, run nothing
#   -h, --help               this help

set -euo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# Prints a command in copy-pasteable form, then runs it unless this is a dry run.
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    [ "$dry_run" = 1 ] || "$@"
}

# Like run, with stdout and stderr in a log file (the tail is shown when the command fails).
run_logged() {
    local log=$1; shift
    printf '+'; printf ' %q' "$@"; printf ' > %q 2>&1\n' "$log"
    [ "$dry_run" = 1 ] && return 0
    if ! "$@" > "$log" 2>&1; then
        tail -40 "$log" >&2
        die "failed; full log: $log"
    fi
}

identity=${AEROOPS_SIGNING_IDENTITY:-}
notary_profile=${AEROOPS_NOTARY_PROFILE:-}
notary_keychain=${AEROOPS_NOTARY_KEYCHAIN:-}
version=${AEROOPS_VERSION:-}
build=${AEROOPS_BUILD:-}
feed_url=${AEROOPS_FEED_URL:-}
public_key=${AEROOPS_SPARKLE_PUBLIC_KEY:-}
team=${AEROOPS_TEAM_ID:-VUDQQS32NW}
download_prefix=${AEROOPS_DOWNLOAD_URL_PREFIX:-}
sparkle_account=${AEROOPS_SPARKLE_ACCOUNT:-app.aeroops}
updates_dir=${AEROOPS_UPDATES_DIR:-build/updates}
output=build/release
dry_run=0

while [ $# -gt 0 ]; do
    case $1 in
        --identity) identity=${2:?--identity needs a value}; shift 2 ;;
        --notary-profile) notary_profile=${2:?--notary-profile needs a value}; shift 2 ;;
        --notary-keychain) notary_keychain=${2:?--notary-keychain needs a value}; shift 2 ;;
        --version) version=${2:?--version needs a value}; shift 2 ;;
        --build) build=${2:?--build needs a value}; shift 2 ;;
        --feed-url) feed_url=${2:?--feed-url needs a value}; shift 2 ;;
        --public-key) public_key=${2:?--public-key needs a value}; shift 2 ;;
        --team) team=${2:?--team needs a value}; shift 2 ;;
        --download-url-prefix) download_prefix=${2:?--download-url-prefix needs a value}; shift 2 ;;
        --sparkle-account) sparkle_account=${2:?--sparkle-account needs a value}; shift 2 ;;
        --updates-dir) updates_dir=${2:?--updates-dir needs a value}; shift 2 ;;
        --output) output=${2:?--output needs a value}; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# MARK: Inputs

step "Checking inputs"
if [ "$dry_run" = 1 ]; then
    # A dry run may leave out what only the release machine has.
    [ -n "$identity" ] || { identity="Developer ID Application: <name> ($team)"; note "dry run: placeholder identity"; }
    [ -n "$notary_profile" ] || { notary_profile="<notary-profile>"; note "dry run: placeholder notary profile"; }
    [ -n "$feed_url" ] || { feed_url="https://example.invalid/aeroops/appcast.xml"; note "dry run: placeholder feed URL"; }
    [ -n "$public_key" ] || { public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; note "dry run: placeholder public key"; }
fi
[ -n "$identity" ] || die "missing --identity (a Developer ID Application identity)"
[ -n "$notary_profile" ] || die "missing --notary-profile (see notarytool store-credentials)"
[ -n "$feed_url" ] || die "missing --feed-url"
[ -n "$public_key" ] || die "missing --public-key"

printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$' || die "team ID must be 10 letters or digits: $team"
case $feed_url in
    https://*) ;;
    *) die "the feed URL must be https: $feed_url" ;;
esac
case $feed_url in
    *[[:space:]\"\'\$\`\\]*) die "the feed URL has spaces, quotes or shell characters: $feed_url" ;;
esac
key_bytes=$(printf '%s' "$public_key" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d ' ')
[ "$key_bytes" = 32 ] || die "the public key must be base64 of 32 bytes (generate_keys -p prints it)"
[ -n "$download_prefix" ] || download_prefix="${feed_url%/*}/"
case $download_prefix in
    https://*/) ;;
    *) die "the download URL prefix must be https and end in /: $download_prefix" ;;
esac

[ -n "$version" ] || version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
[ -n "$build" ] || build=$(git rev-list --count HEAD 2> /dev/null || true)
[ -n "$version" ] || die "missing --version and no MARKETING_VERSION in project.yml"
[ -n "$build" ] || die "missing --build and HEAD has no git history to count"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || die "version must look like 1.2.3 or 1.2.3-beta.1: $version"
printf '%s' "$build" | grep -Eq '^[1-9][0-9]*$' || die "build must be a positive integer: $build"
if [ -n "$notary_keychain" ]; then
    [ "$dry_run" = 1 ] || [ -f "$notary_keychain" ] || die "no keychain at $notary_keychain"
    notary_keychain_args=(--keychain "$notary_keychain")
else
    notary_keychain_args=()
fi
note "version $version (build $build), team $team"
note "identity: $identity"
note "notary profile: $notary_profile${notary_keychain:+ (keychain $notary_keychain)}"
note "feed: $feed_url"
note "downloads: $download_prefix"

update_zip="$updates_dir/AeroOps-$version.zip"
[ ! -e "$update_zip" ] || die "$update_zip exists; release a new version (--version or MARKETING_VERSION in project.yml)"
if [ -f "$updates_dir/appcast.xml" ] && grep -q "<sparkle:version>$build</sparkle:version>" "$updates_dir/appcast.xml"; then
    die "build $build is already in $updates_dir/appcast.xml; commit first or pass a larger --build"
fi

step "Checking tools"
for tool in xcodegen xcodebuild codesign ditto hdiutil plutil spctl; do
    command -v "$tool" > /dev/null || die "$tool not found"
done
xcrun --find notarytool > /dev/null || die "notarytool not found (Xcode command line tools)"
xcrun --find stapler > /dev/null || die "stapler not found (Xcode command line tools)"
if [ "$dry_run" = 1 ]; then
    note "dry run: not looking up the signing identity"
else
    security find-identity -v -p codesigning | grep -F -- "$identity" | grep -q "Developer ID Application" \
        || die "no valid Developer ID Application identity matches \"$identity\" (security find-identity -v -p codesigning)"
fi
if [ -n "$(git status --porcelain 2> /dev/null)" ]; then
    note "warning: the working tree has uncommitted changes; the release will include them"
fi

run_dir="$output/run-$(date +%Y%m%d-%H%M%S)"
derived_data="$output/DerivedData"
archive="$run_dir/AeroOps.xcarchive"
export_dir="$run_dir/export"
app="$export_dir/AeroOps.app"
dmg="$run_dir/AeroOps-$version.dmg"
sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
run mkdir -p "$run_dir" "$updates_dir"

# MARK: Build

step "Generating the Xcode project"
run xcodegen generate

step "Archiving (Release, Developer ID)"
run_logged "$run_dir/archive.log" xcodebuild \
    -project AeroOps.xcodeproj -scheme AeroOps -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" -archivePath "$archive" \
    archive \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$identity" \
    "DEVELOPMENT_TEAM=$team" \
    "MARKETING_VERSION=$version" \
    "CURRENT_PROJECT_VERSION=$build" \
    "AEROOPS_FEED_URL=$feed_url" \
    "AEROOPS_SPARKLE_PUBLIC_KEY=$public_key"

step "Exporting with Developer ID"
export_options="$run_dir/ExportOptions.plist"
# Written in dry runs too (it is only a local file), so they show what the export uses.
mkdir -p "$run_dir"
plutil -create xml1 "$export_options"
plutil -insert method -string developer-id "$export_options"
plutil -insert signingStyle -string manual "$export_options"
plutil -insert signingCertificate -string "$identity" "$export_options"
plutil -insert teamID -string "$team" "$export_options"
plutil -insert destination -string export "$export_options"
plutil -p "$export_options" | sed 's/^/    /'
run_logged "$run_dir/export.log" xcodebuild -exportArchive \
    -archivePath "$archive" -exportPath "$export_dir" -exportOptionsPlist "$export_options"

# MARK: Verify

# Fails unless the code at $1 is Developer ID signed by $team, hardened, timestamped and not
# debuggable (no get-task-allow, which notarization rejects).
check_code() {
    local path=$1 info
    info=$(codesign -dvv "$path" 2>&1) || die "$path is not signed"
    printf '%s\n' "$info" | grep -q '^CodeDirectory .*flags=.*runtime' || die "$path lacks the hardened runtime"
    printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application' || die "$path is not signed with Developer ID"
    printf '%s\n' "$info" | grep -qx "TeamIdentifier=$team" || die "$path is not signed by team $team"
    printf '%s\n' "$info" | grep -q '^Timestamp=' || die "$path has no secure timestamp"
    if codesign -d --entitlements - --xml "$path" 2> /dev/null | grep -q 'get-task-allow'; then
        die "$path has com.apple.security.get-task-allow"
    fi
}

verify_app() {
    codesign --verify --deep --strict --verbose=2 "$app"
    # Every Mach-O in the bundle: the app, aeroops-mcp, aeroops-askpass, Sparkle and its helpers.
    local count=0 file
    while IFS= read -r file; do
        case $(file -b "$file") in
            Mach-O*) check_code "$file"; count=$((count + 1)) ;;
        esac
    done < <(find "$app" -type f -perm -u+x)
    check_code "$app"
    note "$count Mach-O files: Developer ID, team $team, hardened runtime, timestamped, no get-task-allow"

    local plist="$app/Contents/Info.plist" value
    value=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")
    [ "$value" = "$feed_url" ] || die "SUFeedURL is \"$value\", expected $feed_url"
    value=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")
    [ "$value" = "$public_key" ] || die "SUPublicEDKey does not match --public-key"
    value=$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$plist")
    [ "$value" = true ] || die "SUEnableAutomaticChecks must be YES"
    value=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
    [ "$value" = "$version" ] || die "the app says version $value, expected $version"
    value=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
    [ "$value" = "$build" ] || die "the app says build $value, expected $build"
    note "Info.plist: feed, public key, automatic checks on, version $version ($build)"

    # The app's bridge only accepts aeroops-mcp signed by the same team with this identifier.
    local cli="$app/Contents/MacOS/aeroops-mcp"
    codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"app.aeroops.mcp\"" "$cli" \
        || die "aeroops-mcp does not satisfy the bridge's peer requirement"
    "$cli" --version > /dev/null || die "aeroops-mcp does not run (code signature or entitlements rejected?)"
    note "aeroops-mcp: satisfies the bridge peer requirement and runs"

    # The askpass server only answers aeroops-askpass signed by the same team with this identifier.
    local askpass="$app/Contents/MacOS/aeroops-askpass"
    codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"app.aeroops.askpass\"" "$askpass" \
        || die "aeroops-askpass does not satisfy the askpass server's peer requirement"
    "$askpass" --version > /dev/null || die "aeroops-askpass does not run (code signature or entitlements rejected?)"
    note "aeroops-askpass: satisfies the askpass peer requirement and runs"
}

step "Verifying the exported app"
if [ "$dry_run" = 1 ]; then
    note "dry run: would check every Mach-O in $app (Developer ID, hardened runtime, timestamp,"
    note "no get-task-allow), the Sparkle Info.plist keys, aeroops-mcp's bridge requirement and"
    note "aeroops-askpass's askpass requirement"
else
    verify_app
fi

# MARK: Notarize

# Submits $1 under the keychain profile and waits; on rejection fetches Apple's log.
notarize() {
    local file=$1 label=$2
    local result="$run_dir/notary-$label.json" log="$run_dir/notary-$label-log.json"
    printf '+ xcrun notarytool submit %q --keychain-profile %q' "$file" "$notary_profile"
    printf ' %q' ${notary_keychain_args[@]+"${notary_keychain_args[@]}"}
    printf ' --wait --output-format json > %q\n' "$result"
    [ "$dry_run" = 1 ] && return 0
    xcrun notarytool submit "$file" --keychain-profile "$notary_profile" ${notary_keychain_args[@]+"${notary_keychain_args[@]}"} \
        --wait --output-format json > "$result" || true
    local id status
    id=$(plutil -extract id raw -o - "$result" 2> /dev/null || true)
    status=$(plutil -extract status raw -o - "$result" 2> /dev/null || echo "no result")
    note "submission ${id:-?}: $status"
    if [ "$status" != Accepted ]; then
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$notary_profile" \
            ${notary_keychain_args[@]+"${notary_keychain_args[@]}"} "$log" || true
        die "notarization of $file: $status (details: $result, $log)"
    fi
}

step "Notarizing the app"
notarize_zip="$run_dir/AeroOps-notarize.zip"
run ditto -c -k --keepParent "$app" "$notarize_zip"
notarize "$notarize_zip" app
run xcrun stapler staple "$app"
run xcrun stapler validate "$app"
run spctl --assess --type execute --verbose=2 "$app"

# MARK: Package

step "Sparkle update archive"
run ditto -c -k --sequesterRsrc --keepParent "$app" "$update_zip"

step "Disk image"
dmg_root="$run_dir/dmg-root"
run mkdir -p "$dmg_root"
run ditto "$app" "$dmg_root/AeroOps.app"
run ln -s /Applications "$dmg_root/Applications"
run hdiutil create -volname AeroOps -srcfolder "$dmg_root" -fs APFS -format ULFO -ov "$dmg"
run codesign --force --sign "$identity" --timestamp "$dmg"
notarize "$dmg" dmg
run xcrun stapler staple "$dmg"
run xcrun stapler validate "$dmg"
run spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

# MARK: Next steps

if [ "$dry_run" = 1 ]; then
    step "Done (dry run: nothing was built, signed or submitted)"
else
    step "Done"
fi
note "disk image (first installs):   $dmg"
note "update archive (Sparkle):      $update_zip"
note "archive, logs, notary results: $run_dir"
cat <<EOF

Next, by hand:

  1. Optional release notes: $updates_dir/AeroOps-$version.md (or .html) next to the zip.
  2. Sign the update and write the appcast. generate_appcast reads the Sparkle private key from
     your login Keychain (account $sparkle_account) and may ask for access:

       $(printf '%q' "$sparkle_bin/generate_appcast") \\
           --account $(printf '%q' "$sparkle_account") \\
           --download-url-prefix $(printf '%q' "$download_prefix") \\
           $(printf '%q' "$updates_dir")

  3. Upload $updates_dir/appcast.xml so it is served at $feed_url, plus the new zip and any
     *.delta files under $download_prefix (not old_updates/).
  4. Publish $dmg for new installs.
  5. Check: an older AeroOps build with this feed finds and installs $version via
     AeroOps > Check for Updates…
EOF
