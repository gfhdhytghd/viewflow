#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
    cat >&2 <<'EOF'
Usage: package-windows-source.sh [--source SOURCE_ROOT] OUTPUT.tar.gz

Create a reproducible Viewflow source snapshot for the native Windows build.
SOURCE_ROOT defaults to the tree containing this script, but a Git checkout or
tree containing Cargo build output is rejected. Prefer an explicit clean,
allowlisted staging tree. OUTPUT must be outside SOURCE_ROOT so an earlier
artifact can never enter a later snapshot.
EOF
}

source_root=
if [[ ${1:-} == --source ]]; then
    if (($# < 3)); then
        usage
        exit 2
    fi
    source_root=$2
    shift 2
fi

if (($# != 1)); then
    usage
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ -z $source_root ]]; then
    source_root=$(cd -- "$script_dir/../.." && pwd -P)
else
    source_root=$(cd -- "$source_root" && pwd -P)
fi

output=$1
output_dir=$(dirname -- "$output")
output_name=$(basename -- "$output")
if [[ $output_name == '.' || $output_name == '..' ||
    $output_name == *$'\n'* || $output_name == *$'\r'* ||
    $output_name == *$'\\'* || $output_name =~ [[:cntrl:]] ||
    $output_name == *'<'* || $output_name == *'>'* ||
    $output_name == *':'* || $output_name == *'"'* ||
    $output_name == *'|'* || $output_name == *'?'* ||
    $output_name == *'*'* || $output_name == *'.' ||
    $output_name == *' ' ]]; then
    echo "output filename is not representable on Windows: $output_name" >&2
    exit 1
fi
output_device_stem=${output_name%%.*}
case "${output_device_stem^^}" in
    CON | PRN | AUX | NUL | COM[1-9] | LPT[1-9])
        echo "output filename uses a reserved Windows device name: $output_name" >&2
        exit 1
        ;;
esac
if ! command -v realpath >/dev/null 2>&1; then
    echo 'required command is unavailable: realpath' >&2
    exit 1
fi
output_dir=$(realpath -m -- "$output_dir")
case "$output_dir" in
    "$source_root" | "$source_root"/*)
        echo "output must be outside the source root: $output_dir/$output_name" >&2
        exit 1
        ;;
esac
mkdir -p -- "$output_dir"
canonical_output_dir=$(cd -- "$output_dir" && pwd -P)
if [[ $canonical_output_dir != "$output_dir" ]]; then
    echo "output directory changed while resolving it: $output_dir" >&2
    exit 1
fi
output_path="$output_dir/$output_name"

case "$output_path" in
    "$source_root" | "$source_root"/*)
        echo "output must be outside the source root: $output_path" >&2
        exit 1
        ;;
esac
for artifact_path in \
    "$output_path" \
    "$output_path.manifest.sha256" \
    "$output_path.sha256"; do
    if [[ -L $artifact_path || (-e $artifact_path && ! -f $artifact_path) ]]; then
        echo "artifact path is not a regular file: $artifact_path" >&2
        exit 1
    fi
done

required_paths=(
    Cargo.toml
    Cargo.lock
    protocol/viewflow/v1/control.proto
)
for required_path in "${required_paths[@]}"; do
    if [[ ! -f "$source_root/$required_path" ]]; then
        echo "required source file is missing: $required_path" >&2
        exit 1
    fi
done

for command_name in cmp cp cut find gzip iconv mv realpath sha256sum sort stat tar; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "required command is unavailable: $command_name" >&2
        exit 1
    fi
done
if ! tar --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then
    echo 'GNU tar is required for reproducible archive metadata' >&2
    exit 1
fi

umask 022
stage=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-source.XXXXXXXX")
verify_root=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-source-verify.XXXXXXXX")
archive_tmp=$(mktemp "$output_dir/.viewflow-source-archive.XXXXXXXX")
manifest_tmp=$(mktemp "$output_dir/.viewflow-source-manifest.XXXXXXXX")
archive_hash_tmp=$(mktemp "$output_dir/.viewflow-source-hash.XXXXXXXX")
publish_backup_dir=$(mktemp -d "$output_dir/.viewflow-source-backup.XXXXXXXX")
publishing=0
publish_committed=0
artifact_paths=(
    "$output_path.manifest.sha256"
    "$output_path.sha256"
    "$output_path"
)
backup_present=(0 0 0)
backup_identities=('' '' '')
new_published=(0 0 0)
published_identities=('' '' '')
publish_backup_removed=0
output_dir_identity=$(stat -c '%d:%i:%f' -- "$output_dir")
publish_backup_dir_identity=$(stat -c '%d:%i:%f' -- "$publish_backup_dir")

assert_directory_identity() {
    local directory=$1
    local expected_identity=$2
    local description=$3

    if [[ ! -d $directory || -L $directory ||
        $(stat -c '%d:%i:%f' -- "$directory") != "$expected_identity" ]]; then
        echo "$description changed identity: $directory" >&2
        return 1
    fi
}

rollback_publish() {
    local index
    local rollback_failed=0

    if ! assert_directory_identity "$output_dir" "$output_dir_identity" \
        'output directory'; then
        return 1
    fi
    if ! assert_directory_identity "$publish_backup_dir" \
        "$publish_backup_dir_identity" 'publication backup directory'; then
        return 1
    fi

    for index in 2 1 0; do
        if ((new_published[index])); then
            current_published_identity=$(stat -c '%d:%i:%s:%y:%z:%f' -- \
                "${artifact_paths[index]}" 2>/dev/null || true)
            if [[ ! -f ${artifact_paths[index]} || -L ${artifact_paths[index]} ||
                $current_published_identity != "${published_identities[index]}" ]]; then
                echo "published artifact changed identity before rollback: ${artifact_paths[index]}" \
                    >&2
                rollback_failed=1
            elif ! rm -f -- "${artifact_paths[index]}"; then
                rollback_failed=1
            fi
        fi
    done
    for index in 0 1 2; do
        if ((backup_present[index])); then
            current_backup_identity=$(stat -c '%d:%i:%s:%y:%f' -- \
                "$publish_backup_dir/$index" 2>/dev/null || true)
            if [[ ! -f $publish_backup_dir/$index || -L $publish_backup_dir/$index ||
                $current_backup_identity != "${backup_identities[index]}" ]]; then
                echo "backup artifact changed identity before rollback: $publish_backup_dir/$index" \
                    >&2
                rollback_failed=1
            elif [[ -e ${artifact_paths[index]} || -L ${artifact_paths[index]} ]]; then
                echo "artifact path is occupied during rollback: ${artifact_paths[index]}" \
                    >&2
                rollback_failed=1
            elif ! mv -T -- "$publish_backup_dir/$index" \
                "${artifact_paths[index]}"; then
                rollback_failed=1
            fi
        fi
    done
    if ((rollback_failed)); then
        echo "source package publication rollback failed; inspect: $publish_backup_dir" \
            >&2
        return 1
    fi
    return 0
}

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if ((publishing && ! publish_committed)); then
        rollback_publish || status=1
    fi
    rm -rf -- "$stage" "$verify_root"
    rm -f -- "$archive_tmp" "$manifest_tmp" "$archive_hash_tmp"
    if ((! publish_backup_removed)); then
        if assert_directory_identity "$publish_backup_dir" \
            "$publish_backup_dir_identity" 'publication backup directory'; then
            if ((publish_committed)) || [[ -z $(find "$publish_backup_dir" \
                -mindepth 1 -maxdepth 1 -print -quit) ]]; then
                rm -rf -- "$publish_backup_dir"
                publish_backup_removed=1
            fi
        else
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot_root=viewflow-source
mkdir -p -- "$stage/$snapshot_root"

mapfile -d '' -t forbidden_workspace_paths < <(
    cd -- "$source_root"
    find -P . -mindepth 1 \
        \( -iname .git -o -iname target \) -print0 -prune
)
if ((${#forbidden_workspace_paths[@]} != 0)); then
    printf 'forbidden workspace path in source tree: %s\n' \
        "${forbidden_workspace_paths[0]#./}" >&2
    exit 1
fi
mapfile -d '' -t reserved_manifest_paths < <(
    cd -- "$source_root"
    find -P . -mindepth 1 -iname SOURCE-MANIFEST.sha256 -print0 -prune
)
if ((${#reserved_manifest_paths[@]} != 0)); then
    printf 'source path is reserved by the packager: %s\n' \
        "${reserved_manifest_paths[0]#./}" >&2
    exit 1
fi

mapfile -d '' -t root_paths < <(
    cd -- "$source_root"
    find -P . -mindepth 1 -maxdepth 1 -print0
)
for root_path in "${root_paths[@]}"; do
    root_name=${root_path#./}
    if [[ ${root_name,,} == source-manifest.sha256 ]]; then
        echo 'source path is reserved by the packager: SOURCE-MANIFEST.sha256' >&2
        exit 1
    fi
    case "$root_name" in
        .agents | .codex)
            ;;
        .gitignore | Cargo.toml | Cargo.lock | LICENSE | README.md)
            if [[ ! -f $source_root/$root_name || -L $source_root/$root_name ]]; then
                echo "allowed top-level source file has an invalid type: $root_name" \
                    >&2
                exit 1
            fi
            ;;
        crates | deploy | docs | platform | protocol)
            if [[ ! -d $source_root/$root_name || -L $source_root/$root_name ]]; then
                echo "allowed top-level source directory has an invalid type: $root_name" \
                    >&2
                exit 1
            fi
            ;;
        *)
            echo "unexpected top-level source path: $root_name" >&2
            exit 1
            ;;
    esac
done

declare -A windows_paths=()
validate_source_path() {
    local relative_path=$1
    local prefix=
    local path_component
    local folded_prefix
    local device_stem
    local -a path_components=()

    if [[ $relative_path == *$'\n'* || $relative_path == *$'\r'* ]]; then
        echo "source path contains a line break: $relative_path" >&2
        return 1
    fi
    if [[ $relative_path == *$'\\'* ]]; then
        echo "source path is not representable on Windows: $relative_path" >&2
        return 1
    fi
    if ! printf '%s' "$relative_path" | iconv -f UTF-8 -t UTF-16LE \
        >/dev/null; then
        echo "source path is not valid UTF-8: $relative_path" >&2
        return 1
    fi

    IFS=/ read -r -a path_components <<<"$relative_path"
    for path_component in "${path_components[@]}"; do
        if [[ ${path_component,,} == source-manifest.sha256 ]]; then
            echo 'source path is reserved by the packager: SOURCE-MANIFEST.sha256' \
                >&2
            return 1
        fi
        for forbidden_character in '<' '>' ':' '"' '|' '?' '*'; do
            if [[ $path_component == *"$forbidden_character"* ]]; then
                echo "source path is not representable on Windows: $relative_path" \
                    >&2
                return 1
            fi
        done
        case "$path_component" in
            *'.' | *' ')
                echo "source path has a Windows-unsafe trailing character: $relative_path" \
                    >&2
                return 1
                ;;
        esac
        if [[ $path_component =~ [[:cntrl:]] ]]; then
            echo "source path contains a control character: $relative_path" >&2
            return 1
        fi
        device_stem=${path_component%%.*}
        while [[ $device_stem == *' ' || $device_stem == *'.' ]]; do
            device_stem=${device_stem%?}
        done
        case "${device_stem^^}" in
            CON | PRN | AUX | NUL | COM[1-9] | LPT[1-9])
                echo "source path uses a reserved Windows device name: $relative_path" \
                    >&2
                return 1
                ;;
        esac

        if [[ -n $prefix ]]; then
            prefix="$prefix/$path_component"
        else
            prefix=$path_component
        fi
        folded_prefix=${prefix,,}
        if [[ -n ${windows_paths[$folded_prefix]+present} &&
            ${windows_paths[$folded_prefix]} != "$prefix" ]]; then
            printf 'source paths collide on Windows: %s and %s\n' \
                "${windows_paths[$folded_prefix]}" "$prefix" >&2
            return 1
        fi
        windows_paths[$folded_prefix]=$prefix
    done

    case "${relative_path,,}" in
        deploy/windows/package-viewflow-source.sh | \
            deploy/windows/check-source-package.sh | \
            deploy/windows/test-source-package.sh)
            echo "deprecated Windows source packager entry point exists: $relative_path" \
                >&2
            return 1
            ;;
    esac
}

mapfile -d '' -t source_paths < <(
    cd -- "$source_root"
    LC_ALL=C find -P . -mindepth 1 \
        \( -name .agents -o -name .codex \) -prune -o \
        -print0 | LC_ALL=C sort -z
)
for source_path in "${source_paths[@]}"; do
    validate_source_path "${source_path#./}"
done

mapfile -d '' -t unsupported_paths < <(
    cd -- "$source_root"
    find -P . \
        \( -name .agents -o -name .codex \) \
        -prune -o \
        ! -type d ! -type f -print0
)
if ((${#unsupported_paths[@]} != 0)); then
    printf 'unsupported non-regular source path: %s\n' \
        "${unsupported_paths[0]#./}" >&2
    exit 1
fi

mapfile -d '' -t source_files < <(
    cd -- "$source_root"
    LC_ALL=C find -P . \
        \( -name .agents -o -name .codex \) \
        -prune -o \
        -type f -print0 | LC_ALL=C sort -z
)
if ((${#source_files[@]} == 0)); then
    echo 'source snapshot would be empty' >&2
    exit 1
fi

mapfile -d '' -t source_directories < <(
    cd -- "$source_root"
    LC_ALL=C find -P . \
        \( -name .agents -o -name .codex \) \
        -prune -o \
        -type d -print0 | LC_ALL=C sort -z
)
source_directory_identities=()
for source_directory in "${source_directories[@]}"; do
    relative_directory=${source_directory#./}
    directory_path=$source_root
    if [[ $source_directory != '.' ]]; then
        directory_path="$source_root/$relative_directory"
    fi
    if [[ ! -d $directory_path || -L $directory_path ]]; then
        echo "source directory changed type while packaging: $relative_directory" >&2
        exit 1
    fi
    source_directory_identities+=(
        "$(stat -c '%d:%i:%y:%z:%f' -- "$directory_path")"
    )
done

source_hashes=()
for source_file in "${source_files[@]}"; do
    relative_path=${source_file#./}
    destination="$stage/$snapshot_root/$relative_path"
    mkdir -p -- "$(dirname -- "$destination")"
    source_path="$source_root/$relative_path"
    if [[ ! -f $source_path || -L $source_path ]]; then
        echo "source path changed type while packaging: $relative_path" >&2
        exit 1
    fi
    source_identity_before=$(stat -c '%d:%i:%s:%y:%z:%f' -- "$source_path")
    cp --no-dereference -- "$source_path" "$destination"
    if [[ ! -f $destination || -L $destination ]]; then
        echo "source path changed type while packaging: $relative_path" >&2
        exit 1
    fi
    source_hash=$(sha256sum -- "$source_path" | cut -d ' ' -f 1)
    source_identity_after=$(stat -c '%d:%i:%s:%y:%z:%f' -- "$source_path")
    destination_hash=$(sha256sum -- "$destination" | cut -d ' ' -f 1)
    source_identity_final=$(stat -c '%d:%i:%s:%y:%z:%f' -- "$source_path")
    if [[ $source_identity_before != "$source_identity_after" ||
        $source_identity_after != "$source_identity_final" ||
        $source_hash != "$destination_hash" ]]; then
        echo "source file changed while packaging: $relative_path" >&2
        exit 1
    fi
    chmod 0644 -- "$destination"
    source_hashes+=("$destination_hash")
done

mapfile -d '' -t final_forbidden_workspace_paths < <(
    cd -- "$source_root"
    find -P . -mindepth 1 \
        \( -iname .git -o -iname target \) -print0 -prune
)
if ((${#final_forbidden_workspace_paths[@]} != 0)); then
    printf 'forbidden workspace path appeared while packaging: %s\n' \
        "${final_forbidden_workspace_paths[0]#./}" >&2
    exit 1
fi
mapfile -d '' -t final_reserved_manifest_paths < <(
    cd -- "$source_root"
    find -P . -mindepth 1 -iname SOURCE-MANIFEST.sha256 -print0 -prune
)
if ((${#final_reserved_manifest_paths[@]} != 0)); then
    printf 'reserved source manifest path appeared while packaging: %s\n' \
        "${final_reserved_manifest_paths[0]#./}" >&2
    exit 1
fi
mapfile -d '' -t final_unsupported_paths < <(
    cd -- "$source_root"
    find -P . \
        \( -name .agents -o -name .codex \) \
        -prune -o \
        ! -type d ! -type f -print0
)
if ((${#final_unsupported_paths[@]} != 0)); then
    printf 'source tree changed type while packaging: %s\n' \
        "${final_unsupported_paths[0]#./}" >&2
    exit 1
fi
mapfile -d '' -t final_source_paths < <(
    cd -- "$source_root"
    LC_ALL=C find -P . -mindepth 1 \
        \( -name .agents -o -name .codex \) -prune -o \
        -print0 | LC_ALL=C sort -z
)
if ((${#source_paths[@]} != ${#final_source_paths[@]})); then
    echo 'source path set changed while packaging' >&2
    exit 1
fi
for index in "${!source_paths[@]}"; do
    if [[ ${source_paths[index]} != "${final_source_paths[index]}" ]]; then
        echo 'source path set changed while packaging' >&2
        exit 1
    fi
done
mapfile -d '' -t final_source_files < <(
    cd -- "$source_root"
    LC_ALL=C find -P . \
        \( -name .agents -o -name .codex \) \
        -prune -o \
        -type f -print0 | LC_ALL=C sort -z
)
if ((${#source_files[@]} != ${#final_source_files[@]})); then
    echo 'source file set changed while packaging' >&2
    exit 1
fi
for index in "${!source_files[@]}"; do
    if [[ ${source_files[index]} != "${final_source_files[index]}" ]]; then
        echo 'source file set changed while packaging' >&2
        exit 1
    fi
done
mapfile -d '' -t final_source_directories < <(
    cd -- "$source_root"
    LC_ALL=C find -P . \
        \( -name .agents -o -name .codex \) \
        -prune -o \
        -type d -print0 | LC_ALL=C sort -z
)
if ((${#source_directories[@]} != ${#final_source_directories[@]})); then
    echo 'source directory set changed while packaging' >&2
    exit 1
fi
for index in "${!source_directories[@]}"; do
    source_directory=${source_directories[index]}
    if [[ $source_directory != "${final_source_directories[index]}" ]]; then
        echo 'source directory set changed while packaging' >&2
        exit 1
    fi
    relative_directory=${source_directory#./}
    directory_path=$source_root
    if [[ $source_directory != '.' ]]; then
        directory_path="$source_root/$relative_directory"
    fi
    final_directory_identity=$(stat -c '%d:%i:%y:%z:%f' -- \
        "$directory_path" 2>/dev/null || true)
    if [[ ! -d $directory_path || -L $directory_path ||
        $final_directory_identity != "${source_directory_identities[index]}" ]]; then
        echo "source directory changed while packaging: $relative_directory" >&2
        exit 1
    fi
done

internal_manifest="$stage/$snapshot_root/SOURCE-MANIFEST.sha256"
for index in "${!source_files[@]}"; do
    source_file=${source_files[index]}
    relative_path=${source_file#./}
    file_hash=${source_hashes[index]}
    printf '%s  %s/%s\n' "$file_hash" "$snapshot_root" "$relative_path"
done >"$internal_manifest"
chmod 0644 -- "$internal_manifest"
cp -- "$internal_manifest" "$manifest_tmp"
(
    cd -- "$stage"
    sha256sum --strict --check "$manifest_tmp" >/dev/null
)

tar \
    --sort=name \
    --format=gnu \
    --mtime='@0' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$stage" \
    -cf - \
    "$snapshot_root" | gzip -n -9 >"$archive_tmp"

gzip -t -- "$archive_tmp"
tar -xzf "$archive_tmp" -C "$verify_root"
mapfile -d '' -t staged_archive_paths < <(
    cd -- "$stage"
    LC_ALL=C find -P . -mindepth 1 -print0 | LC_ALL=C sort -z
)
mapfile -d '' -t extracted_archive_paths < <(
    cd -- "$verify_root"
    LC_ALL=C find -P . -mindepth 1 -print0 | LC_ALL=C sort -z
)
if ((${#staged_archive_paths[@]} != ${#extracted_archive_paths[@]})); then
    echo 'generated archive path set does not match the staged source' >&2
    exit 1
fi
for index in "${!staged_archive_paths[@]}"; do
    if [[ ${staged_archive_paths[index]} != "${extracted_archive_paths[index]}" ]]; then
        echo 'generated archive path set does not match the staged source' >&2
        exit 1
    fi
done
mapfile -d '' -t extracted_unsupported_paths < <(
    cd -- "$verify_root"
    find -P . ! -type d ! -type f -print0
)
if ((${#extracted_unsupported_paths[@]} != 0)); then
    printf 'generated archive contains a non-regular path: %s\n' \
        "${extracted_unsupported_paths[0]#./}" >&2
    exit 1
fi
cmp --silent -- "$manifest_tmp" \
    "$verify_root/$snapshot_root/SOURCE-MANIFEST.sha256"
(
    cd -- "$verify_root"
    sha256sum --strict --check "$manifest_tmp" >/dev/null
)

archive_hash=$(sha256sum -- "$archive_tmp" | cut -d ' ' -f 1)
manifest_hash=$(sha256sum -- "$manifest_tmp" | cut -d ' ' -f 1)
printf '%s  %s\n' "$archive_hash" "$(basename -- "$output_path")" \
    >"$archive_hash_tmp"
chmod 0644 -- "$archive_tmp" "$manifest_tmp" "$archive_hash_tmp"

# Back up the prior three-file set, then publish the sidecars before the
# archive. The archive rename is the commit point. A normal failure or signal
# before that point restores the complete prior set; consumers must still
# verify both sidecars because no filesystem can rename three paths atomically.
publishing=1
assert_directory_identity "$output_dir" "$output_dir_identity" 'output directory'
assert_directory_identity "$publish_backup_dir" \
    "$publish_backup_dir_identity" 'publication backup directory'
for index in 0 1 2; do
    if [[ -e ${artifact_paths[index]} || -L ${artifact_paths[index]} ]]; then
        if [[ -L ${artifact_paths[index]} || ! -f ${artifact_paths[index]} ]]; then
            echo "artifact path changed type while publishing: ${artifact_paths[index]}" \
                >&2
            exit 1
        fi
        prior_identity=$(stat -c '%d:%i:%s:%y:%f' -- \
            "${artifact_paths[index]}")
        if ! mv -T -- "${artifact_paths[index]}" "$publish_backup_dir/$index"; then
            echo "failed to back up source package artifact: ${artifact_paths[index]}" \
                >&2
            exit 1
        fi
        backup_present[index]=1
        backup_identity=$(stat -c '%d:%i:%s:%y:%f' -- \
            "$publish_backup_dir/$index" 2>/dev/null || true)
        if [[ ! -f $publish_backup_dir/$index || -L $publish_backup_dir/$index ||
            $backup_identity != "$prior_identity" ]]; then
            echo "source package artifact changed while backing it up: ${artifact_paths[index]}" \
                >&2
            exit 1
        fi
        backup_identities[index]=$backup_identity
    fi
done

publish_artifact() {
    local index=$1
    local temporary_path=$2
    local destination_path=${artifact_paths[index]}
    local expected_hash=$3

    assert_directory_identity "$output_dir" "$output_dir_identity" \
        'output directory'
    if [[ -e $destination_path || -L $destination_path ]]; then
        echo "artifact path became occupied while publishing: $destination_path" >&2
        return 1
    fi
    if ! mv -fT -- "$temporary_path" "$destination_path"; then
        echo "failed to publish source package artifact: $destination_path" >&2
        return 1
    fi
    new_published[index]=1
    if [[ ! -f $destination_path || -L $destination_path ]]; then
        echo "published source package artifact has an invalid type: $destination_path" \
            >&2
        return 1
    fi
    published_identities[index]=$(stat -c '%d:%i:%s:%y:%z:%f' -- \
        "$destination_path")
    published_hash=$(sha256sum -- "$destination_path" 2>/dev/null | \
        cut -d ' ' -f 1 || true)
    if [[ $published_hash != "$expected_hash" ]]; then
        echo "published source package artifact failed verification: $destination_path" \
            >&2
        return 1
    fi
}

archive_hash_sidecar_hash=$(sha256sum -- "$archive_hash_tmp" | cut -d ' ' -f 1)
publish_artifact 0 "$manifest_tmp" "$manifest_hash"
publish_artifact 1 "$archive_hash_tmp" "$archive_hash_sidecar_hash"
publish_artifact 2 "$archive_tmp" "$archive_hash"
publish_committed=1
publishing=0
assert_directory_identity "$publish_backup_dir" \
    "$publish_backup_dir_identity" 'publication backup directory'
rm -rf -- "$publish_backup_dir"
publish_backup_removed=1

printf 'archive=%s\n' "$output_path"
printf 'archive_sha256=%s\n' "$archive_hash"
printf 'manifest=%s\n' "$output_path.manifest.sha256"
printf 'manifest_sha256=%s\n' "$manifest_hash"
printf 'source_file_count=%d\n' "${#source_files[@]}"
