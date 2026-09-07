#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
packager=$(cd -- "$script_dir/.." && pwd -P)/package-windows-source.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-package-test.XXXXXXXX")
cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_not_listed() {
    local pattern=$1
    local listing=$2
    if grep -Eq -- "$pattern" "$listing"; then
        fail "archive unexpectedly contains pattern: $pattern"
    fi
}

fixture="$test_root/fixture"
mkdir -p \
    "$fixture/protocol/viewflow/v1" \
    "$fixture/crates/demo/src" \
    "$fixture/.agents/state" \
    "$fixture/.codex/state" \
    "$fixture/crates/demo/.agents/state" \
    "$fixture/crates/demo/.codex/state" \
    "$fixture/docs"
printf '[workspace]\nmembers = ["crates/demo"]\n' >"$fixture/Cargo.toml"
printf '# locked\n' >"$fixture/Cargo.lock"
printf 'syntax = "proto3";\n' >"$fixture/protocol/viewflow/v1/control.proto"
printf 'fn main() {}\n' >"$fixture/crates/demo/src/main.rs"
printf 'allowed space\n' >"$fixture/docs/path with spaces.md"
printf 'exclude root agents\n' >"$fixture/.agents/state/trap"
printf 'exclude root codex\n' >"$fixture/.codex/state/trap"
printf 'exclude nested agents\n' >"$fixture/crates/demo/.agents/state/trap"
printf 'exclude nested codex\n' >"$fixture/crates/demo/.codex/state/trap"
chmod 0755 "$fixture/crates/demo/src/main.rs"

archive_one="$test_root/one package.tar.gz"
archive_two="$test_root/two package.tar.gz"
output_one=$($packager --source "$fixture" "$archive_one")

touch -d '2038-01-19 03:14:07 UTC' \
    "$fixture/Cargo.toml" \
    "$fixture/Cargo.lock" \
    "$fixture/protocol/viewflow/v1/control.proto" \
    "$fixture/crates/demo/src/main.rs" \
    "$fixture/docs/path with spaces.md"
chmod 0600 "$fixture/crates/demo/src/main.rs"
chmod 0700 "$fixture/crates" "$fixture/crates/demo" "$fixture/docs"
output_two=$($packager --source "$fixture" "$archive_two")

hash_one=$(sha256sum -- "$archive_one" | cut -d ' ' -f 1)
hash_two=$(sha256sum -- "$archive_two" | cut -d ' ' -f 1)
[[ $hash_one == "$hash_two" ]] || fail 'archive changed when only mtimes changed'
grep -Fxq "archive_sha256=$hash_one" <<<"$output_one" || \
    fail 'first run did not print the archive SHA256'
grep -Fxq "archive_sha256=$hash_two" <<<"$output_two" || \
    fail 'second run did not print the archive SHA256'
(
    cd "$test_root"
    sha256sum --strict --check 'one package.tar.gz.sha256' >/dev/null
) || fail 'archive checksum sidecar does not verify the archive'

manifest_hash=$(sha256sum -- "$archive_one.manifest.sha256" | cut -d ' ' -f 1)
grep -Fxq "manifest_sha256=$manifest_hash" <<<"$output_one" || \
    fail 'run did not print the manifest SHA256'
cmp --silent \
    "$archive_one.manifest.sha256" \
    "$archive_two.manifest.sha256" || \
    fail 'manifest changed when only mtimes changed'

listing="$test_root/archive-list.txt"
tar -tzf "$archive_one" >"$listing"
grep -Fxq 'viewflow-source/Cargo.toml' "$listing" || \
    fail 'Cargo.toml is absent from the archive'
grep -Fxq 'viewflow-source/Cargo.lock' "$listing" || \
    fail 'Cargo.lock is absent from the archive'
grep -Fxq 'viewflow-source/protocol/viewflow/v1/control.proto' "$listing" || \
    fail 'control.proto is absent from the archive'
grep -Fxq 'viewflow-source/docs/path with spaces.md' "$listing" || \
    fail 'allowed path containing spaces is absent from the archive'
grep -Fxq 'viewflow-source/SOURCE-MANIFEST.sha256' "$listing" || \
    fail 'internal manifest is absent from the archive'
assert_not_listed '(^|/)\.git(/|$)' "$listing"
assert_not_listed '(^|/)\.agents(/|$)' "$listing"
assert_not_listed '(^|/)\.codex(/|$)' "$listing"
assert_not_listed '(^|/)target(/|$)' "$listing"

extract_root="$test_root/extracted"
mkdir -p "$extract_root"
tar -xzf "$archive_one" -C "$extract_root"
cmp --silent \
    "$archive_one.manifest.sha256" \
    "$extract_root/viewflow-source/SOURCE-MANIFEST.sha256" || \
    fail 'external and internal manifests differ'
(
    cd "$extract_root"
    sha256sum --strict --check '../one package.tar.gz.manifest.sha256' >/dev/null
) || fail 'manifest does not verify the extracted source files'
[[ $(stat -c '%a' "$extract_root/viewflow-source/crates/demo/src/main.rs") == 644 ]] || \
    fail 'source file mode was not normalized to 0644'
[[ $(stat -c '%a' "$extract_root/viewflow-source/crates/demo/src") == 755 ]] || \
    fail 'source directory mode was not normalized to 0755'
for published_artifact in \
    "$archive_one" \
    "$archive_one.manifest.sha256" \
    "$archive_one.sha256"; do
    [[ $(stat -c '%a' "$published_artifact") == 644 ]] || \
        fail "published artifact mode was not normalized to 0644: $published_artifact"
done

verbose_listing="$test_root/archive-verbose-list.txt"
TZ=UTC tar --numeric-owner --full-time -tvzf "$archive_one" >"$verbose_listing"
if awk '
    $2 != "0/0" { bad_owner = 1 }
    $4 != "1970-01-01" || $5 != "00:00:00" { bad_time = 1 }
    /^d/ && $1 != "drwxr-xr-x" { bad_mode = 1 }
    /^-/ && $1 != "-rw-r--r--" { bad_mode = 1 }
    END { exit bad_owner || bad_time || bad_mode }
' "$verbose_listing"; then
    :
else
    fail 'archive owner/group or timestamp metadata is not normalized'
fi

for missing_path in \
    Cargo.toml \
    Cargo.lock \
    protocol/viewflow/v1/control.proto; do
    incomplete="$test_root/incomplete-${missing_path//\//-}"
    cp -a -- "$fixture" "$incomplete"
    rm -f -- "$incomplete/$missing_path"
    if $packager --source "$incomplete" "$test_root/missing.tar.gz" \
        >"$test_root/missing.stdout" 2>"$test_root/missing.stderr"; then
        fail "packager accepted fixture missing $missing_path"
    fi
    grep -Fq "required source file is missing: $missing_path" \
        "$test_root/missing.stderr" || \
        fail "missing-file error did not identify $missing_path"
done

if $packager --source "$fixture" "$fixture/output.tar.gz" \
    >"$test_root/in-tree.stdout" 2>"$test_root/in-tree.stderr"; then
    fail 'packager accepted an output inside the source root'
fi
grep -Fq 'output must be outside the source root' "$test_root/in-tree.stderr" || \
    fail 'in-tree output rejection was not explained'

directory_output="$test_root/archive-directory"
mkdir "$directory_output"
if $packager --source "$fixture" "$directory_output" \
    >"$test_root/directory.stdout" 2>"$test_root/directory.stderr"; then
    fail 'packager accepted a directory as the archive output'
fi
grep -Fq 'artifact path is not a regular file' "$test_root/directory.stderr" || \
    fail 'directory output rejection was not explained'

assert_forbidden_workspace_rejection() {
    local fixture_name=$1
    local relative_path=$2
    local path_type=$3
    local invalid_fixture="$test_root/$fixture_name"
    cp -a -- "$fixture" "$invalid_fixture"
    mkdir -p -- "$(dirname -- "$invalid_fixture/$relative_path")"
    if [[ $path_type == directory ]]; then
        mkdir -- "$invalid_fixture/$relative_path"
    else
        printf 'forbidden\n' >"$invalid_fixture/$relative_path"
    fi
    if $packager --source "$invalid_fixture" "$test_root/$fixture_name.tar.gz" \
        >"$test_root/$fixture_name.stdout" \
        2>"$test_root/$fixture_name.stderr"; then
        fail "packager accepted forbidden workspace path: $relative_path"
    fi
    grep -Fq 'forbidden workspace path in source tree' \
        "$test_root/$fixture_name.stderr" || \
        fail "forbidden workspace rejection was not explained: $relative_path"
}

assert_forbidden_workspace_rejection root-git-directory '.git' directory
assert_forbidden_workspace_rejection root-git-file '.GIT' file
assert_forbidden_workspace_rejection nested-git-file \
    'crates/demo/src/.git' file
assert_forbidden_workspace_rejection root-target-file 'target' file
assert_forbidden_workspace_rejection nested-target-directory \
    'crates/demo/Target' directory

assert_windows_rejection() {
    local fixture_name=$1
    local relative_path=$2
    local expected_error=$3
    local invalid_fixture="$test_root/$fixture_name"
    cp -a -- "$fixture" "$invalid_fixture"
    mkdir -p -- "$(dirname -- "$invalid_fixture/$relative_path")"
    printf 'invalid\n' >"$invalid_fixture/$relative_path"
    if $packager --source "$invalid_fixture" "$test_root/$fixture_name.tar.gz" \
        >"$test_root/$fixture_name.stdout" \
        2>"$test_root/$fixture_name.stderr"; then
        fail "packager accepted Windows-invalid path: $relative_path"
    fi
    grep -Fq "$expected_error" "$test_root/$fixture_name.stderr" || \
        fail "Windows-invalid rejection was not explained: $relative_path"
}

assert_windows_rejection \
    invalid-character \
    'docs/bad:name.txt' \
    'source path is not representable on Windows'
assert_windows_rejection \
    invalid-backslash \
    'docs/bad\name.txt' \
    'source path is not representable on Windows'
assert_windows_rejection \
    invalid-line-feed \
    $'docs/bad\nname.txt' \
    'source path contains a line break'
assert_windows_rejection \
    invalid-carriage-return \
    $'docs/bad\rname.txt' \
    'source path contains a line break'
assert_windows_rejection \
    invalid-directory-character \
    'docs/bad:name/nested.txt' \
    'source path is not representable on Windows'
assert_windows_rejection \
    reserved-device \
    'docs/NUL.txt' \
    'source path uses a reserved Windows device name'
assert_windows_rejection \
    trailing-dot \
    'docs/trailing.' \
    'source path has a Windows-unsafe trailing character'
assert_windows_rejection \
    reserved-manifest \
    'source-manifest.sha256' \
    'source path is reserved by the packager'
assert_windows_rejection \
    reserved-manifest-directory \
    'SOURCE-MANIFEST.sha256/nested.txt' \
    'source path is reserved by the packager'
assert_windows_rejection \
    reserved-nested-manifest-directory \
    'docs/source-manifest.sha256/nested.txt' \
    'source path is reserved by the packager'
assert_windows_rejection \
    reserved-manifest-inside-excluded-tree \
    '.agents/SOURCE-MANIFEST.sha256' \
    'source path is reserved by the packager'

assert_windows_rejection \
    deprecated-packager-entry \
    'deploy/windows/package-viewflow-source.sh' \
    'deprecated Windows source packager entry point exists'

empty_manifest_fixture="$test_root/reserved-empty-manifest-directory"
cp -a -- "$fixture" "$empty_manifest_fixture"
mkdir "$empty_manifest_fixture/source-manifest.sha256"
if $packager --source "$empty_manifest_fixture" \
    "$test_root/reserved-empty-manifest-directory.tar.gz" \
    >"$test_root/reserved-empty-manifest-directory.stdout" \
    2>"$test_root/reserved-empty-manifest-directory.stderr"; then
    fail 'packager accepted an empty directory using the reserved manifest name'
fi
grep -Fq 'source path is reserved by the packager' \
    "$test_root/reserved-empty-manifest-directory.stderr" || \
    fail 'empty reserved-manifest directory rejection was not explained'

unknown_root_fixture="$test_root/unknown-root-file"
cp -a -- "$fixture" "$unknown_root_fixture"
printf 'editor log\n' >"$unknown_root_fixture/nvim.log"
if $packager --source "$unknown_root_fixture" \
    "$test_root/unknown-root-file.tar.gz" \
    >"$test_root/unknown-root-file.stdout" \
    2>"$test_root/unknown-root-file.stderr"; then
    fail 'packager accepted an unknown top-level nvim.log file'
fi
grep -Fq 'unexpected top-level source path: nvim.log' \
    "$test_root/unknown-root-file.stderr" || \
    fail 'unknown top-level nvim.log rejection was not explained'

unknown_root_directory_fixture="$test_root/unknown-root-directory"
cp -a -- "$fixture" "$unknown_root_directory_fixture"
mkdir "$unknown_root_directory_fixture/scratch"
printf 'temporary\n' >"$unknown_root_directory_fixture/scratch/output.txt"
if $packager --source "$unknown_root_directory_fixture" \
    "$test_root/unknown-root-directory.tar.gz" \
    >"$test_root/unknown-root-directory.stdout" \
    2>"$test_root/unknown-root-directory.stderr"; then
    fail 'packager accepted an unknown top-level directory'
fi
grep -Fq 'unexpected top-level source path: scratch' \
    "$test_root/unknown-root-directory.stderr" || \
    fail 'unknown top-level directory rejection was not explained'

case_fixture="$test_root/case-collision"
cp -a -- "$fixture" "$case_fixture"
printf 'upper\n' >"$case_fixture/docs/Case.txt"
printf 'lower\n' >"$case_fixture/docs/case.txt"
if $packager --source "$case_fixture" "$test_root/case-collision.tar.gz" \
    >"$test_root/case.stdout" 2>"$test_root/case.stderr"; then
    fail 'packager accepted source paths that collide on Windows'
fi
grep -Fq 'source paths collide on Windows' "$test_root/case.stderr" || \
    fail 'case-collision rejection was not explained'

ln -s -- ../Cargo.toml "$fixture/docs/source-link"
printf 'old archive\n' >"$test_root/symlink.tar.gz"
printf 'old manifest\n' >"$test_root/symlink.tar.gz.manifest.sha256"
printf 'old hash\n' >"$test_root/symlink.tar.gz.sha256"
if $packager --source "$fixture" "$test_root/symlink.tar.gz" \
    >"$test_root/symlink.stdout" 2>"$test_root/symlink.stderr"; then
    fail 'packager accepted a source symlink outside the manifest model'
fi
grep -Fq 'unsupported non-regular source path: docs/source-link' \
    "$test_root/symlink.stderr" || \
    fail 'symlink rejection was not explained'
[[ $(<"$test_root/symlink.tar.gz") == 'old archive' ]] || \
    fail 'failed package replaced the prior archive'
[[ $(<"$test_root/symlink.tar.gz.manifest.sha256") == 'old manifest' ]] || \
    fail 'failed package replaced the prior manifest'
[[ $(<"$test_root/symlink.tar.gz.sha256") == 'old hash' ]] || \
    fail 'failed package replaced the prior archive checksum'
rm -f -- "$fixture/docs/source-link"

output_symlink_target="$test_root/output-symlink-target"
printf 'do not replace\n' >"$output_symlink_target"
ln -s -- "$output_symlink_target" "$test_root/output-symlink.tar.gz"
if $packager --source "$fixture" "$test_root/output-symlink.tar.gz" \
    >"$test_root/output-symlink.stdout" \
    2>"$test_root/output-symlink.stderr"; then
    fail 'packager accepted a symlink as an archive output'
fi
grep -Fq 'artifact path is not a regular file' \
    "$test_root/output-symlink.stderr" || \
    fail 'output symlink rejection was not explained'
[[ $(<"$output_symlink_target") == 'do not replace' ]] || \
    fail 'output symlink target was modified'

if "$packager" --source "$fixture" "$test_root/bad\\name.tar.gz" \
    >"$test_root/output-name.stdout" 2>"$test_root/output-name.stderr"; then
    fail 'packager accepted a Windows-invalid output filename'
fi
grep -Fq 'output filename is not representable on Windows' \
    "$test_root/output-name.stderr" || \
    fail 'Windows-invalid output filename rejection was not explained'
if "$packager" --source "$fixture" "$test_root/NUL.tar.gz" \
    >"$test_root/output-device.stdout" 2>"$test_root/output-device.stderr"; then
    fail 'packager accepted a reserved Windows device output filename'
fi
grep -Fq 'output filename uses a reserved Windows device name' \
    "$test_root/output-device.stderr" || \
    fail 'reserved output device-name rejection was not explained'

cp_real=$(command -v cp)
cp_shim_dir="$test_root/cp-shims"
mkdir "$cp_shim_dir"
cat >"$cp_shim_dir/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$VIEWFLOW_TEST_REAL_CP" "$@"
if [[ -n ${VIEWFLOW_TEST_MUTATE_DIRECTORY:-} &&
    ! -e ${VIEWFLOW_TEST_MUTATE_DIRECTORY_ONCE_FILE:-} ]]; then
    chmod 0755 -- "$VIEWFLOW_TEST_MUTATE_DIRECTORY"
    : >"$VIEWFLOW_TEST_MUTATE_DIRECTORY_ONCE_FILE"
fi
EOF
chmod 0755 "$cp_shim_dir/cp"
if PATH="$cp_shim_dir:$PATH" \
    VIEWFLOW_TEST_REAL_CP="$cp_real" \
    VIEWFLOW_TEST_MUTATE_DIRECTORY="$fixture/docs" \
    VIEWFLOW_TEST_MUTATE_DIRECTORY_ONCE_FILE="$test_root/cp-mutated-once" \
    "$packager" --source "$fixture" "$test_root/directory-race.tar.gz" \
    >"$test_root/directory-race.stdout" \
    2>"$test_root/directory-race.stderr"; then
    fail 'packager accepted a source directory that changed while packaging'
fi
grep -Fq 'source directory changed while packaging: docs' \
    "$test_root/directory-race.stderr" || \
    fail 'source-directory identity failure was not explained'
chmod 0700 "$fixture/docs"

mv_real=$(command -v mv)
shim_dir="$test_root/shims"
mkdir "$shim_dir"
cat >"$shim_dir/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=
for argument in "$@"; do
    destination=$argument
done
if [[ -n ${VIEWFLOW_TEST_FAIL_MV_DEST:-} &&
    $destination == "$VIEWFLOW_TEST_FAIL_MV_DEST" &&
    ! -e ${VIEWFLOW_TEST_FAIL_MV_ONCE_FILE:-} ]]; then
    : >"$VIEWFLOW_TEST_FAIL_MV_ONCE_FILE"
    exit 73
fi
"$VIEWFLOW_TEST_REAL_MV" "$@"
if [[ -n ${VIEWFLOW_TEST_CORRUPT_MV_DEST:-} &&
    $destination == "$VIEWFLOW_TEST_CORRUPT_MV_DEST" &&
    ! -e ${VIEWFLOW_TEST_CORRUPT_MV_ONCE_FILE:-} ]]; then
    printf 'corrupt\n' >>"$destination"
    : >"$VIEWFLOW_TEST_CORRUPT_MV_ONCE_FILE"
fi
EOF
chmod 0755 "$shim_dir/mv"

transaction_archive="$test_root/transaction.tar.gz"
printf 'old archive\n' >"$transaction_archive"
printf 'old manifest\n' >"$transaction_archive.manifest.sha256"
printf 'old hash\n' >"$transaction_archive.sha256"
if PATH="$shim_dir:$PATH" \
    VIEWFLOW_TEST_REAL_MV="$mv_real" \
    VIEWFLOW_TEST_FAIL_MV_DEST="$transaction_archive" \
    VIEWFLOW_TEST_FAIL_MV_ONCE_FILE="$test_root/mv-failed-once" \
    $packager --source "$fixture" "$transaction_archive" \
    >"$test_root/transaction.stdout" \
    2>"$test_root/transaction.stderr"; then
    fail 'packager succeeded after an injected archive publication failure'
fi
grep -Fq 'failed to publish source package artifact' \
    "$test_root/transaction.stderr" || \
    fail "publication failure was not explained: $(<"$test_root/transaction.stderr")"
[[ $(<"$transaction_archive") == 'old archive' ]] || \
    fail 'publication rollback did not restore the prior archive'
[[ $(<"$transaction_archive.manifest.sha256") == 'old manifest' ]] || \
    fail 'publication rollback did not restore the prior manifest'
[[ $(<"$transaction_archive.sha256") == 'old hash' ]] || \
    fail 'publication rollback did not restore the prior archive checksum'

corrupt_archive="$test_root/corrupt-transaction.tar.gz"
printf 'old archive\n' >"$corrupt_archive"
printf 'old manifest\n' >"$corrupt_archive.manifest.sha256"
printf 'old hash\n' >"$corrupt_archive.sha256"
if PATH="$shim_dir:$PATH" \
    VIEWFLOW_TEST_REAL_MV="$mv_real" \
    VIEWFLOW_TEST_CORRUPT_MV_DEST="$corrupt_archive.manifest.sha256" \
    VIEWFLOW_TEST_CORRUPT_MV_ONCE_FILE="$test_root/mv-corrupted-once" \
    "$packager" --source "$fixture" "$corrupt_archive" \
    >"$test_root/corrupt-transaction.stdout" \
    2>"$test_root/corrupt-transaction.stderr"; then
    fail 'packager accepted an artifact corrupted during publication'
fi
grep -Fq 'published source package artifact failed verification' \
    "$test_root/corrupt-transaction.stderr" || \
    fail 'published artifact verification failure was not explained'
[[ $(<"$corrupt_archive") == 'old archive' ]] || \
    fail 'corruption rollback did not restore the prior archive'
[[ $(<"$corrupt_archive.manifest.sha256") == 'old manifest' ]] || \
    fail 'corruption rollback did not restore the prior manifest'
[[ $(<"$corrupt_archive.sha256") == 'old hash' ]] || \
    fail 'corruption rollback did not restore the prior archive checksum'

echo 'package-windows-source tests passed'
