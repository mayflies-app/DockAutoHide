#!/bin/bash
# Sourceable macOS app signing helpers. Compatible with the system Bash 3.2.
# This file does not change the caller's shell options, directory or traps.

macos_signing_resolve() {
    local requested="${1:-}" keychain="${2:-}" required="${3:-0}"
    local identities matches count team_pattern
    local security_args=(find-identity -v -p codesigning)
    MACOS_SIGN_READY=0
    MACOS_SIGN_IDENTITY=""
    MACOS_SIGN_NAME=""
    MACOS_SIGN_TEAM_ID=""
    MACOS_SIGN_KEYCHAIN="$keychain"
    MACOS_SIGN_REQUIREMENT=""
    MACOS_SIGN_VERIFIED_APP=""
    MACOS_SIGN_PREVIOUS_APP=""
    case "$required" in
        0|1) ;;
        *) printf 'require_developer_id must be 0 or 1.\n' >&2; return 1 ;;
    esac
    if [[ "$requested" == - ]]; then
        MACOS_SIGN_IDENTITY=-
    else
        [[ -z "$keychain" ]] || security_args+=("$keychain")
        if ! identities="$(security "${security_args[@]}")"; then
            printf 'Could not query signing identities in the local keychain.\n' >&2
            return 1
        fi
        # ENVIRON preserves backslashes in certificate names, unlike awk -v.
        matches="$(printf '%s\n' "$identities" | MACOS_SIGN_REQUESTED="$requested" awk '
            BEGIN { requested = ENVIRON["MACOS_SIGN_REQUESTED"] }
            $1 ~ /^[0-9]+\)$/ && length($2) == 40 && $2 ~ /^[[:xdigit:]]+$/ {
                if (!match($0, /"[^"]*"/)) next
                name = substr($0, RSTART + 1, RLENGTH - 2)
                hash = toupper($2)
                if (requested == "" ? name ~ /^Developer ID Application: / : (name == requested || hash == toupper(requested))) {
                    if (!seen[hash]++) print hash "\t" name
                }
            }')" || return 1
        count="$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')" || return 1
        if [[ "$count" == 0 ]]; then
            if [[ -n "$requested" ]]; then
                printf 'Signing identity is not available: %s\n' "$requested" >&2
                return 1
            fi
            if [[ "$required" == 1 ]]; then
                printf 'A valid Developer ID Application identity is required.\n' >&2
                return 1
            fi
            printf 'No valid Developer ID Application identity found; using ad hoc signing.\n' >&2
            MACOS_SIGN_IDENTITY=-
        elif [[ "$count" != 1 ]]; then
            printf 'Multiple signing identities match; specify a full name or SHA-1:\n%s\n' "$matches" >&2
            return 1
        else
            IFS=$'\t' read -r MACOS_SIGN_IDENTITY MACOS_SIGN_NAME <<< "$matches"
        fi
    fi
    if [[ "$MACOS_SIGN_NAME" == "Developer ID Application: "* ]]; then
        team_pattern='\(([A-Z0-9]{10})\)$'
        if [[ ! "$MACOS_SIGN_NAME" =~ $team_pattern ]]; then
            printf 'Developer ID identity has no valid Team ID: %s\n' "$MACOS_SIGN_NAME" >&2
            return 1
        fi
        MACOS_SIGN_TEAM_ID="${BASH_REMATCH[1]}"
    elif [[ "$required" == 1 ]]; then
        printf 'A Developer ID Application identity is required; ad hoc and development identities are not accepted.\n' >&2
        return 1
    fi
    MACOS_SIGN_READY=1
    printf 'Signing identity: %s [%s]\n' "${MACOS_SIGN_NAME:-ad hoc}" "$MACOS_SIGN_IDENTITY"
}

_macos_signing_requirement() {
    local display requirement
    display="$(codesign --display -r- "$1" 2>&1)" || return 1
    requirement="$(printf '%s\n' "$display" | awk '/^(# )?designated => / { sub(/^(# )?designated => /, ""); print; count++ } END { if (count != 1) exit 1 }')" || return 1
    [[ -n "$requirement" ]] || return 1
    printf '%s\n' "$requirement"
}

_macos_signing_check_update() {
    local app="$1" previous="$2" previous_info previous_requirement
    [[ -e "$previous" ]] || return 0
    if ! previous_info="$(codesign --display --verbose=4 "$previous" 2>&1)"; then
        printf 'Previous app has no readable signature; this build establishes a new signing identity.\n'
        return 0
    fi
    if ! printf '%s\n' "$previous_info" | awk '/^Authority=Developer ID Application: / { found = 1 } END { exit !found }'; then
        if [[ -n "$MACOS_SIGN_TEAM_ID" ]]; then
            printf 'Migrating to Developer ID; an existing Keychain item may require one-time access approval.\n'
        fi
        return 0
    fi
    if [[ -z "$MACOS_SIGN_TEAM_ID" ]]; then
        printf 'Refusing to replace a Developer ID app with ad hoc or development signing. Use a separate development output directory.\n' >&2
        return 1
    fi
    if ! previous_requirement="$(_macos_signing_requirement "$previous")"; then
        printf 'Could not read the previous Developer ID app designated requirement.\n' >&2
        return 1
    fi
    # A literal requirement needs the '=' prefix; otherwise codesign reads a file.
    if ! codesign --verify --deep --strict -R "=$previous_requirement" "$app"; then
        printf 'New app does not satisfy the previous signing identity; refusing to replace it.\n' >&2
        return 1
    fi
    printf 'Verified signing identity continuity with the previous Developer ID app.\n'
}

macos_signing_sign_app() {
    local app="${1:-}" identifier="${2:-}" previous="${3:-}" entitlements="${4:-}"
    local signature entitlement_data debug_allowed requirement
    local sign_args=(--force --sign "${MACOS_SIGN_IDENTITY:-}" --identifier "$identifier")
    MACOS_SIGN_VERIFIED_APP=""
    MACOS_SIGN_REQUIREMENT=""
    MACOS_SIGN_PREVIOUS_APP=""
    if [[ "${MACOS_SIGN_READY:-0}" != 1 || ! -d "$app" || -z "$identifier" ]]; then
        printf 'Resolve a signing identity and provide an app bundle and identifier before signing.\n' >&2
        return 1
    fi
    if [[ -n "$entitlements" ]]; then
        if [[ ! -f "$entitlements" ]] || ! plutil -lint -- "$entitlements" >/dev/null; then
            printf 'Entitlements must be a valid plist: %s\n' "$entitlements" >&2
            return 1
        fi
        debug_allowed="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true)"
        if [[ -n "$MACOS_SIGN_TEAM_ID" && "$debug_allowed" == true ]]; then
            printf 'Developer ID distribution builds must not enable get-task-allow.\n' >&2
            return 1
        fi
        sign_args+=(--entitlements "$entitlements")
    fi
    [[ -z "$MACOS_SIGN_KEYCHAIN" ]] || sign_args+=(--keychain "$MACOS_SIGN_KEYCHAIN")
    if [[ -n "$MACOS_SIGN_TEAM_ID" ]]; then
        sign_args+=(--options runtime --timestamp)
    elif [[ "$MACOS_SIGN_IDENTITY" == - ]]; then
        sign_args+=(--timestamp=none)
    fi
    # Nested code must be signed inside-out by the caller; never sign with --deep.
    codesign "${sign_args[@]}" "$app" || return 1
    codesign --verify --deep --strict --verbose=2 "$app" || return 1
    signature="$(codesign --display --verbose=4 "$app" 2>&1)" || return 1
    if ! printf '%s\n' "$signature" | MACOS_EXPECTED_IDENTIFIER="$identifier" awk '
        $0 == "Identifier=" ENVIRON["MACOS_EXPECTED_IDENTIFIER"] { found = 1 }
        END { exit !found }
    '; then
        printf 'Signed app identifier does not match %s.\n' "$identifier" >&2
        return 1
    fi
    if [[ -n "$MACOS_SIGN_TEAM_ID" ]]; then
        if ! printf '%s\n' "$signature" | MACOS_EXPECTED_AUTHORITY="$MACOS_SIGN_NAME" MACOS_EXPECTED_TEAM="$MACOS_SIGN_TEAM_ID" awk '
            $0 == "Authority=" ENVIRON["MACOS_EXPECTED_AUTHORITY"] { authority_ok = 1 }
            /^CodeDirectory / && /flags=.*\([^)]*runtime[^)]*\)/ { runtime_ok = 1 }
            /^Timestamp=./ && $0 != "Timestamp=none" { timestamp_ok = 1 }
            $0 == "TeamIdentifier=" ENVIRON["MACOS_EXPECTED_TEAM"] { team_ok = 1 }
            END { exit !(authority_ok && runtime_ok && timestamp_ok && team_ok) }
        '; then
            printf 'Developer ID signature verification failed (identity, Team ID, runtime or timestamp).\n%s\n' "$signature" >&2
            return 1
        fi
        entitlement_data="$(codesign --display --entitlements :- "$app" 2>/dev/null)" || return 1
        if [[ -n "$entitlement_data" ]]; then
            printf '%s\n' "$entitlement_data" | plutil -lint - >/dev/null || return 1
            debug_allowed="$(printf '%s\n' "$entitlement_data" | plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null || true)"
            if [[ "$debug_allowed" == true ]]; then
                printf 'Developer ID signature must not allow debugging (get-task-allow).\n' >&2
                return 1
            fi
        fi
    elif [[ "$MACOS_SIGN_IDENTITY" == - ]]; then
        if ! printf '%s\n' "$signature" | awk '$0 == "Signature=adhoc" { found = 1 } END { exit !found }'; then
            printf 'Expected an ad hoc signature.\n' >&2
            return 1
        fi
    fi
    if ! requirement="$(_macos_signing_requirement "$app")"; then
        printf 'Signed app has no readable designated requirement.\n' >&2
        return 1
    fi
    if [[ -n "$previous" ]]; then
        _macos_signing_check_update "$app" "$previous" || return 1
    fi
    MACOS_SIGN_REQUIREMENT="$requirement"
    MACOS_SIGN_VERIFIED_APP="$app"
    MACOS_SIGN_PREVIOUS_APP="$previous"
    printf 'Verified signature. Designated requirement: %s\n' "$requirement"
}

macos_signing_publish_app() {
    local app="${1:-}" final="${2:-}" backup=""
    if [[ -z "$app" || -z "$final" || "$app" == "$final" || "$app" != "${MACOS_SIGN_VERIFIED_APP:-}" || ! -d "$app" ]]; then
        printf 'Only the verified staged app can be published.\n' >&2
        return 1
    fi
    if [[ -e "$final" && "$final" != "$MACOS_SIGN_PREVIOUS_APP" ]]; then
        printf 'The existing destination was not checked for signing identity continuity.\n' >&2
        return 1
    fi
    mkdir -p "$(dirname "$final")" || return 1
    if [[ -e "$final" ]]; then
        backup="$(mktemp -d "$(dirname "$final")/.previous-app.XXXXXX")" || return 1
        if ! mv "$final" "$backup/app"; then
            rmdir "$backup" || true
            return 1
        fi
    fi
    if ! mv "$app" "$final"; then
        if [[ -n "$backup" ]]; then
            if ! mv "$backup/app" "$final"; then
                printf 'Could not restore the previous app; recover it from %s/app.\n' "$backup" >&2
                return 1
            fi
            rmdir "$backup" || true
        fi
        return 1
    fi
    if [[ -n "$backup" ]]; then
        rm -rf "$backup" || return 1
    fi
    MACOS_SIGN_VERIFIED_APP="$final"
    MACOS_SIGN_PREVIOUS_APP=""
}
