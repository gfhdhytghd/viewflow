#!/usr/bin/env bash

# Reproduce and validate a Deskflow provenance manifest without building or
# changing the source tree. Any source/configuration/artifact drift and any
# pending Ninja action are rejected.

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly GENERATOR=$SCRIPT_DIR/generate-deskflow-provenance.sh
readonly DEFAULT_UPSTREAM_HEAD=760e3b99b00053647a96b405276bf614bd860075
readonly REQUIRED_PROTOCOL_VERSION=2.1
readonly REQUIRED_SIDECAR_PROTOCOL_VERSION=3

manifest=
manifest_expected_sha=
deskflow_candidate=
deskflow_expected_sha=
deskflow_core_candidate=
deskflow_core_expected_sha=
expected_upstream_head=$DEFAULT_UPSTREAM_HEAD

usage() {
    cat <<'EOF'
Usage: check-deskflow-provenance.sh \
  --manifest /absolute/path/deskflow-provenance.json \
  --manifest-sha256 64-hex-sha \
  --deskflow-candidate /absolute/path/deskflow \
  --deskflow-sha256 64-hex-sha \
  --deskflow-core-candidate /absolute/path/deskflow-core \
  --deskflow-core-sha256 64-hex-sha \
  [--expected-upstream-head 40-hex-commit]
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

while (($#)); do
    case $1 in
        --manifest)
            require_value "$1" "${2-}"
            manifest=$2
            shift 2
            ;;
        --manifest-sha256)
            require_value "$1" "${2-}"
            manifest_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-candidate)
            require_value "$1" "${2-}"
            deskflow_candidate=$2
            shift 2
            ;;
        --deskflow-sha256)
            require_value "$1" "${2-}"
            deskflow_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-core-candidate)
            require_value "$1" "${2-}"
            deskflow_core_candidate=$2
            shift 2
            ;;
        --deskflow-core-sha256)
            require_value "$1" "${2-}"
            deskflow_core_expected_sha=${2,,}
            shift 2
            ;;
        --expected-upstream-head)
            require_value "$1" "${2-}"
            expected_upstream_head=${2,,}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

[[ -n $manifest && -n $manifest_expected_sha && -n $deskflow_candidate &&
   -n $deskflow_expected_sha && -n $deskflow_core_candidate &&
   -n $deskflow_core_expected_sha ]] || {
    usage >&2
    die 'all manifest and artifact options are mandatory'
}
[[ $manifest_expected_sha =~ ^[0-9a-f]{64}$ &&
   $deskflow_expected_sha =~ ^[0-9a-f]{64}$ &&
   $deskflow_core_expected_sha =~ ^[0-9a-f]{64}$ ]] ||
    die 'all SHA-256 values must be exactly 64 lowercase hexadecimal characters'
[[ $expected_upstream_head =~ ^[0-9a-f]{40}$ ]] ||
    die 'upstream head must be exactly 40 lowercase hexadecimal characters'

for command_name in chmod cmp install jq mktemp python3 readelf rm sha256sum stat; do
    command -v "$command_name" >/dev/null || die "required command is unavailable: $command_name"
done
[[ -x $GENERATOR ]] || die "provenance generator is not executable: $GENERATOR"

require_regular_file() {
    local label=$1 path=$2
    [[ $path == /* ]] || die "$label must be an absolute path"
    [[ -f $path && ! -L $path ]] || die "$label must be a regular, non-symlink file: $path"
}

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

elf_build_id() {
    local path=$1 build_id
    build_id=$(readelf -n -- "$path" 2>/dev/null |
        awk '/Build ID:/ {print tolower($3); found=1; exit} END {if (!found) exit 1}') ||
        die "ELF artifact has no GNU build ID: $path"
    printf '%s\n' "$build_id"
}

assert_strict_json_document() {
    local label=$1 path=$2
    python3 - "$label" "$path" <<'PY'
import json
import sys


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


label, path = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as document:
        value = json.load(document, object_pairs_hook=reject_duplicate_keys)
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value is not an object")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
    print(f"error: {label} is not one strict JSON object: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

validate_exact_schema() {
    jq -e \
        --arg upstream "$expected_upstream_head" \
        --arg protocol_version "$REQUIRED_PROTOCOL_VERSION" \
        --argjson sidecar_protocol_version "$REQUIRED_SIDECAR_PROTOCOL_VERSION" \
        --arg deskflow_sha "$deskflow_expected_sha" \
        --arg core_sha "$deskflow_core_expected_sha" '
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def build_id: type == "string" and test("^[0-9a-f]+$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        def absolute: type == "string" and startswith("/");
        def source_path: type == "string" and test("^[A-Za-z0-9._/@+=,:~-]+$") and
          (startswith("/") | not) and . != "." and . != ".." and
          (startswith("../") | not) and (contains("/../") | not) and
          (endswith("/..") | not);
        def tracked_entry:
          (keys == ["path", "sha256", "size_bytes", "status"]) and
          (.path | source_path) and .status == "M" and
          (.sha256 | sha256) and (.size_bytes | uint53);
        def untracked_entry:
          (keys == ["path", "sha256", "size_bytes"]) and
          (.path | source_path) and (.sha256 | sha256) and (.size_bytes | uint53);
        def critical_entry:
          (keys == ["path", "sha256", "size_bytes", "status"]) and
          (.path | source_path) and (.status == "M" or .status == "U") and
          (.sha256 | sha256) and (.size_bytes | uint53);
        def artifact:
          (keys == ["elf_build_id", "sha256", "size_bytes", "source_path"]) and
          (.source_path | absolute) and (.sha256 | sha256) and
          (.size_bytes | uint53 and . > 0) and (.elf_build_id | build_id);
        def live_acceptance:
          (keys == ["arm_magic", "core_query", "enabled", "peer_auth", "protocol_version", "receipt_magic", "receipt_size", "sidecar_protocol_version", "socket_kind"]) and
          .enabled == true and .core_query == true and
          .socket_kind == "af_unix" and
          .peer_auth == "so_peercred_same_uid" and
          .arm_magic == "VFARM001" and .receipt_magic == "VFRCP001" and
          .receipt_size == 568 and
          .protocol_version == $protocol_version and
          .sidecar_protocol_version == $sidecar_protocol_version;
        (keys == ["artifacts", "build", "generated_at_utc", "kind", "protocol_version", "schema_version", "sidecar_protocol_version", "source", "upstream"]) and
        .schema_version == 1 and .kind == "viewflow-deskflow-linux-provenance" and
        .protocol_version == $protocol_version and
        .sidecar_protocol_version == $sidecar_protocol_version and
        (.upstream | keys == ["commit", "detached_head"]) and
        .upstream.commit == $upstream and .upstream.detached_head == true and
        (.source | keys == ["critical_files", "modified_tracked_files", "root", "tracked_patch", "untracked_source_files"]) and
        (.source.root | absolute) and
        (.source.tracked_patch | keys == ["sha256", "size_bytes"]) and
        (.source.tracked_patch.sha256 | sha256) and
        (.source.tracked_patch.size_bytes | uint53 and . > 0) and
        (.source.modified_tracked_files | type == "array" and length == 8 and all(.[]; tracked_entry)) and
        (.source.modified_tracked_files | map(.path)) == [
          "src/apps/deskflow-core/deskflow-core.cpp",
          "src/lib/arch/unix/ArchMultithreadPosix.cpp",
          "src/lib/platform/PortalInputCapture.cpp",
          "src/lib/platform/PortalInputCapture.h",
          "src/lib/server/CMakeLists.txt",
          "src/lib/server/Server.cpp",
          "src/lib/server/Server.h",
          "src/unittests/server/CMakeLists.txt"
        ] and
        (.source.untracked_source_files | type == "array" and length == 4 and all(.[]; untracked_entry)) and
        (.source.untracked_source_files | map(.path)) == [
          "src/lib/server/ViewflowSidecarClient.cpp",
          "src/lib/server/ViewflowSidecarClient.h",
          "src/unittests/server/ViewflowSidecarClientTests.cpp",
          "src/unittests/server/ViewflowSidecarClientTests.h"
        ] and
        (.source.critical_files | type == "array" and length == 12 and all(.[]; critical_entry)) and
        (.source.critical_files | map(.path)) ==
          ((.source.modified_tracked_files | map(.path)) + (.source.untracked_source_files | map(.path))) and
        .source.critical_files ==
          (.source.modified_tracked_files +
           (.source.untracked_source_files | map(. + {status: "U"}))) and
        (.build | keys == ["build_type", "cmake", "compilers", "directory", "generator", "live_acceptance", "ninja"]) and
        (.build.directory | absolute) and .build.generator == "Ninja" and
        (.build.build_type | type == "string" and length > 0) and
        (.build.live_acceptance | live_acceptance) and
        (.build.cmake | keys == ["cache_sha256", "cache_size_bytes", "executable", "executable_sha256", "verify_globs_sha256", "verify_globs_size_bytes", "version"]) and
        (.build.cmake.executable | absolute) and (.build.cmake.version | type == "string" and length > 0) and
        (.build.cmake.executable_sha256 | sha256) and (.build.cmake.cache_sha256 | sha256) and
        (.build.cmake.cache_size_bytes | uint53 and . > 0) and
        (.build.cmake.verify_globs_sha256 | sha256) and
        (.build.cmake.verify_globs_size_bytes | uint53 and . > 0) and
        (.build.ninja | keys == ["build_file_sha256", "build_file_size_bytes", "executable", "executable_sha256", "pending_rebuild", "rules_file_sha256", "rules_file_size_bytes", "version"]) and
        (.build.ninja.executable | absolute) and (.build.ninja.version | type == "string" and length > 0) and
        (.build.ninja.executable_sha256 | sha256) and (.build.ninja.build_file_sha256 | sha256) and
        (.build.ninja.build_file_size_bytes | uint53 and . > 0) and
        (.build.ninja.rules_file_sha256 | sha256) and
        (.build.ninja.rules_file_size_bytes | uint53 and . > 0) and
        .build.ninja.pending_rebuild == false and
        (.build.compilers | keys == ["c", "cxx"]) and
        all([.build.compilers.c, .build.compilers.cxx][];
          keys == ["executable_sha256", "path", "version"] and
          (.path | absolute) and (.version | type == "string" and length > 0) and
          (.executable_sha256 | sha256)) and
        (.artifacts | keys == ["deskflow", "deskflow_core"]) and
        (.artifacts.deskflow | artifact) and (.artifacts.deskflow_core | artifact) and
        .artifacts.deskflow.source_path == (.build.directory + "/bin/deskflow") and
        .artifacts.deskflow_core.source_path == (.build.directory + "/bin/deskflow-core") and
        .artifacts.deskflow.sha256 == $deskflow_sha and
        .artifacts.deskflow_core.sha256 == $core_sha and
        (.generated_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        ' "$manifest" >/dev/null || die 'provenance manifest schema or embedded artifact identity is invalid'
}

require_regular_file 'provenance manifest' "$manifest"
require_regular_file 'deskflow candidate' "$deskflow_candidate"
require_regular_file 'deskflow-core candidate' "$deskflow_core_candidate"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/deskflow-provenance-check.XXXXXXXX")
chmod 0700 "$tmp_dir"
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$tmp_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
install -m 0400 -- "$manifest" "$tmp_dir/input-manifest.json"
install -m 0400 -- "$deskflow_candidate" "$tmp_dir/input-deskflow"
install -m 0400 -- "$deskflow_core_candidate" "$tmp_dir/input-deskflow-core"
manifest=$tmp_dir/input-manifest.json
deskflow_candidate=$tmp_dir/input-deskflow
deskflow_core_candidate=$tmp_dir/input-deskflow-core

assert_strict_json_document 'provenance manifest' "$manifest"
[[ $(sha256 "$manifest") == "$manifest_expected_sha" ]] || die 'provenance manifest SHA-256 mismatch'
[[ $(sha256 "$deskflow_candidate") == "$deskflow_expected_sha" ]] || die 'deskflow candidate SHA-256 mismatch'
[[ $(sha256 "$deskflow_core_candidate") == "$deskflow_core_expected_sha" ]] || die 'deskflow-core candidate SHA-256 mismatch'
validate_exact_schema

deskflow_size=$(jq -er '.artifacts.deskflow.size_bytes' "$manifest")
deskflow_build_id=$(jq -er '.artifacts.deskflow.elf_build_id' "$manifest")
core_size=$(jq -er '.artifacts.deskflow_core.size_bytes' "$manifest")
core_build_id=$(jq -er '.artifacts.deskflow_core.elf_build_id' "$manifest")
[[ $(stat -c '%s' -- "$deskflow_candidate") == "$deskflow_size" ]] ||
    die 'deskflow candidate size does not match provenance manifest'
[[ $(elf_build_id "$deskflow_candidate") == "$deskflow_build_id" ]] ||
    die 'deskflow candidate build ID does not match provenance manifest'
[[ $(stat -c '%s' -- "$deskflow_core_candidate") == "$core_size" ]] ||
    die 'deskflow-core candidate size does not match provenance manifest'
[[ $(elf_build_id "$deskflow_core_candidate") == "$core_build_id" ]] ||
    die 'deskflow-core candidate build ID does not match provenance manifest'

regenerated=$tmp_dir/regenerated.json
"$GENERATOR" \
    --source-dir "$(jq -er '.source.root' "$manifest")" \
    --build-dir "$(jq -er '.build.directory' "$manifest")" \
    --deskflow "$(jq -er '.artifacts.deskflow.source_path' "$manifest")" \
    --deskflow-core "$(jq -er '.artifacts.deskflow_core.source_path' "$manifest")" \
    --output "$regenerated" \
    --expected-upstream-head "$expected_upstream_head" >/dev/null

jq -cS 'del(.generated_at_utc)' "$manifest" >"$tmp_dir/expected.canonical.json"
jq -cS 'del(.generated_at_utc)' "$regenerated" >"$tmp_dir/actual.canonical.json"
cmp -s "$tmp_dir/expected.canonical.json" "$tmp_dir/actual.canonical.json" ||
    die 'provenance manifest does not match the current source, build configuration, or source artifacts'
[[ $(sha256 "$manifest") == "$manifest_expected_sha" &&
   $(sha256 "$deskflow_candidate") == "$deskflow_expected_sha" &&
   $(sha256 "$deskflow_core_candidate") == "$deskflow_core_expected_sha" ]] ||
    die 'staged provenance input changed during verification'

printf 'Deskflow provenance check passed\n'
