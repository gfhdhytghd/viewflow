#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo 'Usage: check-viewflow-release-provenance.sh --manifest ABS --manifest-sha256 64-lowercase-hex'; }
manifest=''; expected=''
while (($#)); do case $1 in --manifest) manifest=${2-}; shift 2;; --manifest-sha256) expected=${2-}; shift 2;; *) usage >&2; exit 2;; esac; done
[[ $manifest == /* && $expected =~ ^[0-9a-f]{64}$ && -f $manifest && ! -L $manifest && $(stat -c %h -- "$manifest") == 1 ]] || { usage >&2; exit 2; }
[[ $(sha256sum -- "$manifest" | awk '{print tolower($1)}') == "$expected" ]] || { echo 'manifest hash mismatch' >&2; exit 1; }
python3 -c 'import json,re,sys
def h(p):
 d={}
 for k,v in p:
  if k in d: raise ValueError("duplicate key "+k)
  d[k]=v
 return d
def rel(p):
 return isinstance(p,str) and not p.startswith("/") and "//" not in p and not any(ord(c)<32 or ord(c)==127 for c in p) and all(q not in ("",".","..") and re.fullmatch(r"[A-Za-z0-9._@+=,:~-]+",q) for q in p.split("/"))
x=json.load(open(sys.argv[1]),object_pairs_hook=h)
assert set(x)=={"schema_version","kind","protocol_version","sidecar_protocol_version","source","build","artifacts"}
assert x["schema_version"]==2 and x["kind"]=="viewflow-linux-rust-release-provenance" and x["protocol_version"]=="2.1" and x["sidecar_protocol_version"]==3
s=x["source"]; assert set(s)=={"identity","root","directories","files"} and s["identity"]=="allowlisted-tree-v2" and s["root"].startswith("/") and s["directories"] and s["files"]
assert [z["path"] for z in s["directories"]]==sorted(z["path"] for z in s["directories"]); assert [z["path"] for z in s["files"]]==sorted(z["path"] for z in s["files"])
for z in s["directories"]: assert set(z)=={"path","mode"} and (z["path"]=="." or rel(z["path"])) and re.fullmatch(r"0[0-7]{3}",z["mode"])
for z in s["files"]: assert set(z)=={"path","sha256","size_bytes","mode","identity"} and rel(z["path"]) and re.fullmatch(r"[0-9a-f]{64}",z["sha256"]) and isinstance(z["size_bytes"],int) and re.fullmatch(r"0[0-7]{3}",z["mode"])
b=x["build"]; assert set(b)=={"cwd","target_dir","target_triple","host_triple","profile","command","rustc","cargo"} and b["cwd"]==s["root"] and b["target_dir"].startswith("/") and b["target_triple"]==b["host_triple"] and b["profile"]=="release" and b["command"]=="CARGO_NET_OFFLINE=true cargo build --release --locked --offline -p viewflowd -p viewflow-deployment-marker"
for t in ("rustc","cargo"): assert set(b[t])=={"invoked_path","invoked_sha256","active_path","active_sha256","vv"} and b[t]["invoked_path"].startswith("/") and b[t]["active_path"].startswith("/") and re.fullmatch(r"[0-9a-f]{64}",b[t]["invoked_sha256"]) and re.fullmatch(r"[0-9a-f]{64}",b[t]["active_sha256"]) and b[t]["vv"]
assert set(x["artifacts"])=={"viewflowd","deployment_marker","unit","dropin"}
assert x["artifacts"]["viewflowd"]["path"]==b["target_dir"]+"/release/viewflowd" and x["artifacts"]["deployment_marker"]["path"]==b["target_dir"]+"/release/viewflow-deployment-marker"
for n,z in x["artifacts"].items(): assert set(z)==({"path","sha256","size_bytes","mode","device","inode","link_count"}|({"elf_build_id"} if n in ("viewflowd","deployment_marker") else set())) and z["path"].startswith("/") and re.fullmatch(r"[0-9a-f]{64}",z["sha256"]) and z["link_count"]>=1 and (z["link_count"]==1 if n in ("unit","dropin") else True)
' "$manifest" || { echo 'invalid exact provenance schema' >&2; exit 1; }
readarray -t a < <(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(x["source"]["root"]);print(x["build"]["target_dir"]);print(x["artifacts"]["unit"]["path"]);print(x["artifacts"]["dropin"]["path"])' "$manifest")
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); tmp=$(mktemp -d "${TMPDIR:-/tmp}/vf-release-check.XXXXXXXX"); trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
"$dir/generate-viewflow-release-provenance.sh" --verify-existing --source-dir "${a[0]}" --build-dir "${a[1]}" --unit "${a[2]}" --dropin "${a[3]}" --output "$tmp/recomputed.json" >/dev/null
cmp -s -- "$manifest" "$tmp/recomputed.json" || { echo 'current source/tool/artifact final recheck differs' >&2; exit 1; }
echo "Viewflow release provenance verified: $manifest"
