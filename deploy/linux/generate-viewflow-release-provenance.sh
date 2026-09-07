#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
usage(){ echo 'Usage: generate-viewflow-release-provenance.sh --source-dir ABS --build-dir ABS --unit ABS --dropin ABS --output ABS [--verify-existing]'; }
source_dir='' build_dir='' unit='' dropin='' output='' verify=0
while (($#)); do case $1 in --source-dir) source_dir=${2-};shift 2;;--build-dir) build_dir=${2-};shift 2;;--unit) unit=${2-};shift 2;;--dropin) dropin=${2-};shift 2;;--output) output=${2-};shift 2;;--verify-existing) verify=1;shift;;*) usage >&2;exit 2;;esac;done
[[ -n $source_dir && -n $build_dir && -n $unit && -n $dropin && -n $output ]] || { usage >&2;exit 2; }
die(){ echo "error: $*" >&2;exit 1; }; abs(){ [[ $1 == /* ]]||die "not absolute: $1"; }; sha(){ sha256sum -- "$1"|awk '{print tolower($1)}'; }; size(){ stat -c %s -- "$1"; }; mode(){ local x;x=$(stat -c %a -- "$1");printf '0%03o\n' "$((8#$x))"; }; ident(){ stat -c '%d:%i:%s:%h:%a' -- "$1"; }; bid(){ readelf -n -- "$1"|awk '/Build ID:/{print tolower($3);x=1;exit}END{exit !x}'; }
safe_file(){ [[ -f $1 && ! -L $1 && $(stat -c %h -- "$1") == 1 ]]||die "unsafe file: $1"; (( (8#$(stat -c %a -- "$1")&8#022)==0 ))||die "writable file: $1"; }
safe_dir(){ [[ -d $1 && ! -L $1 ]]||die "unsafe directory: $1"; (( (8#$(stat -c %a -- "$1")&8#022)==0 ))||die "writable directory: $1"; }
safe_build_dir(){ safe_dir "$1"; [[ $(stat -c %u -- "$1") == $(id -u) && $(stat -c %a -- "$1") == 700 ]] || die "build-dir must be owned by current uid and mode 0700: $1"; }
safe_cargo_artifact(){ [[ -f $1 && ! -L $1 && $(stat -c %h -- "$1") -ge 1 ]] || die "unsafe Cargo artifact: $1"; (( (8#$(stat -c %a -- "$1")&8#022)==0 )) || die "writable Cargo artifact: $1"; [[ $(realpath -e -- "$1") == "$1" ]] || die "Cargo artifact path is not canonical: $1"; }
fsync(){ python3 - "$1" "$(dirname -- "$1")" <<'PY'
import os,sys
for p in sys.argv[1:]:
 f=os.open(p,os.O_RDONLY|(os.O_DIRECTORY if os.path.isdir(p) else 0))
 try: os.fsync(f)
 finally: os.close(f)
PY
}
for x in cargo rustc rustup find python3 readelf sha256sum stat sort realpath rg file;do command -v "$x">/dev/null||die "missing $x";done
for p in "$source_dir" "$build_dir" "$unit" "$dropin" "$output";do abs "$p";done
source_dir=$(cd -- "$source_dir"&&pwd -P);safe_dir "$source_dir"; build_parent=$(dirname -- "$build_dir");out_parent=$(dirname -- "$output");safe_dir "$build_parent";safe_dir "$out_parent"
case "$build_dir" in "$source_dir"|"$source_dir"/*)die 'build-dir inside source';;esac;case "$output" in "$source_dir"|"$source_dir"/*|"$build_dir"|"$build_dir"/*)die 'output inside source/build';;esac
[[ ! -e $output ]]||die 'output exists'; if ((verify));then safe_build_dir "$build_dir";else [[ ! -e $build_dir ]]||die 'fresh build-dir exists'; install -d -m 0700 -- "$build_dir"; safe_build_dir "$build_dir";fi
safe_file "$unit";safe_file "$dropin"
for p in .gitignore Cargo.toml Cargo.lock LICENSE README.md crates deploy docs platform protocol crates/viewflow-protocol/src/lib.rs crates/viewflow-platform/src/sidecar.rs;do [[ -e $source_dir/$p && ! -L $source_dir/$p ]]||die "missing source: $p";done
rg -q 'ProtocolVersion \{ major: 2, minor: 1 \}' "$source_dir/crates/viewflow-protocol/src/lib.rs"||die 'protocol not 2.1';rg -q 'SIDECAR_PROTOCOL_VERSION: u8 = 3' "$source_dir/crates/viewflow-platform/src/sidecar.rs"||die 'sidecar not 3'
while IFS= read -r -d '' p;do die "forbidden source: ${p#"$source_dir"/}";done < <(find -P "$source_dir" -mindepth 1 \( -name .git -o -name target -o -name .agents -o -name .codex -o -name __pycache__ \) -print0)
declare -A roots=();for x in .gitignore Cargo.toml Cargo.lock LICENSE README.md crates deploy docs platform protocol;do roots[$x]=1;done
while IFS= read -r -d '' p;do x=${p#"$source_dir"/};[[ ${roots[$x]+yes} ]]||die "unexpected root: $x";done < <(find -P "$source_dir" -mindepth 1 -maxdepth 1 ! -name .git -print0)
while IFS= read -r -d '' p;do [[ -d $p && ! -L $p ]]||die "nested special/symlink: $p";safe_dir "$p";done < <(find -P "$source_dir" -type d -print0)
while IFS= read -r -d '' p;do [[ -f $p && ! -L $p ]]||die "nested special/symlink: $p";safe_file "$p";done < <(find -P "$source_dir" -mindepth 1 -type f ! -path "$source_dir/.git/*" -print0)
while IFS= read -r -d '' p;do die "nested special/symlink: $p";done < <(find -P "$source_dir" -mindepth 1 ! -type d ! -type f -print0)
tmp=$(mktemp "$out_parent/.vf-release.XXXXXXXX");files=$(mktemp "$out_parent/.vf-files.XXXXXXXX");dirs=$(mktemp "$out_parent/.vf-dirs.XXXXXXXX");trap 'rm -f -- "$tmp" "$files" "$dirs"' EXIT HUP INT TERM
snap(){ : >"$files";: >"$dirs";while IFS= read -r -d '' p;do r=${p#"$source_dir"/};[[ $p == "$source_dir" ]]&&r=.;printf '%s\t%s\n' "$r" "$(mode "$p")">>"$dirs";done < <(find -P "$source_dir" -type d -print0|sort -z);while IFS= read -r -d '' p;do r=${p#"$source_dir"/};printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$(sha "$p")" "$(size "$p")" "$(mode "$p")" "$(ident "$p")">>"$files";done < <(find -P "$source_dir" -mindepth 1 -type f ! -path "$source_dir/.git/*" -print0|sort -z); }
snap; files_before=$(sha "$files");dirs_before=$(sha "$dirs")
rustc_invoked=$(realpath -e -- "$(command -v rustc)");cargo_invoked=$(realpath -e -- "$(command -v cargo)");rustc_active=$(realpath -e -- "$(rustup which rustc)");cargo_active=$(realpath -e -- "$(rustup which cargo)");rustc_invoked_hash=$(sha "$rustc_invoked");cargo_invoked_hash=$(sha "$cargo_invoked");rustc_hash=$(sha "$rustc_active");cargo_hash=$(sha "$cargo_active");rustc_vv=$($rustc_active -Vv);cargo_vv=$($cargo_active -Vv);host=$(awk -F': ' '$1=="host"{print $2}'<<<"$rustc_vv");[[ -n $host ]]||die 'no rust host'
if ((!verify));then (cd -- "$source_dir"&&CARGO_TARGET_DIR="$build_dir" CARGO_NET_OFFLINE=true "$cargo_active" build --release --locked --offline -p viewflowd -p viewflow-deployment-marker);fi
vf=$build_dir/release/viewflowd;marker=$build_dir/release/viewflow-deployment-marker
safe_build_dir "$build_dir"
for p in "$vf" "$marker";do safe_cargo_artifact "$p";[[ -x $p && $(file -Lb -- "$p") == *ELF* ]]||die "not executable ELF: $p";bid "$p">/dev/null||die "no build id: $p";done
[[ $(ident "$vf") != $(ident "$marker") ]]||die 'artifacts not distinct'
vf_before="$(sha "$vf"):$(size "$vf"):$(bid "$vf"):$(ident "$vf")"; marker_before="$(sha "$marker"):$(size "$marker"):$(bid "$marker"):$(ident "$marker")"; unit_before="$(sha "$unit"):$(size "$unit"):$(ident "$unit")"; dropin_before="$(sha "$dropin"):$(size "$dropin"):$(ident "$dropin")"
python3 - "$files" "$dirs" "$tmp" "$source_dir" "$build_dir" "$vf" "$marker" "$unit" "$dropin" "$host" "$rustc_invoked" "$rustc_invoked_hash" "$rustc_active" "$rustc_hash" "$rustc_vv" "$cargo_invoked" "$cargo_invoked_hash" "$cargo_active" "$cargo_hash" "$cargo_vv" <<'PY'
import hashlib,json,os,subprocess,sys
f,d,o,root,target,v,m,u,di,host,ri,rih,r,rh,rv,ci,cih,c,ch,cv=sys.argv[1:]
def a(p,e=False):
 s=os.stat(p,follow_symlinks=False);q={'path':p,'sha256':hashlib.file_digest(open(p,'rb'),'sha256').hexdigest(),'size_bytes':s.st_size,'mode':format(s.st_mode&511,'04o'),'device':s.st_dev,'inode':s.st_ino,'link_count':s.st_nlink}
 if e:q['elf_build_id']=[x.split()[-1].lower()for x in subprocess.check_output(['readelf','-n',p],text=True).splitlines()if 'Build ID:'in x][0]
 return q
fs=[]
for x in open(f):p,h,n,mo,i=x.rstrip('\n').split('\t');fs.append({'path':p,'sha256':h,'size_bytes':int(n),'mode':mo,'identity':i})
ds=[]
for x in open(d):p,mo=x.rstrip('\n').split('\t');ds.append({'path':p,'mode':mo})
x={'schema_version':2,'kind':'viewflow-linux-rust-release-provenance','protocol_version':'2.1','sidecar_protocol_version':3,'source':{'identity':'allowlisted-tree-v2','root':root,'directories':ds,'files':fs},'build':{'cwd':root,'target_dir':target,'target_triple':host,'host_triple':host,'profile':'release','command':'CARGO_NET_OFFLINE=true cargo build --release --locked --offline -p viewflowd -p viewflow-deployment-marker','rustc':{'invoked_path':ri,'invoked_sha256':rih,'active_path':r,'active_sha256':rh,'vv':rv},'cargo':{'invoked_path':ci,'invoked_sha256':cih,'active_path':c,'active_sha256':ch,'vv':cv}},'artifacts':{'viewflowd':a(v,True),'deployment_marker':a(m,True),'unit':a(u),'dropin':a(di)}}
json.dump(x,open(o,'w'),sort_keys=True,separators=(',',':'));open(o,'a').write('\n')
PY
snap;[[ $(sha "$files") == "$files_before" && $(sha "$dirs") == "$dirs_before" ]]||die 'source raced';[[ $(realpath -e -- "$(command -v rustc)") == "$rustc_invoked" && $(sha "$rustc_invoked") == "$rustc_invoked_hash" && $(realpath -e -- "$(rustup which rustc)") == "$rustc_active" && $(sha "$rustc_active") == "$rustc_hash" && $($rustc_active -Vv) == "$rustc_vv" && $(realpath -e -- "$(command -v cargo)") == "$cargo_invoked" && $(sha "$cargo_invoked") == "$cargo_invoked_hash" && $(realpath -e -- "$(rustup which cargo)") == "$cargo_active" && $(sha "$cargo_active") == "$cargo_hash" && $($cargo_active -Vv) == "$cargo_vv" ]]||die 'tool raced'
safe_build_dir "$build_dir";for p in "$vf" "$marker";do safe_cargo_artifact "$p";done;for p in "$unit" "$dropin";do safe_file "$p";done
[[ "$(sha "$vf"):$(size "$vf"):$(bid "$vf"):$(ident "$vf")" == "$vf_before" && "$(sha "$marker"):$(size "$marker"):$(bid "$marker"):$(ident "$marker")" == "$marker_before" && "$(sha "$unit"):$(size "$unit"):$(ident "$unit")" == "$unit_before" && "$(sha "$dropin"):$(size "$dropin"):$(ident "$dropin")" == "$dropin_before" ]] || die 'artifact raced'
fsync "$tmp";ln -- "$tmp" "$output"||die 'create-once failed';fsync "$output";rm -f -- "$tmp";printf '%s  %s\n' "$(sha "$output")" "$output"
