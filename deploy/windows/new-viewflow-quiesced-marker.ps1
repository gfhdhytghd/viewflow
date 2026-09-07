[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeReceiptPath,
    [Parameter(Mandatory = $true)][string]$DaemonExitEvidencePath,
    [Parameter(Mandatory = $true)][string]$DaemonExitObservationPath,
    [Parameter(Mandatory = $true)][string]$CandidatePath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedCandidateSha256,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateRange(1, 300)][int]$MaximumEvidenceAgeSeconds = 60
)

$ErrorActionPreference = 'Stop'
$taskName = '\Viewflow Peer'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Viewflow'
$installedBinary = Join-Path $installRoot 'viewflowd.exe'
$installedWrapper = Join-Path $installRoot 'viewflow-client.ps1'
$identityRoot = Join-Path $installRoot 'identity'
$peer = '172.16.105.62:44119'
$localDeviceId = '00000000000000000000000000000001'
$deviceId = '00000000000000000000000000000002'
$sourceDisplayId = '00000000000000000000000000000101'
$expectedOwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$maximumJsonInteger = 9007199254740991L

# ConvertFrom-Json is deliberately not the syntax boundary: Windows PowerShell
# 5.1 collapses duplicate keys. This C# 5 scanner validates the exact bytes
# first, including every nested object, then ConvertFrom-Json sees the same text.
if ($null -eq ('ViewflowMarker.StrictJson' -as [type])) {
    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

namespace ViewflowMarker {
    public static class StrictJson {
        private const int MaxBytes = 16 * 1024 * 1024;
        private const int MaxDepth = 128;

        public static string ValidateUtf8Object(byte[] bytes) {
            if (bytes == null || bytes.Length == 0) throw new FormatException("JSON document is empty");
            if (bytes.Length > MaxBytes) throw new FormatException("JSON document exceeds 16 MiB");
            if (bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)
                throw new FormatException("UTF-8 BOM is not allowed");
            string text = new UTF8Encoding(false, true).GetString(bytes);
            Parser parser = new Parser(text);
            parser.ParseDocument();
            return text;
        }

        private sealed class Parser {
            private readonly string text;
            private int position;
            internal Parser(string value) { text = value; }

            internal void ParseDocument() {
                SkipWhitespace();
                if (position >= text.Length || text[position] != '{')
                    throw Error("top-level JSON value must be an object");
                ParseObject(1);
                SkipWhitespace();
                if (position != text.Length) throw Error("trailing content after JSON object");
            }

            private void ParseValue(int depth) {
                if (depth > MaxDepth) throw Error("JSON nesting exceeds 128 levels");
                SkipWhitespace();
                if (position >= text.Length) throw Error("unexpected end of JSON input");
                char value = text[position];
                if (value == '{') ParseObject(depth);
                else if (value == '[') ParseArray(depth);
                else if (value == '"') ParseString();
                else if (value == 't') ParseLiteral("true");
                else if (value == 'f') ParseLiteral("false");
                else if (value == 'n') ParseLiteral("null");
                else if (value == '-' || (value >= '0' && value <= '9')) ParseNumber();
                else throw Error("invalid JSON value");
            }

            private void ParseObject(int depth) {
                Require('{');
                SkipWhitespace();
                HashSet<string> exact = new HashSet<string>(StringComparer.Ordinal);
                HashSet<string> folded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                if (Take('}')) return;
                while (true) {
                    SkipWhitespace();
                    if (position >= text.Length || text[position] != '"')
                        throw Error("object property name must be a string");
                    string name = ParseString();
                    if (!exact.Add(name)) throw Error("duplicate object property: " + name);
                    if (!folded.Add(name)) throw Error("case-colliding object property: " + name);
                    SkipWhitespace();
                    Require(':');
                    ParseValue(depth + 1);
                    SkipWhitespace();
                    if (Take('}')) return;
                    Require(',');
                }
            }

            private void ParseArray(int depth) {
                Require('[');
                SkipWhitespace();
                if (Take(']')) return;
                while (true) {
                    ParseValue(depth + 1);
                    SkipWhitespace();
                    if (Take(']')) return;
                    Require(',');
                }
            }

            private string ParseString() {
                Require('"');
                StringBuilder result = new StringBuilder();
                while (position < text.Length) {
                    char value = text[position++];
                    if (value == '"') return result.ToString();
                    if (value == '\\') {
                        if (position >= text.Length) throw Error("unterminated JSON escape");
                        char escape = text[position++];
                        if (escape == '"' || escape == '\\' || escape == '/') result.Append(escape);
                        else if (escape == 'b') result.Append('\b');
                        else if (escape == 'f') result.Append('\f');
                        else if (escape == 'n') result.Append('\n');
                        else if (escape == 'r') result.Append('\r');
                        else if (escape == 't') result.Append('\t');
                        else if (escape == 'u') {
                            char first = ParseHexCodeUnit();
                            if (char.IsHighSurrogate(first)) {
                                if (position + 1 >= text.Length || text[position] != '\\' ||
                                    text[position + 1] != 'u')
                                    throw Error("high surrogate must be followed by a low surrogate escape");
                                position += 2;
                                char second = ParseHexCodeUnit();
                                if (!char.IsLowSurrogate(second))
                                    throw Error("high surrogate must be followed by a low surrogate");
                                result.Append(first); result.Append(second);
                            } else if (char.IsLowSurrogate(first)) {
                                throw Error("lone low surrogate is not allowed");
                            } else result.Append(first);
                        } else throw Error("invalid JSON escape");
                    } else {
                        if (value < 0x20) throw Error("unescaped control character in JSON string");
                        if (char.IsHighSurrogate(value)) {
                            if (position >= text.Length || !char.IsLowSurrogate(text[position]))
                                throw Error("lone high surrogate is not allowed");
                            result.Append(value); result.Append(text[position++]);
                        } else if (char.IsLowSurrogate(value)) {
                            throw Error("lone low surrogate is not allowed");
                        } else result.Append(value);
                    }
                }
                throw Error("unterminated JSON string");
            }

            private char ParseHexCodeUnit() {
                if (position + 4 > text.Length) throw Error("incomplete Unicode escape");
                int code = 0;
                for (int index = 0; index < 4; index++) {
                    char value = text[position++];
                    int digit;
                    if (value >= '0' && value <= '9') digit = value - '0';
                    else if (value >= 'a' && value <= 'f') digit = value - 'a' + 10;
                    else if (value >= 'A' && value <= 'F') digit = value - 'A' + 10;
                    else throw Error("invalid Unicode escape");
                    code = (code << 4) | digit;
                }
                return (char)code;
            }

            private void ParseNumber() {
                Take('-');
                if (position >= text.Length) throw Error("incomplete JSON number");
                if (text[position] == '0') {
                    position++;
                    if (position < text.Length && text[position] >= '0' && text[position] <= '9')
                        throw Error("leading zero in JSON number");
                } else {
                    if (text[position] < '1' || text[position] > '9')
                        throw Error("invalid JSON number integer part");
                    while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
                }
                if (Take('.')) {
                    int start = position;
                    while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
                    if (position == start) throw Error("JSON fraction requires a digit");
                }
                if (position < text.Length && (text[position] == 'e' || text[position] == 'E')) {
                    position++;
                    if (position < text.Length && (text[position] == '+' || text[position] == '-')) position++;
                    int start = position;
                    while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
                    if (position == start) throw Error("JSON exponent requires a digit");
                }
            }

            private void ParseLiteral(string literal) {
                for (int index = 0; index < literal.Length; index++) {
                    if (position >= text.Length || text[position++] != literal[index])
                        throw Error("invalid JSON literal");
                }
            }
            private void SkipWhitespace() {
                while (position < text.Length) {
                    char value = text[position];
                    if (value == ' ' || value == '\t' || value == '\n' || value == '\r') position++;
                    else return;
                }
            }
            private bool Take(char expected) {
                if (position < text.Length && text[position] == expected) { position++; return true; }
                return false;
            }
            private void Require(char expected) {
                if (!Take(expected)) throw Error("expected '" + expected + "'");
            }
            private FormatException Error(string message) {
                return new FormatException(message + " at character " + position);
            }
        }
    }
}
'@
}

if ($null -eq ('ViewflowMarker.NativeFile' -as [type])) {
    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ViewflowMarker {
    [StructLayout(LayoutKind.Sequential)] public struct FileTime { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)] public struct ByHandleFileInformation {
        public uint FileAttributes; public FileTime CreationTime; public FileTime LastAccessTime;
        public FileTime LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh;
        public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow;
    }
    public static class NativeFile {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out ByHandleFileInformation information);
    }
}
'@
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    [IO.Path]::GetFullPath($Path)
}

function Assert-NoReparsePathComponents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ParentOnly
    )
    $cursor = Get-NormalizedFullPath -Path $Path
    if ($ParentOnly) { $cursor = [IO.Path]::GetDirectoryName($cursor) }
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $attributes = [IO.File]::GetAttributes($cursor)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name path must not contain a reparse point: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or
            [string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parent
    }
}

function Assert-RegularNonReparseFile {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name does not exist: $Path" }
    Assert-NoReparsePathComponents -Path $Path -Name $Name
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must be a regular non-reparse file: $Path"
    }
}

function Assert-OwnerOnlyFileSecurity {
    param([string]$Path, [string]$Name)
    $security = Get-Acl -LiteralPath $Path
    try {
        $ownerSid = ([Security.Principal.NTAccount][string]$security.Owner).Translate(
            [Security.Principal.SecurityIdentifier]).Value
    } catch { $ownerSid = [string]$security.Owner }
    if ($ownerSid -cne $expectedOwnerSid) { throw "$Name owner SID is invalid" }
    if (-not $security.AreAccessRulesProtected) { throw "$Name ACL must have inheritance disabled" }
    $rules = @($security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 1) { throw "$Name ACL must contain exactly one explicit access rule" }
    $rule = $rules[0]
    if ($rule.IdentityReference.Value -cne $expectedOwnerSid -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
            [Security.AccessControl.FileSystemRights]::FullControl) {
        throw "$Name ACL must grant only the owner SID FullControl"
    }
}

function Set-OwnerOnlyFileSecurity {
    param([string]$Path)
    $sid = New-Object Security.Principal.SecurityIdentifier($expectedOwnerSid)
    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $sid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-BytesSha256Lower {
    param([byte[]]$Bytes)
    $digest = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($digest.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $digest.Dispose() }
}

function Get-Sha256Lower {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Artifact does not exist: $Path" }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-AllStreamBytes {
    param([IO.Stream]$Stream, [string]$Name)
    if (-not $Stream.CanRead -or -not $Stream.CanSeek) { throw "$Name stream must be readable and seekable" }
    $Stream.Position = 0
    $memory = New-Object IO.MemoryStream
    try { $Stream.CopyTo($memory); $bytes = $memory.ToArray() }
    finally { $memory.Dispose(); $Stream.Position = 0 }
    if ($bytes.Length -eq 0) { throw "$Name is empty" }
    return ,$bytes
}

function Get-StreamFileIdentity {
    param([IO.FileStream]$Stream, [string]$Name)
    $information = New-Object ViewflowMarker.ByHandleFileInformation
    if (-not [ViewflowMarker.NativeFile]::GetFileInformationByHandle(
        $Stream.SafeFileHandle, [ref]$information)) { throw "$Name file identity could not be read" }
    if (($information.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not be a reparse file"
    }
    if ([uint32]$information.NumberOfLinks -ne 1) { throw "$Name must have exactly one hard link" }
    '{0:x8}:{1:x8}{2:x8}' -f @(
        [uint32]$information.VolumeSerialNumber,
        [uint32]$information.FileIndexHigh,
        [uint32]$information.FileIndexLow)
}

function Open-PinnedJsonSnapshot {
    param([string]$Path, [string]$Name)
    Assert-RegularNonReparseFile -Path $Path -Name $Name
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $identity = Get-StreamFileIdentity -Stream $stream -Name $Name
        $bytes = Read-AllStreamBytes -Stream $stream -Name $Name
        try {
            $text = [ViewflowMarker.StrictJson]::ValidateUtf8Object($bytes)
            $value = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        } catch { throw "$Name is not a strict UTF-8 JSON object: $($_.Exception.Message)" }
        if ($value -isnot [pscustomobject]) { throw "$Name must be a JSON object" }
        [pscustomobject]@{
            Stream = $stream; Value = $value; Sha256 = Get-BytesSha256Lower -Bytes $bytes
            Identity = $identity
        }
        $stream = $null
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-RegularFileIdentity {
    param([string]$Path, [string]$Name)
    Assert-RegularNonReparseFile -Path $Path -Name $Name
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Get-StreamFileIdentity -Stream $stream -Name $Name }
    finally { $stream.Dispose() }
}

function Assert-DistinctDeploymentPaths {
    param([hashtable]$Paths)
    $entries = @($Paths.GetEnumerator())
    for ($left = 0; $left -lt $entries.Count; $left++) {
        for ($right = $left + 1; $right -lt $entries.Count; $right++) {
            if ([string]::Equals([string]$entries[$left].Value, [string]$entries[$right].Value,
                [StringComparison]::OrdinalIgnoreCase)) {
                throw "Deployment paths must be distinct: $($entries[$left].Key) and $($entries[$right].Key)"
            }
        }
    }
}

function Test-JsonInteger { param($Value) $Value -is [int] -or $Value -is [long] }
function Assert-Uint53 {
    param($Value, [string]$Name, [switch]$Positive)
    if (-not (Test-JsonInteger $Value) -or [long]$Value -lt 0 -or
        [long]$Value -gt $maximumJsonInteger -or ($Positive -and [long]$Value -le 0)) {
        throw "$Name must be a valid JSON uint53"
    }
}

function Get-ExactProperty {
    param($Value, [string]$Name)
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -ceq $Name) { return $property }
    }
    $null
}

function Assert-ExactPropertySet {
    param($Value, [string[]]$Names, [string]$Context)
    if ($Value -isnot [pscustomobject]) { throw "$Context must be a JSON object" }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw "$Context has an unexpected field set" }
    foreach ($name in $Names) {
        if ($null -eq (Get-ExactProperty -Value $Value -Name $name)) {
            throw "$Context has an unexpected field set"
        }
    }
}

function Assert-LowerSha256 {
    param($Value, [string]$Name)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 string"
    }
}

function Assert-FreshUnixMilliseconds {
    param($Value, [string]$Name)
    Assert-Uint53 -Value $Value -Name $Name -Positive
    try { $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Value) }
    catch { throw "$Name is invalid" }
    $age = [DateTimeOffset]::UtcNow - $timestamp
    if ($age.TotalSeconds -lt -5 -or $age.TotalSeconds -gt $MaximumEvidenceAgeSeconds) {
        throw "$Name is stale or from the future"
    }
}

function Assert-JsonDeepEqual {
    param($Left, $Right, [string]$Context)
    if ($null -eq $Left -or $null -eq $Right) {
        if ($null -ne $Left -or $null -ne $Right) { throw "$Context differs" }
        return
    }
    if ($Left -is [pscustomobject] -or $Right -is [pscustomobject]) {
        if ($Left -isnot [pscustomobject] -or $Right -isnot [pscustomobject]) {
            throw "$Context differs in type"
        }
        $leftNames = @($Left.PSObject.Properties.Name)
        Assert-ExactPropertySet -Value $Right -Names $leftNames -Context $Context
        foreach ($name in $leftNames) {
            $leftProperty = Get-ExactProperty $Left $name
            $rightProperty = Get-ExactProperty $Right $name
            Assert-JsonDeepEqual -Left $leftProperty.Value -Right $rightProperty.Value `
                -Context "$Context.$name"
        }
        return
    }
    $leftIsArray = $Left -is [Array]
    $rightIsArray = $Right -is [Array]
    if ($leftIsArray -or $rightIsArray) {
        if (-not $leftIsArray -or -not $rightIsArray -or $Left.Count -ne $Right.Count) {
            throw "$Context differs in array shape"
        }
        for ($index = 0; $index -lt $Left.Count; $index++) {
            Assert-JsonDeepEqual $Left[$index] $Right[$index] "$Context[$index]"
        }
        return
    }
    if (Test-JsonInteger $Left) {
        if (-not (Test-JsonInteger $Right) -or [long]$Left -ne [long]$Right) { throw "$Context differs" }
        return
    }
    if ($Left.GetType() -ne $Right.GetType()) { throw "$Context differs in type" }
    if ($Left -is [string]) {
        if ($Left -cne $Right) { throw "$Context differs" }
    } elseif (-not [object]::Equals($Left, $Right)) { throw "$Context differs" }
}

function Assert-RuntimeReceipt {
    param($Receipt)
    Assert-ExactPropertySet $Receipt @(
        'schema_version', 'state', 'daemon_instance_id', 'operation_id',
        'daemon_pid', 'daemon_start_ticks', 'boot_id', 'daemon_sha256',
        'protocol_version', 'local_device', 'target_device', 'cleanup',
        'route_status', 'peer_disconnect_status', 'daemon_exit_required',
        'sidecar_session_disconnected', 'artifact_hashes', 'completed_at_unix_ms'
    ) 'Runtime receipt'
    if ($Receipt.schema_version -isnot [int] -or $Receipt.schema_version -ne 4 -or
        $Receipt.state -isnot [string] -or $Receipt.state -cne 'viewflow-input-quiesced') {
        throw 'Runtime receipt schema or state is invalid'
    }
    Assert-Uint53 $Receipt.daemon_pid 'Runtime daemon_pid' -Positive
    Assert-Uint53 $Receipt.daemon_start_ticks 'Runtime daemon_start_ticks' -Positive
    Assert-FreshUnixMilliseconds $Receipt.completed_at_unix_ms 'Runtime completed_at_unix_ms'
    if ($Receipt.operation_id -isnot [string] -or
        $Receipt.operation_id -cnotmatch '^[A-Za-z0-9_-]{16,128}$' -or
        $Receipt.boot_id -isnot [string] -or
        $Receipt.boot_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Runtime receipt operation or daemon identity is invalid'
    }
    $expectedInstance = '{0}-{1}-{2}' -f @(
        $Receipt.boot_id, [long]$Receipt.daemon_pid, [long]$Receipt.daemon_start_ticks)
    Assert-LowerSha256 $Receipt.daemon_sha256 'Runtime daemon_sha256'
    if ($Receipt.daemon_instance_id -isnot [string] -or
        $Receipt.daemon_instance_id -cne $expectedInstance -or
        $Receipt.protocol_version -isnot [string] -or $Receipt.protocol_version -cne '2.1' -or
        $Receipt.local_device -isnot [string] -or $Receipt.local_device -cne $localDeviceId -or
        $Receipt.target_device -isnot [string] -or $Receipt.target_device -cne $deviceId) {
        throw 'Runtime receipt daemon, protocol, or endpoint binding is invalid'
    }
    if ($Receipt.route_status -isnot [string] -or $Receipt.route_status -cne 'removed' -or
        $Receipt.peer_disconnect_status -isnot [string] -or
        $Receipt.peer_disconnect_status -cne 'initiated_before_daemon_exit' -or
        $Receipt.daemon_exit_required -isnot [bool] -or $Receipt.daemon_exit_required -ne $true -or
        $Receipt.sidecar_session_disconnected -isnot [bool] -or
        $Receipt.sidecar_session_disconnected -ne $true) {
        throw 'Runtime receipt does not describe the required one-way quiesce boundary'
    }

    $cleanup = $Receipt.cleanup
    Assert-ExactPropertySet $cleanup @(
        'route_ever_activated', 'route_was_active', 'active_lease_generation',
        'last_input_sequence', 'release_all', 'lease_revoke',
        'bound_peer_epoch', 'bound_peer_socket', 'source_display', 'route_generation'
    ) 'Runtime cleanup'
    Assert-ExactPropertySet $cleanup.release_all @('status', 'ack') 'Runtime ReleaseAll evidence'
    Assert-ExactPropertySet $cleanup.lease_revoke @('status', 'generation', 'ack') `
        'Runtime LeaseRevoke evidence'
    if ($cleanup.route_ever_activated -isnot [bool] -or $cleanup.route_was_active -isnot [bool]) {
        throw 'Runtime cleanup activation fields must be boolean'
    }
    if (-not $cleanup.route_was_active) {
        if ($cleanup.route_ever_activated -ne $false -or
            $null -ne $cleanup.source_display -or $null -ne $cleanup.route_generation -or
            $null -ne $cleanup.active_lease_generation -or $null -ne $cleanup.last_input_sequence -or
            $cleanup.release_all.status -isnot [string] -or
            $cleanup.release_all.status -cne 'not_required_no_active_route' -or
            $null -ne $cleanup.release_all.ack -or
            $cleanup.lease_revoke.status -isnot [string] -or
            $cleanup.lease_revoke.status -cne 'not_required_no_active_route' -or
            $null -ne $cleanup.lease_revoke.generation -or $null -ne $cleanup.lease_revoke.ack -or
            $null -ne $cleanup.bound_peer_epoch -or $null -ne $cleanup.bound_peer_socket) {
            throw 'Inactive-route cleanup evidence is inconsistent'
        }
    } else {
        $ack = $cleanup.release_all.ack
        $revokeAck = $cleanup.lease_revoke.ack
        Assert-ExactPropertySet $ack @(
            'lease_generation', 'target_device', 'event_sequence', 'result'
        ) 'Runtime Applied ACK'
        Assert-ExactPropertySet $revokeAck @(
            'operation_id', 'lease_generation', 'owner_device',
            'target_device', 'state', 'result'
        ) 'Runtime LeaseRevoke Applied ACK'
        Assert-Uint53 $cleanup.active_lease_generation 'Runtime active_lease_generation' -Positive
        Assert-Uint53 $cleanup.last_input_sequence 'Runtime last_input_sequence'
        Assert-Uint53 $cleanup.route_generation 'Runtime route_generation' -Positive
        Assert-Uint53 $cleanup.bound_peer_epoch 'Runtime bound_peer_epoch' -Positive
        Assert-Uint53 $ack.lease_generation 'Runtime ReleaseAll ACK lease_generation' -Positive
        Assert-Uint53 $ack.event_sequence 'Runtime ReleaseAll ACK event_sequence'
        Assert-Uint53 $cleanup.lease_revoke.generation 'Runtime revoke generation' -Positive
        Assert-Uint53 $revokeAck.lease_generation 'Runtime revoke ACK lease_generation' -Positive
        $socketMatch = [regex]::Match(
            [string]$cleanup.bound_peer_socket, '^172\.16\.105\.70:(?<port>[0-9]{1,5})$')
        if ($cleanup.route_ever_activated -ne $true -or
            $cleanup.source_display -isnot [string] -or
            $cleanup.source_display -cne $sourceDisplayId -or
            [long]$cleanup.active_lease_generation -eq $maximumJsonInteger -or
            [long]$cleanup.last_input_sequence -eq $maximumJsonInteger -or
            $cleanup.bound_peer_socket -isnot [string] -or -not $socketMatch.Success -or
            [int]$socketMatch.Groups['port'].Value -lt 1 -or
            [int]$socketMatch.Groups['port'].Value -gt 65535 -or
            $cleanup.release_all.status -isnot [string] -or $cleanup.release_all.status -cne 'applied' -or
            $ack.result -isnot [string] -or $ack.result -cne 'applied' -or
            [long]$ack.lease_generation -ne [long]$cleanup.active_lease_generation -or
            $ack.target_device -isnot [string] -or $ack.target_device -cne $deviceId -or
            [long]$ack.event_sequence -ne ([long]$cleanup.last_input_sequence + 1) -or
            $cleanup.lease_revoke.status -isnot [string] -or
            $cleanup.lease_revoke.status -cne 'applied' -or
            [long]$cleanup.lease_revoke.generation -ne
                ([long]$cleanup.active_lease_generation + 1) -or
            $revokeAck.operation_id -isnot [string] -or
            $revokeAck.operation_id -cnotmatch '^[0-9a-f]{32}$' -or
            $revokeAck.operation_id -ceq ('0' * 32) -or
            $revokeAck.operation_id.Substring(0, 16) -cne
                ('{0:x16}' -f [long]$cleanup.bound_peer_epoch) -or
            $revokeAck.operation_id.Substring(16, 16) -ceq ('0' * 16) -or
            [long]$revokeAck.lease_generation -ne [long]$cleanup.lease_revoke.generation -or
            $revokeAck.owner_device -isnot [string] -or $revokeAck.owner_device -cne $localDeviceId -or
            $revokeAck.target_device -isnot [string] -or $revokeAck.target_device -cne $deviceId -or
            $revokeAck.state -isnot [string] -or $revokeAck.state -cne 'revoked' -or
            $revokeAck.result -isnot [string] -or $revokeAck.result -cne 'applied') {
            throw 'Active-route cleanup evidence is inconsistent'
        }
    }

    Assert-ExactPropertySet $Receipt.artifact_hashes @(
        'linux_viewflowd', 'linux_peer_certificate',
        'linux_peer_private_key', 'linux_certificate_authority'
    ) 'Runtime artifact_hashes'
    foreach ($property in $Receipt.artifact_hashes.PSObject.Properties) {
        Assert-LowerSha256 $property.Value "Runtime artifact hash $($property.Name)"
    }
    if ($Receipt.artifact_hashes.linux_viewflowd -cne $Receipt.daemon_sha256) {
        throw 'Runtime linux_viewflowd artifact does not match daemon_sha256'
    }
}

function Assert-DaemonExitBundle {
    param($Receipt, $Evidence, $Observation, $ReceiptSha, $ObservationSha, [string]$ObservationName)
    $compactNames = @(
        'active_state', 'boot_id', 'command_outputs', 'daemon_instance_id',
        'daemon_pid', 'daemon_sha256', 'daemon_start_ticks', 'exact_process_count',
        'exit_status', 'invocation_id', 'journal', 'main_pid', 'observation_file_name',
        'observation_sha256', 'observed_at_unix_ms', 'operation_id', 'protocol_version',
        'runtime_receipt_sha256', 'schema_version', 'sidecar_socket_present', 'state',
        'udp_listener_count', 'unit'
    )
    $rawNames = @(
        'command_outputs', 'daemon_identity', 'journal_query', 'observed_at_unix_ms',
        'operation_id', 'runtime_receipt_sha256', 'schema_version', 'state'
    )
    $commandNames = @(
        'exact_process_pids', 'journal_entries', 'journal_json_sha256',
        'journal_selected_invocation_id', 'original_daemon_pid_present',
        'sidecar_socket_lstat', 'systemctl_invocation_id', 'systemctl_is_active',
        'systemctl_main_pid', 'udp_listener_output'
    )
    Assert-ExactPropertySet $Evidence $compactNames 'Daemon-exit compact evidence'
    Assert-ExactPropertySet $Observation $rawNames 'Raw daemon-exit observation'
    Assert-ExactPropertySet $Observation.daemon_identity @(
        'boot_id', 'daemon_instance_id', 'daemon_pid', 'daemon_sha256',
        'daemon_start_ticks', 'invocation_id'
    ) 'Raw daemon identity'
    Assert-ExactPropertySet $Evidence.journal @(
        'entry_count', 'exit_realtime_us', 'first_realtime_us', 'last_realtime_us',
        'query', 'quiescence_exit_count', 'slice_sha256', 'startup_count'
    ) 'Daemon-exit journal'
    $queryNames = @('_BOOT_ID', '_PID', '_SYSTEMD_INVOCATION_ID')
    Assert-ExactPropertySet $Evidence.journal.query $queryNames 'Daemon-exit journal query'
    Assert-ExactPropertySet $Observation.journal_query $queryNames 'Raw journal query'
    Assert-ExactPropertySet $Evidence.exit_status @(
        'exact_process_count', 'main_pid_zero', 'original_daemon_pid_present',
        'sidecar_socket_present', 'udp_listener_count', 'unit_inactive'
    ) 'Daemon-exit status'
    Assert-ExactPropertySet $Evidence.command_outputs $commandNames 'Daemon-exit command outputs'
    Assert-ExactPropertySet $Observation.command_outputs $commandNames 'Raw command outputs'

    Assert-LowerSha256 $Evidence.runtime_receipt_sha256 'Daemon-exit runtime_receipt_sha256'
    Assert-LowerSha256 $Observation.runtime_receipt_sha256 'Raw runtime_receipt_sha256'
    Assert-LowerSha256 $Evidence.observation_sha256 'Daemon-exit observation_sha256'
    Assert-LowerSha256 $Evidence.daemon_sha256 'Daemon-exit daemon_sha256'
    Assert-LowerSha256 $Observation.daemon_identity.daemon_sha256 'Raw daemon_sha256'
    Assert-LowerSha256 $Evidence.journal.slice_sha256 'Daemon-exit journal slice_sha256'
    Assert-LowerSha256 $Evidence.command_outputs.journal_json_sha256 `
        'Daemon-exit journal_json_sha256'

    Assert-Uint53 $Evidence.daemon_pid 'Daemon-exit daemon_pid' -Positive
    Assert-Uint53 $Evidence.daemon_start_ticks 'Daemon-exit daemon_start_ticks' -Positive
    Assert-Uint53 $Evidence.observed_at_unix_ms 'Daemon-exit observed_at_unix_ms' -Positive
    Assert-Uint53 $Evidence.main_pid 'Daemon-exit main_pid'
    Assert-Uint53 $Evidence.exact_process_count 'Daemon-exit exact_process_count'
    Assert-Uint53 $Evidence.udp_listener_count 'Daemon-exit udp_listener_count'
    Assert-Uint53 $Evidence.journal.entry_count 'Daemon-exit journal entry_count' -Positive
    Assert-Uint53 $Evidence.journal.startup_count 'Daemon-exit journal startup_count'
    Assert-Uint53 $Evidence.journal.quiescence_exit_count `
        'Daemon-exit journal quiescence_exit_count'
    Assert-Uint53 $Evidence.journal.first_realtime_us `
        'Daemon-exit journal first_realtime_us' -Positive
    Assert-Uint53 $Evidence.journal.last_realtime_us `
        'Daemon-exit journal last_realtime_us' -Positive
    Assert-Uint53 $Evidence.journal.exit_realtime_us `
        'Daemon-exit journal exit_realtime_us' -Positive
    Assert-Uint53 $Observation.daemon_identity.daemon_pid 'Raw daemon_pid' -Positive
    Assert-Uint53 $Observation.daemon_identity.daemon_start_ticks `
        'Raw daemon_start_ticks' -Positive
    Assert-Uint53 $Observation.observed_at_unix_ms 'Raw observed_at_unix_ms' -Positive

    $expectedInstance = '{0}-{1}-{2}' -f @(
        $Receipt.boot_id, [long]$Receipt.daemon_pid, [long]$Receipt.daemon_start_ticks)
    $journal = $Evidence.journal
    $commands = $Evidence.command_outputs
    $completedMicros = [long]$Receipt.completed_at_unix_ms * 1000L
    if ($Evidence.schema_version -isnot [int] -or $Evidence.schema_version -ne 1 -or
        $Evidence.state -isnot [string] -or $Evidence.state -cne 'viewflow-daemon-exited' -or
        $Observation.schema_version -isnot [int] -or $Observation.schema_version -ne 1 -or
        $Observation.state -isnot [string] -or
        $Observation.state -cne 'viewflow-daemon-exit-observation' -or
        $Evidence.operation_id -isnot [string] -or $Evidence.operation_id -cne $Receipt.operation_id -or
        $Observation.operation_id -isnot [string] -or
        $Observation.operation_id -cne $Receipt.operation_id -or
        $Evidence.runtime_receipt_sha256 -cne $ReceiptSha -or
        $Observation.runtime_receipt_sha256 -cne $ReceiptSha -or
        $Evidence.observation_sha256 -cne $ObservationSha -or
        $Evidence.observation_file_name -isnot [string] -or
        $Evidence.observation_file_name -cne $ObservationName -or
        $Evidence.daemon_instance_id -isnot [string] -or
        $Evidence.daemon_instance_id -cne $expectedInstance -or
        [long]$Evidence.daemon_pid -ne [long]$Receipt.daemon_pid -or
        [long]$Evidence.daemon_start_ticks -ne [long]$Receipt.daemon_start_ticks -or
        $Evidence.boot_id -isnot [string] -or $Evidence.boot_id -cne $Receipt.boot_id -or
        $Evidence.daemon_sha256 -cne $Receipt.daemon_sha256 -or
        $Evidence.invocation_id -isnot [string] -or
        $Evidence.invocation_id -cnotmatch '^[0-9a-f]{32}$' -or
        $Evidence.protocol_version -isnot [string] -or $Evidence.protocol_version -cne '2.1' -or
        $Evidence.unit -isnot [string] -or $Evidence.unit -cne 'viewflow-peer.service' -or
        $journal.query._SYSTEMD_INVOCATION_ID -isnot [string] -or
        $journal.query._SYSTEMD_INVOCATION_ID -cne $Evidence.invocation_id -or
        $journal.query._PID -isnot [string] -or
        $journal.query._PID -cne ([long]$Evidence.daemon_pid).ToString() -or
        $journal.query._BOOT_ID -isnot [string] -or
        $journal.query._BOOT_ID -cne ([string]$Evidence.boot_id).Replace('-', '') -or
        [long]$journal.startup_count -ne 1 -or [long]$journal.quiescence_exit_count -ne 1 -or
        [long]$journal.last_realtime_us -lt [long]$journal.first_realtime_us -or
        [long]$journal.exit_realtime_us -lt [long]$journal.first_realtime_us -or
        [long]$journal.exit_realtime_us -gt [long]$journal.last_realtime_us -or
        [long]$journal.exit_realtime_us -lt $completedMicros -or
        $Evidence.active_state -isnot [string] -or $Evidence.active_state -cne 'inactive' -or
        [long]$Evidence.main_pid -ne 0 -or [long]$Evidence.exact_process_count -ne 0 -or
        [long]$Evidence.udp_listener_count -ne 0 -or
        $Evidence.sidecar_socket_present -isnot [bool] -or
        $Evidence.sidecar_socket_present -ne $false) {
        throw 'Daemon-exit evidence, raw observation, and runtime receipt are inconsistent'
    }

    $identity = $Observation.daemon_identity
    if ($identity.daemon_instance_id -isnot [string] -or
        $identity.daemon_instance_id -cne $Evidence.daemon_instance_id -or
        [long]$identity.daemon_pid -ne [long]$Evidence.daemon_pid -or
        [long]$identity.daemon_start_ticks -ne [long]$Evidence.daemon_start_ticks -or
        $identity.boot_id -isnot [string] -or $identity.boot_id -cne $Evidence.boot_id -or
        $identity.daemon_sha256 -isnot [string] -or
        $identity.daemon_sha256 -cne $Evidence.daemon_sha256 -or
        $identity.invocation_id -isnot [string] -or $identity.invocation_id -cne $Evidence.invocation_id) {
        throw 'Raw daemon identity does not match compact evidence'
    }
    Assert-JsonDeepEqual $Observation.journal_query $journal.query 'Raw journal query'
    Assert-JsonDeepEqual $Observation.command_outputs $commands 'Raw command outputs'

    $status = $Evidence.exit_status
    if ($status.unit_inactive -isnot [bool] -or $status.unit_inactive -ne $true -or
        $status.main_pid_zero -isnot [bool] -or $status.main_pid_zero -ne $true -or
        $status.original_daemon_pid_present -isnot [bool] -or
        $status.original_daemon_pid_present -ne $false -or
        -not (Test-JsonInteger $status.exact_process_count) -or
        [long]$status.exact_process_count -ne 0 -or
        -not (Test-JsonInteger $status.udp_listener_count) -or
        [long]$status.udp_listener_count -ne 0 -or
        $status.sidecar_socket_present -isnot [bool] -or
        $status.sidecar_socket_present -ne $false) {
        throw 'Daemon-exit status is not the required fixed quiescence state'
    }
    if ($commands.systemctl_is_active -isnot [string] -or
        $commands.systemctl_is_active -cne 'inactive' -or
        $commands.systemctl_main_pid -isnot [string] -or $commands.systemctl_main_pid -cne '0' -or
        $commands.systemctl_invocation_id -isnot [string] -or
        ($commands.systemctl_invocation_id -cne '' -and
            $commands.systemctl_invocation_id -cne $Evidence.invocation_id) -or
        $commands.journal_selected_invocation_id -isnot [string] -or
        $commands.journal_selected_invocation_id -cne $Evidence.invocation_id -or
        $commands.original_daemon_pid_present -isnot [string] -or
        $commands.original_daemon_pid_present -cne 'false' -or
        $commands.exact_process_pids -isnot [string] -or $commands.exact_process_pids -cne '' -or
        $commands.udp_listener_output -isnot [string] -or $commands.udp_listener_output -cne '' -or
        $commands.sidecar_socket_lstat -isnot [string] -or
        $commands.sidecar_socket_lstat -cne 'absent' -or
        $commands.journal_json_sha256 -cne $journal.slice_sha256 -or
        $commands.journal_entries -isnot [Array] -or
        $commands.journal_entries.Count -ne [long]$journal.entry_count) {
        throw 'Daemon-exit command outputs are inconsistent'
    }
    Assert-FreshUnixMilliseconds $Evidence.observed_at_unix_ms 'Exit observed_at_unix_ms'
    if ([long]$Evidence.observed_at_unix_ms -lt [long]$Receipt.completed_at_unix_ms -or
        [long]$Observation.observed_at_unix_ms -ne [long]$Evidence.observed_at_unix_ms) {
        throw 'Daemon exit observation predates cleanup completion or raw observation differs'
    }
}

if (Test-Path -LiteralPath $OutputPath) {
    throw "Refusing to replace an existing quiesced marker: $OutputPath"
}
$runtimeReceiptFullPath = Get-NormalizedFullPath $RuntimeReceiptPath
$exitEvidenceFullPath = Get-NormalizedFullPath $DaemonExitEvidencePath
$exitObservationFullPath = Get-NormalizedFullPath $DaemonExitObservationPath
$candidateFullPath = Get-NormalizedFullPath $CandidatePath
$outputFullPath = Get-NormalizedFullPath $OutputPath
Assert-DistinctDeploymentPaths @{
    runtime_receipt = $runtimeReceiptFullPath; daemon_exit_evidence = $exitEvidenceFullPath
    daemon_exit_observation = $exitObservationFullPath; candidate = $candidateFullPath
    output = $outputFullPath
}

$receiptSnapshot = $null
$evidenceSnapshot = $null
$observationSnapshot = $null
try {
    $receiptSnapshot = Open-PinnedJsonSnapshot $runtimeReceiptFullPath 'Runtime receipt'
    $evidenceSnapshot = Open-PinnedJsonSnapshot $exitEvidenceFullPath 'Daemon-exit compact evidence'
    $observationSnapshot = Open-PinnedJsonSnapshot $exitObservationFullPath 'Raw daemon-exit observation'
    $identityNames = @{}
    foreach ($binding in @(
        @('Runtime receipt', $receiptSnapshot),
        @('Daemon-exit compact evidence', $evidenceSnapshot),
        @('Raw daemon-exit observation', $observationSnapshot))) {
        if ($identityNames.ContainsKey($binding[1].Identity)) {
            throw "Evidence files must not alias: $($identityNames[$binding[1].Identity]) and $($binding[0])"
        }
        $identityNames[$binding[1].Identity] = $binding[0]
    }

    $receipt = $receiptSnapshot.Value
    $exitEvidence = $evidenceSnapshot.Value
    $rawObservation = $observationSnapshot.Value
    Assert-RuntimeReceipt $receipt
    Assert-DaemonExitBundle $receipt $exitEvidence $rawObservation `
        $receiptSnapshot.Sha256 $observationSnapshot.Sha256 `
        ([IO.Path]::GetFileName($exitObservationFullPath))

    $artifactHashes = [ordered]@{}
    foreach ($property in $receipt.artifact_hashes.PSObject.Properties) {
        $artifactHashes[$property.Name] = [string]$property.Value
    }
    $artifactPaths = [ordered]@{
        windows_installed_viewflowd = $installedBinary
        windows_candidate_viewflowd = $candidateFullPath
        windows_client_wrapper = $installedWrapper
        windows_peer_certificate = (Join-Path $identityRoot 'peer.pem')
        windows_peer_private_key = (Join-Path $identityRoot 'peer.key')
        windows_certificate_authority = (Join-Path $identityRoot 'ca.pem')
    }
    foreach ($artifact in $artifactPaths.GetEnumerator()) {
        $identity = Get-RegularFileIdentity $artifact.Value $artifact.Key
        if ($identity -ceq $observationSnapshot.Identity) {
            throw "Raw daemon-exit observation aliases artifact: $($artifact.Key)"
        }
        $artifactHash = Get-Sha256Lower $artifact.Value
        if ($artifactHash -ceq $observationSnapshot.Sha256) {
            throw "Raw daemon-exit observation aliases artifact bytes: $($artifact.Key)"
        }
        $artifactHashes[$artifact.Key] = $artifactHash
    }
    if ($artifactHashes.windows_candidate_viewflowd -cne
        $ExpectedCandidateSha256.ToLowerInvariant()) {
        throw 'Candidate SHA256 does not match the reviewed expected value'
    }

    $marker = [ordered]@{
        schema_version = 4; state = 'viewflow-input-quiesced'
        operation_id = [string]$receipt.operation_id; task_name = $taskName
        peer = $peer; device_id = $deviceId; protocol_version = [string]$receipt.protocol_version
        daemon_instance_id = [string]$receipt.daemon_instance_id
        local_device = [string]$receipt.local_device; target_device = [string]$receipt.target_device
        daemon_sha256 = [string]$receipt.daemon_sha256; daemon_pid = [long]$receipt.daemon_pid
        daemon_start_ticks = [long]$receipt.daemon_start_ticks; boot_id = [string]$receipt.boot_id
        cleanup = $receipt.cleanup; route_status = [string]$receipt.route_status
        peer_disconnect_status = 'confirmed_by_daemon_exit'
        daemon_exit_evidence = $exitEvidence; artifact_hashes = $artifactHashes
        completed_at_unix_ms = [long]$receipt.completed_at_unix_ms
        created_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $currentReceiptSha256 = Get-Sha256Lower $runtimeReceiptFullPath
    if ($currentReceiptSha256 -cne $receiptSnapshot.Sha256) {
        throw 'Runtime receipt changed after it was read'
    }
    $currentExitEvidenceSha256 = Get-Sha256Lower $exitEvidenceFullPath
    if ($currentExitEvidenceSha256 -cne $evidenceSnapshot.Sha256) {
        throw 'Daemon-exit compact evidence changed after it was read'
    }
    $currentObservationSha256 = Get-Sha256Lower $exitObservationFullPath
    if ($currentObservationSha256 -cne $observationSnapshot.Sha256) {
        throw 'Raw daemon-exit observation changed after it was read'
    }

    $parent = Split-Path -Parent $outputFullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Marker parent directory does not exist: $parent"
    }
    Assert-NoReparsePathComponents $outputFullPath 'Marker output' -ParentOnly
    $temporary = Join-Path $parent ('.viewflow-quiesced-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $json = $marker | ConvertTo-Json -Depth 64
        [IO.File]::WriteAllText(
            $temporary, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Set-OwnerOnlyFileSecurity $temporary
        Move-Item -LiteralPath $temporary -Destination $outputFullPath
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Write-Output "Created Viewflow quiesced marker for operation $($receipt.operation_id)"
} finally {
    if ($null -ne $observationSnapshot) { $observationSnapshot.Stream.Dispose() }
    if ($null -ne $evidenceSnapshot) { $evidenceSnapshot.Stream.Dispose() }
    if ($null -ne $receiptSnapshot) { $receiptSnapshot.Stream.Dispose() }
}
