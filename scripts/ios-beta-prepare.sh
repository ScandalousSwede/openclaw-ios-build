#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/ios-beta-prepare.sh --build-number 7 [--team-id TEAMID] [--push-mode relay|direct]

Optional custom relay:
  OPENCLAW_PUSH_RELAY_BASE_URL=https://relay.example.com \
    scripts/ios-beta-prepare.sh --build-number 7 [--team-id TEAMID]

Prepares local beta-release inputs without touching local signing overrides:
- reads apps/ios/version.json and writes apps/ios/build/Version.xcconfig
- writes apps/ios/build/BetaRelease.xcconfig with canonical bundle IDs
- configures relay-backed APNs registration by default
- supports an explicit direct mode for the isolated AIES internal TestFlight lane
- regenerates apps/ios/OpenClaw.xcodeproj via xcodegen
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/ios"
BUILD_DIR="${IOS_DIR}/build"
BETA_XCCONFIG="${IOS_DIR}/build/BetaRelease.xcconfig"
TEAM_HELPER="${ROOT_DIR}/scripts/ios-team-id.sh"
VERSION_HELPER="${ROOT_DIR}/scripts/ios-write-version-xcconfig.sh"
IOS_VERSION_HELPER="${ROOT_DIR}/scripts/ios-version.ts"
VERSION_SYNC_HELPER="${ROOT_DIR}/scripts/ios-sync-versioning.ts"
AIES_CONTINUITY_TEAM_ID="J76B47MZ6V"

BUILD_NUMBER=""
TEAM_ID="${IOS_DEVELOPMENT_TEAM:-}"
PUSH_MODE="relay"
DEFAULT_IOS_PUSH_RELAY_BASE_URL="https://ios-push-relay.openclaw.ai"
PUSH_RELAY_BASE_URL="${OPENCLAW_PUSH_RELAY_BASE_URL:-${IOS_PUSH_RELAY_BASE_URL:-${DEFAULT_IOS_PUSH_RELAY_BASE_URL}}}"
PUSH_RELAY_BASE_URL_XCCONFIG=""
PUSH_TRANSPORT=""
PUSH_DISTRIBUTION=""
IOS_VERSION=""

prepare_build_dir() {
  if [[ -L "${BUILD_DIR}" ]]; then
    echo "Refusing to use symlinked build directory: ${BUILD_DIR}" >&2
    exit 1
  fi

  mkdir -p "${BUILD_DIR}"
}

write_generated_file() {
  local output_path="$1"
  local tmp_file=""

  if [[ -e "${output_path}" && -L "${output_path}" ]]; then
    echo "Refusing to overwrite symlinked file: ${output_path}" >&2
    exit 1
  fi

  tmp_file="$(mktemp "${output_path}.XXXXXX")"
  cat >"${tmp_file}"
  mv -f "${tmp_file}" "${output_path}"
}

validate_push_relay_base_url() {
  local value="$1"

  if [[ "${value}" =~ [[:space:]] ]]; then
    echo "Invalid OPENCLAW_PUSH_RELAY_BASE_URL: whitespace is not allowed." >&2
    exit 1
  fi

  if [[ "${value}" == *'$'* || "${value}" == *'('* || "${value}" == *')'* || "${value}" == *'='* ]]; then
    echo "Invalid OPENCLAW_PUSH_RELAY_BASE_URL: contains forbidden xcconfig characters." >&2
    exit 1
  fi

  if [[ ! "${value}" =~ ^https://[A-Za-z0-9.-]+(:([0-9]{1,5}))?(/[A-Za-z0-9._~!&*+,;:@%/-]*)?$ ]]; then
    echo "Invalid OPENCLAW_PUSH_RELAY_BASE_URL: expected https://host[:port][/path]." >&2
    exit 1
  fi

  local port="${BASH_REMATCH[2]:-}"
  if [[ -n "${port}" ]] && (( 10#${port} > 65535 )); then
    echo "Invalid OPENCLAW_PUSH_RELAY_BASE_URL: port must be between 1 and 65535." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --push-mode)
      PUSH_MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${BUILD_NUMBER}" ]]; then
  echo "Missing required --build-number." >&2
  usage
  exit 1
fi

if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "Invalid --build-number: expected digits only." >&2
  exit 1
fi

if [[ -z "${TEAM_ID}" ]]; then
  TEAM_ID="$(IOS_ALLOW_KEYCHAIN_TEAM_FALLBACK=1 bash "${TEAM_HELPER}")"
fi

if [[ ! "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Invalid Apple Team ID: expected exactly 10 uppercase letters or digits." >&2
  exit 1
fi

if [[ "${TEAM_ID}" != "${AIES_CONTINUITY_TEAM_ID}" ]]; then
  echo "AIES old-identity continuity builds require Apple Team ${AIES_CONTINUITY_TEAM_ID}." >&2
  exit 1
fi

if [[ -z "${TEAM_ID}" ]]; then
  echo "Could not resolve Apple Team ID. Set IOS_DEVELOPMENT_TEAM or sign into Xcode." >&2
  exit 1
fi

case "${PUSH_MODE}" in
  relay)
    PUSH_TRANSPORT="relay"
    PUSH_DISTRIBUTION="official"
    validate_push_relay_base_url "${PUSH_RELAY_BASE_URL}"

    # `.xcconfig` treats `//` as a comment opener. Break the URL with a helper setting
    # so Xcode still resolves it back to `https://...` at build time.
    PUSH_RELAY_BASE_URL_XCCONFIG="$(
      # The sed replacement intentionally contains literal xcconfig substitutions.
      # shellcheck disable=SC2016
      printf '%s' "${PUSH_RELAY_BASE_URL}" \
        | sed 's#//#$(OPENCLAW_URL_SLASH)$(OPENCLAW_URL_SLASH)#g'
    )"
    ;;
  direct)
    # Direct mode publishes the production APNs token only to the authenticated
    # Argus gateway. Keep relay distribution and URL settings empty by construction.
    PUSH_TRANSPORT="direct"
    PUSH_DISTRIBUTION="local"
    PUSH_RELAY_BASE_URL_XCCONFIG=""
    ;;
  *)
    echo "Invalid --push-mode '${PUSH_MODE}'. Expected relay or direct." >&2
    exit 1
    ;;
esac

prepare_build_dir

(
  cd "${ROOT_DIR}" && node --import tsx "${VERSION_SYNC_HELPER}" --check
)

IOS_VERSION="$(cd "${ROOT_DIR}" && node --import tsx "${IOS_VERSION_HELPER}" --field canonicalVersion)"
if [[ -z "${IOS_VERSION}" ]]; then
  echo "Unable to resolve iOS version from ${ROOT_DIR}/apps/ios/version.json." >&2
  exit 1
fi

(
  bash "${VERSION_HELPER}" --build-number "${BUILD_NUMBER}"
)

write_generated_file "${BETA_XCCONFIG}" <<EOF
// Auto-generated by scripts/ios-beta-prepare.sh.
// Local beta-release override; do not commit.
DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
OPENCLAW_CODE_SIGN_STYLE = Automatic
OPENCLAW_DEVELOPMENT_TEAM = ${TEAM_ID}
OPENCLAW_IOS_SELECTED_TEAM = ${TEAM_ID}
OPENCLAW_APP_BUNDLE_ID = ai.openclaw.client
OPENCLAW_SHARE_BUNDLE_ID = ai.openclaw.client.share
OPENCLAW_ACTIVITY_WIDGET_BUNDLE_ID = ai.openclaw.client.activitywidget
OPENCLAW_WATCH_APP_BUNDLE_ID = ai.openclaw.client.watchkitapp
OPENCLAW_WATCH_EXTENSION_BUNDLE_ID = ai.openclaw.client.watchkitapp.extension
OPENCLAW_APP_PROFILE =
OPENCLAW_SHARE_PROFILE =
OPENCLAW_PUSH_TRANSPORT = ${PUSH_TRANSPORT}
OPENCLAW_PUSH_DISTRIBUTION = ${PUSH_DISTRIBUTION}
OPENCLAW_URL_SLASH = /
OPENCLAW_PUSH_RELAY_BASE_URL = ${PUSH_RELAY_BASE_URL_XCCONFIG}
OPENCLAW_PUSH_APNS_ENVIRONMENT = production
EOF

(
  cd "${IOS_DIR}"
  xcodegen generate
)

echo "Prepared iOS beta release: version=${IOS_VERSION} build=${BUILD_NUMBER} team=${TEAM_ID} push=${PUSH_MODE}"
echo "XCODE_XCCONFIG_FILE=${BETA_XCCONFIG}"
