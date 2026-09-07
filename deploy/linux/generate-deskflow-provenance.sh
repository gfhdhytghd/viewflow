#!/usr/bin/env bash

# Freeze the exact detached, dirty Deskflow source state and the two ELF
# artifacts produced from it. This script never builds or changes the source
# tree; a pending Ninja action is a hard failure.

set -Eeuo pipefail
export LC_ALL=C

# Git's object and repository selection is extensively environment-driven.
# Provenance must describe the repository passed on the command line, without
# caller-supplied replace objects, alternate object stores, namespaces, or
# config injection changing what HEAD and diff mean.
while IFS= read -r git_environment_name; do
    [[ $git_environment_name == GIT_* ]] && unset "$git_environment_name"
done < <(compgen -e)
export GIT_NO_REPLACE_OBJECTS=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

readonly DEFAULT_UPSTREAM_HEAD=760e3b99b00053647a96b405276bf614bd860075
readonly REQUIRED_PROTOCOL_VERSION=2.1
readonly REQUIRED_SIDECAR_PROTOCOL_VERSION=3

source_dir=
build_dir=
deskflow_artifact=
deskflow_core_artifact=
output=
expected_upstream_head=$DEFAULT_UPSTREAM_HEAD

usage() {
    cat <<'EOF'
Usage: generate-deskflow-provenance.sh \
  --source-dir /absolute/path/deskflow-source \
  --build-dir /absolute/path/deskflow-build \
  --deskflow /absolute/path/deskflow \
  --deskflow-core /absolute/path/deskflow-core \
  --output /absolute/path/deskflow-provenance.json \
  [--expected-upstream-head 40-hex-commit]

The upstream override exists only for isolated fixture repositories. Production
generation must use the default reviewed Deskflow 1.26.0 commit.
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
        --source-dir)
            require_value "$1" "${2-}"
            source_dir=$2
            shift 2
            ;;
        --build-dir)
            require_value "$1" "${2-}"
            build_dir=$2
            shift 2
            ;;
        --deskflow)
            require_value "$1" "${2-}"
            deskflow_artifact=$2
            shift 2
            ;;
        --deskflow-core)
            require_value "$1" "${2-}"
            deskflow_core_artifact=$2
            shift 2
            ;;
        --output)
            require_value "$1" "${2-}"
            output=$2
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

[[ -n $source_dir && -n $build_dir && -n $deskflow_artifact &&
   -n $deskflow_core_artifact && -n $output ]] || {
    usage >&2
    die 'all source, build, artifact, and output options are mandatory'
}
[[ $expected_upstream_head =~ ^[0-9a-f]{40}$ ]] ||
    die '--expected-upstream-head must be exactly 40 lowercase hexadecimal characters'

for command_name in awk chmod cmake cmp date git grep jq ln mktemp ninja python3 \
    readelf readlink rm sed sha256sum stat tee; do
    command -v "$command_name" >/dev/null || die "required command is unavailable: $command_name"
done

canonical_directory() {
    local label=$1 path=$2
    [[ $path == /* ]] || die "$label must be an absolute path"
    [[ -d $path && ! -L $path ]] || die "$label must be a non-symlink directory: $path"
    readlink -f -- "$path"
}

canonical_file() {
    local label=$1 path=$2
    [[ $path == /* ]] || die "$label must be an absolute path"
    [[ -f $path && ! -L $path ]] || die "$label must be a regular, non-symlink file: $path"
    readlink -f -- "$path"
}

canonical_tool() {
    local label=$1 path=$2 canonical
    [[ $path == /* ]] || die "$label must be an absolute path"
    canonical=$(readlink -f -- "$path")
    [[ -f $canonical && ! -L $canonical ]] ||
        die "$label does not resolve to a regular file: $path"
    printf '%s\n' "$canonical"
}

source_dir=$(canonical_directory 'source directory' "$source_dir")
build_dir=$(canonical_directory 'build directory' "$build_dir")
deskflow_artifact=$(canonical_file 'deskflow artifact' "$deskflow_artifact")
deskflow_core_artifact=$(canonical_file 'deskflow-core artifact' "$deskflow_core_artifact")
[[ $output == /* ]] || die 'output must be an absolute path'
output_parent=$(canonical_directory 'output parent directory' "$(dirname -- "$output")")
output=$output_parent/$(basename -- "$output")
[[ ! -e $output && ! -L $output ]] || die "output already exists: $output"

case "$build_dir/" in
    "$source_dir/"*) ;;
    *) die 'build directory must be inside the source directory' ;;
esac
build_relative=${build_dir#"$source_dir"/}
[[ -n $build_relative && $build_relative != "$build_dir" ]] ||
    die 'build directory must be a proper child of the source directory'
[[ $deskflow_artifact == "$build_dir/bin/deskflow" ]] ||
    die 'deskflow artifact must be the exact Ninja output build/bin/deskflow'
[[ $deskflow_core_artifact == "$build_dir/bin/deskflow-core" ]] ||
    die 'deskflow-core artifact must be the exact Ninja output build/bin/deskflow-core'
[[ $deskflow_artifact != "$deskflow_core_artifact" ]] ||
    die 'Deskflow artifacts must be distinct files'

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

file_size() {
    stat -c '%s' -- "$1"
}

elf_build_id() {
    local path=$1 build_id
    build_id=$(readelf -n -- "$path" 2>/dev/null |
        awk '/Build ID:/ {print tolower($3); found=1; exit} END {if (!found) exit 1}') ||
        die "ELF artifact has no GNU build ID: $path"
    [[ $build_id =~ ^[0-9a-f]+$ ]] || die "invalid ELF build ID: $path"
    printf '%s\n' "$build_id"
}

require_safe_relative_path() {
    local path=$1
    [[ -n $path && $path != /* && $path != . && $path != .. &&
       $path != ../* && $path != */../* && $path != */.. &&
       $path =~ ^[A-Za-z0-9._/@+=,:~-]+$ ]] ||
        die "unsupported source path: $path"
}

cache_value() {
    local key=$1 cache=$build_dir/CMakeCache.txt value
    value=$(awk -F= -v key="$key" '$1 ~ ("^" key ":[^=]+$") {print substr($0, index($0, "=") + 1); found=1; exit} END {if (!found) exit 1}' "$cache") ||
        die "CMake cache is missing $key"
    printf '%s\n' "$value"
}

ninja_is_clean() {
    local log=$1
    shift
    local filtered=$log.unexpected verify_source verify_copy verify_log
    local touch_count replacement_count
    if ! "$ninja_executable" -C "$build_dir" -n -d explain "$@" >"$log" 2>&1; then
        sed -n '1,80p' "$log" >&2
        die 'Ninja dry-run failed'
    fi
    # CMake CONFIGURE_DEPENDS always makes Ninja describe these two dry-run
    # housekeeping steps because -n cannot execute VerifyGlobs and restat its
    # stamp. They are not compilation/link work. Any other explanation or
    # command remains a hard failure.
    awk '
      /^ninja: Entering directory / {next}
      /^ninja: no work to do\.$/ {next}
      /^ninja explain: .*\/CMakeFiles\/VerifyGlobs\.cmake_force is dirty$/ {next}
      /^ninja explain: .*\/CMakeFiles\/cmake\.verify_globs is dirty$/ {next}
      /^\[0\/2\] Re-checking globbed directories\.\.\.$/ {next}
      /^\[1\/2\] Re-running CMake\.\.\.$/ {next}
      {print; unexpected=1}
      END {exit unexpected}
    ' "$log" >"$filtered" || {
        sed -n '1,80p' "$log" >&2
        die 'Ninja reports pending rebuild work'
    }
    [[ ! -s $filtered ]] || die 'Ninja reports pending rebuild work'

    verify_source=$build_dir/CMakeFiles/VerifyGlobs.cmake
    if [[ -e $verify_source ]]; then
        [[ -f $verify_source && ! -L $verify_source ]] ||
            die 'CMake VerifyGlobs script is not a regular file'
        verify_copy=$tmp_dir/VerifyGlobs.no-touch.cmake
        verify_log=$log.verify-globs
        sed -E 's|^([[:space:]]*)file\(TOUCH_NOCREATE .+\)$|\1message(FATAL_ERROR "Deskflow provenance glob mismatch")|' \
            "$verify_source" >"$verify_copy"
        touch_count=$(grep -c 'file(TOUCH_NOCREATE ' "$verify_source")
        replacement_count=$(grep -c 'Deskflow provenance glob mismatch' "$verify_copy")
        [[ $touch_count -gt 0 && $replacement_count -eq $touch_count ]] ||
            die 'CMake VerifyGlobs script does not match the reviewed no-touch transform'
        if ! "$cmake_executable" -P "$verify_copy" >"$verify_log" 2>&1; then
            sed -n '1,80p' "$verify_log" >&2
            die 'CMake source glob set differs from the configured build graph'
        fi
    fi
}

readonly -a REQUIRED_TRACKED_FILES=(
    src/apps/deskflow-core/deskflow-core.cpp
    src/lib/arch/unix/ArchMultithreadPosix.cpp
    src/lib/platform/PortalInputCapture.cpp
    src/lib/platform/PortalInputCapture.h
    src/lib/server/CMakeLists.txt
    src/lib/server/Server.cpp
    src/lib/server/Server.h
    src/unittests/server/CMakeLists.txt
)
readonly -a REQUIRED_UNTRACKED_SOURCE_FILES=(
    src/lib/server/ViewflowSidecarClient.cpp
    src/lib/server/ViewflowSidecarClient.h
    src/unittests/server/ViewflowSidecarClientTests.cpp
    src/unittests/server/ViewflowSidecarClientTests.h
)

# This is deliberately a source capability attestation, not a claim that a
# currently running Deskflow daemon has already produced acceptance evidence.
# The latter is queried only through the owner-only live core control socket
# during the post-release transaction.  Keep these assertions structural and
# fail closed if the reviewed implementation stops providing that query path.
validate_live_acceptance_capability() {
    local sidecar_source=$source_dir/src/lib/server/ViewflowSidecarClient.cpp
    local core_source=$source_dir/src/apps/deskflow-core/deskflow-core.cpp
    [[ -f $sidecar_source && ! -L $sidecar_source &&
       -f $core_source && ! -L $core_source ]] ||
        die 'reviewed live acceptance source files are unavailable'

    grep -Fqx \
        "constexpr std::array<uint8_t, 8> kAcceptanceArmMagic = {'V', 'F', 'A', 'R', 'M', '0', '0', '1'};" \
        "$sidecar_source" || die 'reviewed live acceptance arm record magic is unavailable'
    grep -Fqx \
        "constexpr std::array<uint8_t, 8> kAcceptanceReceiptMagic = {'V', 'F', 'R', 'C', 'P', '0', '0', '1'};" \
        "$sidecar_source" || die 'reviewed live acceptance receipt magic is unavailable'
    grep -Fqx 'constexpr size_t kAcceptanceReceiptBytes = 568;' "$sidecar_source" ||
        die 'reviewed live acceptance receipt size is unavailable'
    grep -Fq '::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC' "$sidecar_source" ||
        die 'reviewed live acceptance AF_UNIX transport is unavailable'
    grep -Fq '::getsockopt(fd, SOL_SOCKET, SO_PEERCRED' "$sidecar_source" ||
        die 'reviewed live acceptance peer credential gate is unavailable'
    grep -Fq 'std::string_view(argv[1]) == "--viewflow-acceptance-query"' "$sidecar_source" ||
        die 'reviewed live core query parser is unavailable'
    grep -Fq 'return runViewflowAcceptanceQuery(argc, argv);' "$core_source" ||
        die 'reviewed deskflow-core live query entrypoint is unavailable'
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/deskflow-provenance.XXXXXXXX")
manifest_tmp=$(mktemp "$output_parent/.deskflow-provenance.XXXXXXXX")
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$tmp_dir"
    rm -f -- "$manifest_tmp"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot_source() {
    local prefix=$1
    local patch=$tmp_dir/$prefix.patch tracked_tsv=$tmp_dir/$prefix.tracked.tsv
    local untracked_tsv=$tmp_dir/$prefix.untracked.tsv critical_tsv=$tmp_dir/$prefix.critical.tsv
    local status path candidate
    local -a actual_tracked=() actual_untracked=() actual_ignored=()

    git -C "$source_dir" -c color.ui=false -c core.autocrlf=false diff \
        --binary --full-index --no-ext-diff --no-renames --no-color \
        "$head_commit" -- . >"$patch"

    mapfile -d '' -t actual_tracked < <(
        git -C "$source_dir" diff --name-only -z --no-renames "$head_commit" -- .
    )
    ((${#actual_tracked[@]} == ${#REQUIRED_TRACKED_FILES[@]})) ||
        die 'tracked dirty file set does not match the reviewed Deskflow patch'
    for candidate in "${!REQUIRED_TRACKED_FILES[@]}"; do
        [[ ${actual_tracked[candidate]} == "${REQUIRED_TRACKED_FILES[candidate]}" ]] ||
            die 'tracked dirty file set does not match the reviewed Deskflow patch'
    done

    mapfile -d '' -t actual_untracked < <(
        git -C "$source_dir" ls-files --others --exclude-standard -z -- . |
            while IFS= read -r -d '' path; do
                [[ $path == "$build_relative" || $path == "$build_relative"/* ]] ||
                    printf '%s\0' "$path"
            done
    )
    ((${#actual_untracked[@]} == ${#REQUIRED_UNTRACKED_SOURCE_FILES[@]})) ||
        die 'untracked source file set does not match the reviewed Deskflow patch'
    for candidate in "${!REQUIRED_UNTRACKED_SOURCE_FILES[@]}"; do
        [[ ${actual_untracked[candidate]} == "${REQUIRED_UNTRACKED_SOURCE_FILES[candidate]}" ]] ||
            die 'untracked source file set does not match the reviewed Deskflow patch'
    done

    # An ignored file can still affect a configured build when CMake names it
    # explicitly. The build tree is the only allowed ignored subtree; every
    # other ignored file would be an unrecorded build input.
    mapfile -d '' -t actual_ignored < <(
        git -C "$source_dir" ls-files --others --ignored --exclude-standard -z -- . |
            while IFS= read -r -d '' path; do
                [[ $path == "$build_relative" || $path == "$build_relative"/* ]] ||
                    printf '%s\0' "$path"
            done
    )
    ((${#actual_ignored[@]} == 0)) ||
        die 'ignored files outside the reviewed build directory are not allowed'

    : >"$tracked_tsv"
    : >"$untracked_tsv"
    : >"$critical_tsv"
    for path in "${REQUIRED_TRACKED_FILES[@]}"; do
        require_safe_relative_path "$path"
        [[ -f $source_dir/$path && ! -L $source_dir/$path ]] ||
            die "reviewed tracked source is not a regular file: $path"
        status=$(git -C "$source_dir" diff --name-status --no-renames \
            "$head_commit" -- "$path" |
            awk 'NR == 1 {print $1}')
        [[ $status == M ]] || die "reviewed tracked source must have status M: $path"
        printf '%s\t%s\t%s\t%s\n' "$path" "$status" \
            "$(sha256 "$source_dir/$path")" "$(file_size "$source_dir/$path")" |
            tee -a "$tracked_tsv" >>"$critical_tsv"
    done
    for path in "${REQUIRED_UNTRACKED_SOURCE_FILES[@]}"; do
        require_safe_relative_path "$path"
        [[ -f $source_dir/$path && ! -L $source_dir/$path ]] ||
            die "reviewed untracked source is not a regular file: $path"
        printf '%s\t%s\t%s\t%s\n' "$path" U \
            "$(sha256 "$source_dir/$path")" "$(file_size "$source_dir/$path")" |
            tee -a "$untracked_tsv" >>"$critical_tsv"
    done

    jq -Rn '[inputs | split("\t") | {path: .[0], status: .[1], sha256: .[2], size_bytes: (.[3] | tonumber)}]' \
        <"$tracked_tsv" >"$tmp_dir/$prefix.tracked.json"
    jq -Rn '[inputs | split("\t") | {path: .[0], sha256: .[2], size_bytes: (.[3] | tonumber)}]' \
        <"$untracked_tsv" >"$tmp_dir/$prefix.untracked.json"
    jq -Rn '[inputs | split("\t") | {path: .[0], status: .[1], sha256: .[2], size_bytes: (.[3] | tonumber)}]' \
        <"$critical_tsv" >"$tmp_dir/$prefix.critical.json"
    printf '%s\t%s\n' "$(sha256 "$patch")" "$(file_size "$patch")" >"$tmp_dir/$prefix.patch.identity"
}

[[ $(git -C "$source_dir" rev-parse --is-inside-work-tree) == true ]] ||
    die 'source directory is not a Git worktree'
[[ -z $(git -C "$source_dir" for-each-ref --format='%(refname)' refs/replace) ]] ||
    die 'Git replacement refs are not allowed in the Deskflow source repository'
git_common_dir=$(git -C "$source_dir" rev-parse --path-format=absolute --git-common-dir)
[[ ! -s $git_common_dir/info/grafts ]] ||
    die 'Git grafts are not allowed in the Deskflow source repository'
head_commit=$(git -C "$source_dir" rev-parse --verify HEAD)
[[ $head_commit == "$expected_upstream_head" ]] ||
    die "unexpected Deskflow upstream HEAD: $head_commit"
if git -C "$source_dir" symbolic-ref -q HEAD >/dev/null; then
    die 'Deskflow source must remain at a detached HEAD'
fi

[[ -f $build_dir/CMakeCache.txt && ! -L $build_dir/CMakeCache.txt ]] ||
    die 'CMakeCache.txt is missing or is a symlink'
[[ -f $build_dir/build.ninja && ! -L $build_dir/build.ninja ]] ||
    die 'build.ninja is missing or is a symlink'
[[ -f $build_dir/CMakeFiles/rules.ninja &&
   ! -L $build_dir/CMakeFiles/rules.ninja ]] ||
    die 'CMake Ninja rules file is missing or is a symlink'
[[ -f $build_dir/CMakeFiles/VerifyGlobs.cmake &&
   ! -L $build_dir/CMakeFiles/VerifyGlobs.cmake ]] ||
    die 'CMake VerifyGlobs script is missing or is a symlink'
[[ $(cache_value CMAKE_GENERATOR) == Ninja ]] || die 'CMake generator must be Ninja'
build_type=$(cache_value CMAKE_BUILD_TYPE)
[[ -n $build_type ]] || die 'CMAKE_BUILD_TYPE must be non-empty'
c_compiler=$(canonical_tool 'C compiler' "$(cache_value CMAKE_C_COMPILER)")
cxx_compiler=$(canonical_tool 'C++ compiler' "$(cache_value CMAKE_CXX_COMPILER)")
cmake_executable=$(canonical_tool 'CMake executable' "$(command -v cmake)")
ninja_executable=$(canonical_tool 'Ninja executable' "$(command -v ninja)")

mapfile -t ninja_graph_includes < <(
    awk '$1 == "include" || $1 == "subninja" {print}' "$build_dir/build.ninja"
)
((${#ninja_graph_includes[@]} == 1)) &&
    [[ ${ninja_graph_includes[0]} == 'include CMakeFiles/rules.ninja' ]] ||
    die 'Ninja graph includes differ from the reviewed CMake graph closure'

snapshot_source before
validate_live_acceptance_capability
ninja_is_clean "$tmp_dir/ninja-before.log"
ninja_is_clean "$tmp_dir/ninja-targets-before.log" bin/deskflow bin/deskflow-core

cmake_cache_sha=$(sha256 "$build_dir/CMakeCache.txt")
cmake_cache_size=$(file_size "$build_dir/CMakeCache.txt")
build_ninja_sha=$(sha256 "$build_dir/build.ninja")
build_ninja_size=$(file_size "$build_dir/build.ninja")
rules_ninja_sha=$(sha256 "$build_dir/CMakeFiles/rules.ninja")
rules_ninja_size=$(file_size "$build_dir/CMakeFiles/rules.ninja")
verify_globs_sha=$(sha256 "$build_dir/CMakeFiles/VerifyGlobs.cmake")
verify_globs_size=$(file_size "$build_dir/CMakeFiles/VerifyGlobs.cmake")
cmake_version=$("$cmake_executable" --version | sed -n '1p')
ninja_version=$("$ninja_executable" --version)
c_version=$("$c_compiler" --version | sed -n '1p')
cxx_version=$("$cxx_compiler" --version | sed -n '1p')
cmake_executable_sha=$(sha256 "$cmake_executable")
ninja_executable_sha=$(sha256 "$ninja_executable")
c_executable_sha=$(sha256 "$c_compiler")
cxx_executable_sha=$(sha256 "$cxx_compiler")

deskflow_sha=$(sha256 "$deskflow_artifact")
deskflow_size=$(file_size "$deskflow_artifact")
deskflow_build_id=$(elf_build_id "$deskflow_artifact")
deskflow_core_sha=$(sha256 "$deskflow_core_artifact")
deskflow_core_size=$(file_size "$deskflow_core_artifact")
deskflow_core_build_id=$(elf_build_id "$deskflow_core_artifact")

read -r patch_sha patch_size <"$tmp_dir/before.patch.identity"
generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
    --arg kind viewflow-deskflow-linux-provenance \
    --arg protocol_version "$REQUIRED_PROTOCOL_VERSION" \
    --argjson sidecar_protocol_version "$REQUIRED_SIDECAR_PROTOCOL_VERSION" \
    --arg head "$head_commit" \
    --arg source_root "$source_dir" \
    --arg patch_sha "$patch_sha" --arg patch_size "$patch_size" \
    --slurpfile tracked "$tmp_dir/before.tracked.json" \
    --slurpfile untracked "$tmp_dir/before.untracked.json" \
    --slurpfile critical "$tmp_dir/before.critical.json" \
    --arg build_directory "$build_dir" --arg build_type "$build_type" \
    --arg cmake_executable "$cmake_executable" --arg cmake_version "$cmake_version" \
    --arg cmake_executable_sha "$cmake_executable_sha" \
    --arg cmake_cache_sha "$cmake_cache_sha" --arg cmake_cache_size "$cmake_cache_size" \
    --arg verify_globs_sha "$verify_globs_sha" --arg verify_globs_size "$verify_globs_size" \
    --arg ninja_executable "$ninja_executable" --arg ninja_version "$ninja_version" \
    --arg ninja_executable_sha "$ninja_executable_sha" \
    --arg build_ninja_sha "$build_ninja_sha" --arg build_ninja_size "$build_ninja_size" \
    --arg rules_ninja_sha "$rules_ninja_sha" --arg rules_ninja_size "$rules_ninja_size" \
    --arg c_path "$c_compiler" --arg c_version "$c_version" \
    --arg c_sha "$c_executable_sha" \
    --arg cxx_path "$cxx_compiler" --arg cxx_version "$cxx_version" \
    --arg cxx_sha "$cxx_executable_sha" \
    --arg deskflow_path "$deskflow_artifact" --arg deskflow_sha "$deskflow_sha" \
    --arg deskflow_size "$deskflow_size" --arg deskflow_build_id "$deskflow_build_id" \
    --arg core_path "$deskflow_core_artifact" --arg core_sha "$deskflow_core_sha" \
    --arg core_size "$deskflow_core_size" --arg core_build_id "$deskflow_core_build_id" \
    --arg generated_at "$generated_at_utc" \
    '{
      schema_version: 1,
      kind: $kind,
      protocol_version: $protocol_version,
      sidecar_protocol_version: $sidecar_protocol_version,
      upstream: {commit: $head, detached_head: true},
      source: {
        root: $source_root,
        tracked_patch: {sha256: $patch_sha, size_bytes: ($patch_size | tonumber)},
        modified_tracked_files: $tracked[0],
        untracked_source_files: $untracked[0],
        critical_files: $critical[0]
      },
      build: {
        directory: $build_directory,
        generator: "Ninja",
        build_type: $build_type,
        cmake: {
          executable: $cmake_executable,
          version: $cmake_version,
          executable_sha256: $cmake_executable_sha,
          cache_sha256: $cmake_cache_sha,
          cache_size_bytes: ($cmake_cache_size | tonumber),
          verify_globs_sha256: $verify_globs_sha,
          verify_globs_size_bytes: ($verify_globs_size | tonumber)
        },
        ninja: {
          executable: $ninja_executable,
          version: $ninja_version,
          executable_sha256: $ninja_executable_sha,
          build_file_sha256: $build_ninja_sha,
          build_file_size_bytes: ($build_ninja_size | tonumber),
          rules_file_sha256: $rules_ninja_sha,
          rules_file_size_bytes: ($rules_ninja_size | tonumber),
          pending_rebuild: false
        },
        live_acceptance: {
          enabled: true,
          socket_kind: "af_unix",
          peer_auth: "so_peercred_same_uid",
          arm_magic: "VFARM001",
          receipt_magic: "VFRCP001",
          receipt_size: 568,
          protocol_version: $protocol_version,
          sidecar_protocol_version: $sidecar_protocol_version,
          core_query: true
        },
        compilers: {
          c: {path: $c_path, version: $c_version, executable_sha256: $c_sha},
          cxx: {path: $cxx_path, version: $cxx_version, executable_sha256: $cxx_sha}
        }
      },
      artifacts: {
        deskflow: {
          source_path: $deskflow_path,
          sha256: $deskflow_sha,
          size_bytes: ($deskflow_size | tonumber),
          elf_build_id: $deskflow_build_id
        },
        deskflow_core: {
          source_path: $core_path,
          sha256: $core_sha,
          size_bytes: ($core_size | tonumber),
          elf_build_id: $core_build_id
        }
      },
      generated_at_utc: $generated_at
    }' >"$manifest_tmp"

# Catch source, configuration, and artifact changes that race generation.
[[ $(git -C "$source_dir" rev-parse --verify HEAD) == "$head_commit" ]] ||
    die 'source HEAD changed while provenance was generated'
if git -C "$source_dir" symbolic-ref -q HEAD >/dev/null; then
    die 'source left detached HEAD while provenance was generated'
fi
snapshot_source after
validate_live_acceptance_capability
cmp -s "$tmp_dir/before.patch.identity" "$tmp_dir/after.patch.identity" ||
    die 'tracked patch changed while provenance was generated'
for suffix in tracked.json untracked.json critical.json; do
    cmp -s "$tmp_dir/before.$suffix" "$tmp_dir/after.$suffix" ||
        die 'source dirty set changed while provenance was generated'
done
[[ $(sha256 "$build_dir/CMakeCache.txt") == "$cmake_cache_sha" &&
   $(file_size "$build_dir/CMakeCache.txt") == "$cmake_cache_size" ]] ||
    die 'CMake configuration changed while provenance was generated'
[[ $(sha256 "$build_dir/build.ninja") == "$build_ninja_sha" &&
   $(file_size "$build_dir/build.ninja") == "$build_ninja_size" ]] ||
    die 'Ninja build file changed while provenance was generated'
[[ $(sha256 "$build_dir/CMakeFiles/rules.ninja") == "$rules_ninja_sha" &&
   $(file_size "$build_dir/CMakeFiles/rules.ninja") == "$rules_ninja_size" ]] ||
    die 'Ninja rules file changed while provenance was generated'
[[ $(sha256 "$build_dir/CMakeFiles/VerifyGlobs.cmake") == "$verify_globs_sha" &&
   $(file_size "$build_dir/CMakeFiles/VerifyGlobs.cmake") == "$verify_globs_size" ]] ||
    die 'CMake VerifyGlobs script changed while provenance was generated'
[[ $(sha256 "$deskflow_artifact") == "$deskflow_sha" &&
   $(file_size "$deskflow_artifact") == "$deskflow_size" &&
   $(elf_build_id "$deskflow_artifact") == "$deskflow_build_id" ]] ||
    die 'deskflow artifact changed while provenance was generated'
[[ $(sha256 "$deskflow_core_artifact") == "$deskflow_core_sha" &&
   $(file_size "$deskflow_core_artifact") == "$deskflow_core_size" &&
   $(elf_build_id "$deskflow_core_artifact") == "$deskflow_core_build_id" ]] ||
    die 'deskflow-core artifact changed while provenance was generated'
[[ $(sha256 "$cmake_executable") == "$cmake_executable_sha" &&
   $("$cmake_executable" --version | sed -n '1p') == "$cmake_version" ]] ||
    die 'CMake executable changed while provenance was generated'
[[ $(sha256 "$ninja_executable") == "$ninja_executable_sha" &&
   $("$ninja_executable" --version) == "$ninja_version" ]] ||
    die 'Ninja executable changed while provenance was generated'
[[ $(sha256 "$c_compiler") == "$c_executable_sha" &&
   $("$c_compiler" --version | sed -n '1p') == "$c_version" ]] ||
    die 'C compiler changed while provenance was generated'
[[ $(sha256 "$cxx_compiler") == "$cxx_executable_sha" &&
   $("$cxx_compiler" --version | sed -n '1p') == "$cxx_version" ]] ||
    die 'C++ compiler changed while provenance was generated'
ninja_is_clean "$tmp_dir/ninja-after.log"
ninja_is_clean "$tmp_dir/ninja-targets-after.log" bin/deskflow bin/deskflow-core

# The terminal snapshot follows every command that can observe or update build
# metadata. It narrows the final publication race to the unavoidable interval
# between these pathname checks and the no-clobber hard-link publication.
snapshot_source terminal
validate_live_acceptance_capability
cmp -s "$tmp_dir/before.patch.identity" "$tmp_dir/terminal.patch.identity" ||
    die 'tracked patch changed before provenance publication'
for suffix in tracked.json untracked.json critical.json; do
    cmp -s "$tmp_dir/before.$suffix" "$tmp_dir/terminal.$suffix" ||
        die 'source dirty set changed before provenance publication'
done
[[ $(sha256 "$build_dir/CMakeCache.txt") == "$cmake_cache_sha" &&
   $(file_size "$build_dir/CMakeCache.txt") == "$cmake_cache_size" &&
   $(sha256 "$build_dir/build.ninja") == "$build_ninja_sha" &&
   $(file_size "$build_dir/build.ninja") == "$build_ninja_size" &&
   $(sha256 "$build_dir/CMakeFiles/rules.ninja") == "$rules_ninja_sha" &&
   $(file_size "$build_dir/CMakeFiles/rules.ninja") == "$rules_ninja_size" &&
   $(sha256 "$build_dir/CMakeFiles/VerifyGlobs.cmake") == "$verify_globs_sha" &&
   $(file_size "$build_dir/CMakeFiles/VerifyGlobs.cmake") == "$verify_globs_size" ]] ||
    die 'build configuration changed before provenance publication'
[[ $(sha256 "$deskflow_artifact") == "$deskflow_sha" &&
   $(file_size "$deskflow_artifact") == "$deskflow_size" &&
   $(elf_build_id "$deskflow_artifact") == "$deskflow_build_id" &&
   $(sha256 "$deskflow_core_artifact") == "$deskflow_core_sha" &&
   $(file_size "$deskflow_core_artifact") == "$deskflow_core_size" &&
   $(elf_build_id "$deskflow_core_artifact") == "$deskflow_core_build_id" ]] ||
    die 'Deskflow artifacts changed before provenance publication'
[[ $(sha256 "$cmake_executable") == "$cmake_executable_sha" &&
   $("$cmake_executable" --version | sed -n '1p') == "$cmake_version" &&
   $(sha256 "$ninja_executable") == "$ninja_executable_sha" &&
   $("$ninja_executable" --version) == "$ninja_version" &&
   $(sha256 "$c_compiler") == "$c_executable_sha" &&
   $("$c_compiler" --version | sed -n '1p') == "$c_version" &&
   $(sha256 "$cxx_compiler") == "$cxx_executable_sha" &&
   $("$cxx_compiler" --version | sed -n '1p') == "$cxx_version" ]] ||
    die 'build tool identity changed before provenance publication'

chmod 0600 "$manifest_tmp"
ln -- "$manifest_tmp" "$output" || die "failed to publish manifest without overwrite: $output"
manifest_sha=$(sha256 "$output")
printf 'Deskflow provenance manifest: %s\n' "$output"
printf 'Deskflow provenance SHA-256: %s\n' "$manifest_sha"
