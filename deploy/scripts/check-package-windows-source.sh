#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

packager=${1:-deploy/scripts/package-windows-source.sh}
behavior_test=${2:-deploy/scripts/tests/package-windows-source-test.sh}

for executable in "$packager" "$behavior_test"; do
    if [[ ! -x $executable ]]; then
        echo "missing executable packaging component: $executable" >&2
        exit 1
    fi
done

require() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" "$packager"; then
        echo "source packager missing $description" >&2
        exit 1
    fi
}

require_fixed() {
    local text=$1
    local description=$2
    if ! rg --quiet --fixed-strings -- "$text" "$packager"; then
        echo "source packager missing $description" >&2
        exit 1
    fi
}

require_fixed '\( -iname .git -o -iname target \)' \
    'recursive forbidden workspace-path scan'
require_fixed '\( -name .agents -o -name .codex \)' \
    'recursive local-agent metadata pruning'
require 'unsupported non-regular source path' 'symlink/special-file rejection'
require 'protocol/viewflow/v1/control\.proto' 'protocol source gate'
require 'source path is reserved by the packager' 'internal-manifest collision gate'
require_fixed 'find -P . -mindepth 1 -iname SOURCE-MANIFEST.sha256 -print0 -prune' \
    'whole-tree internal-manifest collision scan'
require 'deprecated Windows source packager entry point exists' \
    'deprecated packager collision gate'
require 'unexpected top-level source path' 'top-level source allowlist gate'
require 'source path is not representable on Windows' 'Windows character gate'
require 'source paths collide on Windows' 'case-insensitive collision gate'
require 'artifact path is not a regular file' 'non-regular output rejection'
require 'output filename is not representable on Windows' \
    'Windows-safe output filename gate'
require 'output filename uses a reserved Windows device name' \
    'reserved Windows output device-name gate'
require 'output_dir_identity' 'output-directory identity capture'
require 'source_identity_before' 'source identity capture before copying'
require 'source_identity_final' 'source identity recheck after hashing'
require 'source_directory_identities' 'source-directory identity capture'
require 'final_source_directories' 'source-directory identity recheck'
require 'final_source_files' 'source file-set recheck after copying'
require 'final_source_paths' 'complete source path-set recheck after copying'
require 'chmod 0644 -- "\$destination"' 'source mode normalization'
require 'sha256sum --strict --check' 'strict staged-manifest verification'
require 'gzip -t -- "\$archive_tmp"' 'generated gzip verification'
require 'extracted_archive_paths' 'generated archive full path-set verification'
require '--sort=name.*--mtime='\''@0'\''.*--owner=0.*--group=0.*--numeric-owner' \
    'reproducible tar metadata'
require 'gzip -n -9' 'reproducible gzip header'
require 'rollback_publish' 'three-artifact publication rollback'
require 'publish_backup_dir' 'same-directory publication backup'
require 'published source package artifact failed verification' \
    'post-publication artifact verification'

manifest_publish_line=$(rg --line-number --fixed-strings \
    'publish_artifact 0 "$manifest_tmp" "$manifest_hash"' \
    "$packager" | cut -d: -f1)
hash_publish_line=$(rg --line-number --fixed-strings \
    'publish_artifact 1 "$archive_hash_tmp" "$archive_hash_sidecar_hash"' \
    "$packager" | cut -d: -f1)
archive_publish_line=$(rg --line-number --fixed-strings \
    'publish_artifact 2 "$archive_tmp" "$archive_hash"' \
    "$packager" | cut -d: -f1)
if [[ -z $manifest_publish_line || -z $hash_publish_line ||
    -z $archive_publish_line ]]; then
    echo 'source packager publication sequence is incomplete' >&2
    exit 1
fi
if ((manifest_publish_line >= hash_publish_line ||
    hash_publish_line >= archive_publish_line)); then
    echo 'archive must be the final commit-point rename' >&2
    exit 1
fi

if [[ -e deploy/windows/package-viewflow-source.sh ||
    -e deploy/windows/check-source-package.sh ||
    -e deploy/windows/test-source-package.sh ]]; then
    echo 'deprecated duplicate Windows source packager entry point exists' >&2
    exit 1
fi

for documentation in deploy/README.md deploy/windows/README.md; do
    if ! rg --quiet --fixed-strings \
        'deploy/scripts/package-windows-source.sh' "$documentation"; then
        echo "documentation does not name the canonical packager: $documentation" >&2
        exit 1
    fi
    if rg --quiet --fixed-strings \
        'deploy/windows/package-viewflow-source.sh' "$documentation"; then
        echo "documentation names the deprecated packager: $documentation" >&2
        exit 1
    fi
done

windows_documentation=deploy/windows/README.md
for required_text in \
    'if ($LASTEXITCODE -ne 0)' \
    'Archive checksum sidecar names a different file' \
    'Unsafe source archive path' \
    'Source archive changed while being extracted' \
    'Extracted source contains a reparse point' \
    '$externalManifestHash -ne $internalManifestHash' \
    'Get-Content -LiteralPath $internalManifest' \
    'Source manifest is empty' \
    'viewflow-source/protocol/viewflow/v1/control.proto' \
    'Source manifest path escapes the source root' \
    'Archive file set does not match the source manifest' \
    'Extracted source file set does not match the source manifest' \
    'Viewflow Windows build failed with exit code $LASTEXITCODE'; do
    if ! rg --quiet --fixed-strings "$required_text" "$windows_documentation"; then
        echo "Windows verification documentation missing gate: $required_text" >&2
        exit 1
    fi
done

echo "Viewflow Windows source packager static checks passed: $packager"
