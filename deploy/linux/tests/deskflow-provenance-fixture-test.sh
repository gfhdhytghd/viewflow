#!/usr/bin/env bash

# End-to-end fixtures for the Deskflow source/build/artifact provenance
# generator and its standalone verifier. Everything lives in one temporary
# detached Git worktree; no Deskflow source or installed runtime is touched.

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
readonly LINUX_DIR
readonly GENERATOR=$LINUX_DIR/generate-deskflow-provenance.sh
readonly CHECKER=$LINUX_DIR/check-deskflow-provenance.sh

fail() {
    printf 'Deskflow provenance fixture test failed: %s\n' "$*" >&2
    exit 1
}

for command_name in cmake git jq ninja readelf sha256sum stat; do
    command -v "$command_name" >/dev/null || fail "required command is unavailable: $command_name"
done
[[ -x $GENERATOR ]] || fail "generator is not executable: $GENERATOR"
[[ -x $CHECKER ]] || fail "checker is not executable: $CHECKER"

tmp_dir=$(mktemp -d /tmp/viewflow-deskflow-provenance-fixture.XXXXXXXX)
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$tmp_dir"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

readonly source_dir=$tmp_dir/source
readonly build_dir=$source_dir/build-local
readonly manifest=$tmp_dir/provenance.json
readonly deskflow=$build_dir/bin/deskflow
readonly deskflow_core=$build_dir/bin/deskflow-core
readonly alternate_elf=$tmp_dir/alternate-elf

readonly -a tracked_paths=(
    src/apps/deskflow-core/deskflow-core.cpp
    src/lib/arch/unix/ArchMultithreadPosix.cpp
    src/lib/platform/PortalInputCapture.cpp
    src/lib/platform/PortalInputCapture.h
    src/lib/server/CMakeLists.txt
    src/lib/server/Server.cpp
    src/lib/server/Server.h
    src/unittests/server/CMakeLists.txt
)
readonly -a untracked_paths=(
    src/lib/server/ViewflowSidecarClient.cpp
    src/lib/server/ViewflowSidecarClient.h
    src/unittests/server/ViewflowSidecarClientTests.cpp
    src/unittests/server/ViewflowSidecarClientTests.h
)

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

write_build_files() {
    local ninja_output_variable
    printf -v ninja_output_variable '%s' "\$out"
    printf '%s\n' \
        'CMAKE_GENERATOR:INTERNAL=Ninja' \
        'CMAKE_BUILD_TYPE:STRING=RelWithDebInfo' \
        'CMAKE_C_COMPILER:FILEPATH=/usr/bin/cc' \
        'CMAKE_CXX_COMPILER:FILEPATH=/usr/bin/c++' \
        >"$build_dir/CMakeCache.txt"
    printf '%s\n' \
        'ninja_required_version = 1.3' \
        'include CMakeFiles/rules.ninja' \
        'build bin/deskflow: phony' \
        'build bin/deskflow-core: phony' \
        'build all: phony bin/deskflow bin/deskflow-core' \
        'default all' \
        >"$build_dir/build.ninja"
    printf '%s\n' \
        'rule create_pending_output' \
        "  command = /usr/bin/touch $ninja_output_variable" \
        >"$build_dir/CMakeFiles/rules.ninja"
    printf '%s\n' \
        '# Minimal CONFIGURE_DEPENDS fixture: the no-touch transform must be safe.' \
        'if(FALSE)' \
        '  file(TOUCH_NOCREATE "/does/not/exist/cmake.verify_globs")' \
        'endif()' \
        >"$build_dir/CMakeFiles/VerifyGlobs.cmake"
}

mkdir -p -- "$source_dir"
git -C "$source_dir" init -q
git -C "$source_dir" config user.name 'Viewflow Fixture'
git -C "$source_dir" config user.email 'viewflow-fixture.invalid@example.invalid'

for path in "${tracked_paths[@]}"; do
    mkdir -p -- "$source_dir/$(dirname -- "$path")"
    printf 'upstream fixture: %s\n' "$path" >"$source_dir/$path"
done
git -C "$source_dir" add -- "${tracked_paths[@]}"
git -C "$source_dir" commit -qm 'fixture upstream'
upstream_head=$(git -C "$source_dir" rev-parse HEAD)
readonly upstream_head
git -C "$source_dir" switch --detach -q "$upstream_head"

for path in "${tracked_paths[@]}"; do
    printf 'reviewed local modification: %s\n' "$path" >>"$source_dir/$path"
done
for path in "${untracked_paths[@]}"; do
    mkdir -p -- "$source_dir/$(dirname -- "$path")"
    printf 'reviewed untracked source: %s\n' "$path" >"$source_dir/$path"
done

# The production generator requires the reviewed live core query capability,
# while this fixture deliberately avoids a real Deskflow build.
cat >"$source_dir/src/lib/server/ViewflowSidecarClient.cpp" <<'EOF'
#include <array>
#include <cstddef>
#include <string_view>
constexpr std::array<uint8_t, 8> kAcceptanceArmMagic = {'V', 'F', 'A', 'R', 'M', '0', '0', '1'};
constexpr std::array<uint8_t, 8> kAcceptanceReceiptMagic = {'V', 'F', 'R', 'C', 'P', '0', '0', '1'};
constexpr size_t kAcceptanceReceiptBytes = 568;
void capability_fixture(int fd, char **argv) {
  ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  ::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, nullptr, nullptr);
  std::string_view query = std::string_view(argv[1]) == "--viewflow-acceptance-query";
  (void)query;
}
EOF
cat >"$source_dir/src/apps/deskflow-core/deskflow-core.cpp" <<'EOF'
int runViewflowAcceptanceQuery(int, char **);
int fixture_main(int argc, char **argv) {
  return runViewflowAcceptanceQuery(argc, argv);
}
EOF

mkdir -p -- "$build_dir/CMakeFiles" "$build_dir/bin"
write_build_files
cp -- /usr/bin/true "$deskflow"
cp -- /usr/bin/false "$deskflow_core"
cp -- /usr/bin/git "$alternate_elf"
readelf -n -- "$deskflow" | grep -Fq 'Build ID:' || fail 'deskflow ELF fixture has no build ID'
readelf -n -- "$deskflow_core" | grep -Fq 'Build ID:' || fail 'deskflow-core ELF fixture has no build ID'
readelf -n -- "$alternate_elf" | grep -Fq 'Build ID:' || fail 'alternate ELF fixture has no build ID'

generate() {
    local output=$1
    "$GENERATOR" \
        --source-dir "$source_dir" \
        --build-dir "$build_dir" \
        --deskflow "$deskflow" \
        --deskflow-core "$deskflow_core" \
        --output "$output" \
        --expected-upstream-head "$upstream_head"
}

check_manifest() {
    local document=$1 document_sha=$2
    local deskflow_candidate=${3:-$deskflow}
    local deskflow_sha=${4:-$(sha256 "$deskflow_candidate")}
    local core_candidate=${5:-$deskflow_core}
    local core_sha=${6:-$(sha256 "$core_candidate")}
    "$CHECKER" \
        --manifest "$document" \
        --manifest-sha256 "$document_sha" \
        --deskflow-candidate "$deskflow_candidate" \
        --deskflow-sha256 "$deskflow_sha" \
        --deskflow-core-candidate "$core_candidate" \
        --deskflow-core-sha256 "$core_sha" \
        --expected-upstream-head "$upstream_head"
}

expect_check_rejected() {
    local name=$1 document=$2 document_sha=$3
    shift 3
    if check_manifest "$document" "$document_sha" "$@" >/dev/null 2>&1; then
        fail "invalid provenance was accepted: $name"
    fi
}

expect_current_state_rejected() {
    local name=$1
    if check_manifest "$manifest" "$(sha256 "$manifest")" >/dev/null 2>&1; then
        fail "current-state drift was accepted: $name"
    fi
}

expect_generation_rejected() {
    local name=$1 output=$tmp_dir/rejected-$1.json
    rm -f -- "$output"
    if generate "$output" >/dev/null 2>&1; then
        fail "invalid generation state was accepted: $name"
    fi
    [[ ! -e $output ]] || fail "rejected generation published a manifest: $name"
}

generate "$manifest" >/dev/null
[[ $(stat -c '%a' -- "$manifest") == 600 ]] || fail 'generated manifest mode is not 0600'
jq -e '.protocol_version == "2.1" and .sidecar_protocol_version == 3' \
    "$manifest" >/dev/null ||
    fail 'generated manifest does not bind the reviewed protocol claims'
jq -e '
    .build.live_acceptance == {
      enabled: true,
      socket_kind: "af_unix",
      peer_auth: "so_peercred_same_uid",
      arm_magic: "VFARM001",
      receipt_magic: "VFRCP001",
      receipt_size: 568,
      protocol_version: "2.1",
      sidecar_protocol_version: 3,
      core_query: true
    }
' "$manifest" >/dev/null ||
    fail 'generated manifest does not bind the reviewed live acceptance capability'
check_manifest "$manifest" "$(sha256 "$manifest")" >/dev/null ||
    fail 'valid generated manifest was rejected'

arbitrary_path_output=$tmp_dir/arbitrary-elf-path.json
if "$GENERATOR" \
    --source-dir "$source_dir" \
    --build-dir "$build_dir" \
    --deskflow "$alternate_elf" \
    --deskflow-core "$deskflow_core" \
    --output "$arbitrary_path_output" \
    --expected-upstream-head "$upstream_head" >/dev/null 2>&1; then
    fail 'arbitrary deskflow ELF path was accepted as a Ninja output'
fi
[[ ! -e $arbitrary_path_output ]] ||
    fail 'arbitrary deskflow ELF path rejection published a manifest'

hostile_repo=$tmp_dir/hostile-repository
hostile_manifest=$tmp_dir/hostile-environment-provenance.json
mkdir -p -- "$hostile_repo"
git -C "$hostile_repo" init -q
git -C "$hostile_repo" config user.name 'Hostile Git Environment Fixture'
git -C "$hostile_repo" config user.email 'hostile-git-fixture.invalid@example.invalid'
printf 'this repository must never supply provenance\n' >"$hostile_repo/decoy.txt"
git -C "$hostile_repo" add -- decoy.txt
git -C "$hostile_repo" commit -qm 'hostile environment decoy'
hostile_head=$(git -C "$hostile_repo" rev-parse HEAD)
[[ $hostile_head != "$upstream_head" ]] || fail 'hostile repository unexpectedly reused target HEAD'
env \
    GIT_DIR="$hostile_repo/.git" \
    GIT_WORK_TREE="$hostile_repo" \
    GIT_OBJECT_DIRECTORY="$hostile_repo/.git/objects" \
    GIT_NO_REPLACE_OBJECTS=0 \
    "$GENERATOR" \
        --source-dir "$source_dir" \
        --build-dir "$build_dir" \
        --deskflow "$deskflow" \
        --deskflow-core "$deskflow_core" \
        --output "$hostile_manifest" \
        --expected-upstream-head "$upstream_head" >/dev/null ||
    fail 'hostile inherited Git environment redirected provenance generation'
jq -e --arg head "$upstream_head" --arg root "$source_dir" \
    '.upstream.commit == $head and .source.root == $root' \
    "$hostile_manifest" >/dev/null ||
    fail 'hostile inherited Git environment changed recorded source identity'
check_manifest "$hostile_manifest" "$(sha256 "$hostile_manifest")" >/dev/null ||
    fail 'manifest generated under hostile inherited Git environment was rejected'

replacement_tree=$(git -C "$source_dir" rev-parse 'HEAD^{tree}')
replacement_commit=$(printf 'replacement fixture commit\n' |
    git -C "$source_dir" commit-tree "$replacement_tree")
git -C "$source_dir" replace "$upstream_head" "$replacement_commit"
expect_generation_rejected repository-local-replace-ref
git -C "$source_dir" replace -d "$upstream_head" >/dev/null

printf '%s\n' "$upstream_head" >"$source_dir/.git/info/grafts"
expect_generation_rejected repository-local-grafts
rm -f -- "$source_dir/.git/info/grafts"

mutant=$tmp_dir/extra-field.json
jq '.unexpected = true' "$manifest" >"$mutant"
expect_check_rejected extra-json-field "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/duplicate-field.json
sed '1s/{/{"kind":"duplicate-fixture",/' "$manifest" >"$mutant"
expect_check_rejected duplicate-json-field "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/protocol-version-value.json
jq '.protocol_version = "2.0"' "$manifest" >"$mutant"
expect_check_rejected protocol-version-value "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/sidecar-protocol-version-value.json
jq '.sidecar_protocol_version = 2' "$manifest" >"$mutant"
expect_check_rejected sidecar-protocol-version-value "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/protocol-version-omitted.json
jq 'del(.protocol_version)' "$manifest" >"$mutant"
expect_check_rejected protocol-version-omitted "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/sidecar-protocol-version-omitted.json
jq 'del(.sidecar_protocol_version)' "$manifest" >"$mutant"
expect_check_rejected sidecar-protocol-version-omitted "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/protocol-version-duplicate.json
sed '1s/{/{"protocol_version":"duplicate-fixture",/' "$manifest" >"$mutant"
expect_check_rejected protocol-version-duplicate "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/sidecar-protocol-version-duplicate.json
sed '1s/{/{"sidecar_protocol_version":999,/' "$manifest" >"$mutant"
expect_check_rejected sidecar-protocol-version-duplicate "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/live-acceptance-magic.json
jq '.build.live_acceptance.arm_magic = "VFARM999"' "$manifest" >"$mutant"
expect_check_rejected live-acceptance-magic "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/live-acceptance-receipt-size.json
jq '.build.live_acceptance.receipt_size = 567' "$manifest" >"$mutant"
expect_check_rejected live-acceptance-receipt-size "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/live-acceptance-peer-auth.json
jq '.build.live_acceptance.peer_auth = "none"' "$manifest" >"$mutant"
expect_check_rejected live-acceptance-peer-auth "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/live-acceptance-omitted.json
jq 'del(.build.live_acceptance)' "$manifest" >"$mutant"
expect_check_rejected live-acceptance-omitted "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/live-acceptance-extra.json
jq '.build.live_acceptance.extra = true' "$manifest" >"$mutant"
expect_check_rejected live-acceptance-extra "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/embedded-artifact-hash.json
jq '.artifacts.deskflow.sha256 = ("0" * 64)' "$manifest" >"$mutant"
expect_check_rejected embedded-artifact-hash "$mutant" "$(sha256 "$mutant")"

mutant=$tmp_dir/artifact-size.json
alternate_sha=$(sha256 "$alternate_elf")
jq --arg sha "$alternate_sha" '.artifacts.deskflow.sha256 = $sha' \
    "$manifest" >"$mutant"
expect_check_rejected artifact-size-mismatch "$mutant" "$(sha256 "$mutant")" \
    "$alternate_elf" "$alternate_sha"

mutant=$tmp_dir/artifact-build-id.json
jq '.artifacts.deskflow.elf_build_id = "0"' "$manifest" >"$mutant"
expect_check_rejected artifact-build-id-mismatch "$mutant" "$(sha256 "$mutant")"

wrong_sha=$(printf '0%.0s' {1..64})
expect_check_rejected artifact-cli-hash-mismatch "$manifest" "$(sha256 "$manifest")" \
    "$deskflow" "$wrong_sha"

tracked_drift_path=$source_dir/${tracked_paths[0]}
cp -- "$tracked_drift_path" "$tmp_dir/tracked.before"
printf 'unreviewed tracked drift\n' >>"$tracked_drift_path"
expect_current_state_rejected tracked-source-content
cp -- "$tmp_dir/tracked.before" "$tracked_drift_path"

untracked_drift_path=$source_dir/${untracked_paths[0]}
cp -- "$untracked_drift_path" "$tmp_dir/untracked.before"
printf 'unreviewed untracked drift\n' >>"$untracked_drift_path"
expect_current_state_rejected untracked-source-content
cp -- "$tmp_dir/untracked.before" "$untracked_drift_path"

cp -- "$source_dir/.git/info/exclude" "$tmp_dir/git-exclude.before"
printf '/ignored-fixture.cpp\n' >>"$source_dir/.git/info/exclude"
printf 'unreviewed ignored source drift\n' >"$source_dir/ignored-fixture.cpp"
expect_generation_rejected ignored-untracked-source
rm -f -- "$source_dir/ignored-fixture.cpp"
cp -- "$tmp_dir/git-exclude.before" "$source_dir/.git/info/exclude"

cp -- "$build_dir/CMakeCache.txt" "$tmp_dir/cache.before"
printf 'VIEWFLOW_FIXTURE_DRIFT:BOOL=ON\n' >>"$build_dir/CMakeCache.txt"
expect_current_state_rejected cmake-cache-identity
cp -- "$tmp_dir/cache.before" "$build_dir/CMakeCache.txt"

cp -- "$build_dir/build.ninja" "$tmp_dir/ninja.before"
printf '# unreviewed Ninja configuration drift\n' >>"$build_dir/build.ninja"
expect_current_state_rejected ninja-build-file-identity
cp -- "$tmp_dir/ninja.before" "$build_dir/build.ninja"

cp -- "$build_dir/CMakeFiles/rules.ninja" "$tmp_dir/rules.before"
printf '# unreviewed Ninja rules drift\n' >>"$build_dir/CMakeFiles/rules.ninja"
expect_current_state_rejected ninja-rules-file-identity
cp -- "$tmp_dir/rules.before" "$build_dir/CMakeFiles/rules.ninja"

printf '%s\n' \
    'ninja_required_version = 1.3' \
    'include CMakeFiles/rules.ninja' \
    'build bin/deskflow: phony' \
    'build bin/deskflow-core: phony' \
    'build pending-output: create_pending_output' \
    'build all: phony bin/deskflow bin/deskflow-core pending-output' \
    'default all' \
    >"$build_dir/build.ninja"
expect_generation_rejected pending-real-ninja-command
cp -- "$tmp_dir/ninja.before" "$build_dir/build.ninja"

check_manifest "$manifest" "$(sha256 "$manifest")" >/dev/null ||
    fail 'fixture state was not restored after negative cases'

printf 'Deskflow provenance fixture and mutation tests passed\n'
