#!/bin/bash
# Build the SWEET iOS root on macOS (no apfs-fuse / no Linux needed).
#
#   sudo tools/mkiosroot-macos.sh <ipsw-dir> <out.img> [SIZE]
#
#   <ipsw-dir>  a directory holding the *extracted* IPSW: BuildManifest.plist
#               plus the three disk images. The roles are resolved from
#               BuildManifest.plist (OS / SystemOS / AppOS), so the numeric
#               018-xxxxx-0xx.dmg names do not have to be guessed.
#   <out.img>   raw case-sensitive journaled HFS+ image (sparse on disk)
#   [SIZE]      default 16g
#
# Differences from tools/mkiosroot.sh (Linux):
#   - APFS images are mounted with hdiutil instead of apfs-fuse
#   - the filesystem is made with newfs_hfs instead of mkfs.hfsplus
#   - the SWEET tweaks (tools/sweet-root-tweaks.py) are applied in the same
#     mount, so the image is ready to flash when this returns
#   - must run as root: `sudo tools/mkiosroot-macos.sh ...`
#
# Requires: macOS, Xcode command line tools (hdiutil, newfs_hfs, fsck_hfs),
# rsync (the system one is fine; `brew install rsync` if it is openrsync),
# python3 for the tweaks, and ~40 GB free for a 16 GB image.
set -euo pipefail

usage() { sed -n '2,20p' "$0"; exit 2; }
[[ $# -ge 2 ]] || usage

[[ $(id -u) -eq 0 ]] || { echo "error: run me with sudo" >&2; exit 1; }

IPSW_DIR=$(cd "$1" && pwd)
OUT=$2
SIZE=${3:-16g}
TOOLS=$(cd "$(dirname "$0")" && pwd)

[[ -f "$IPSW_DIR/BuildManifest.plist" ]] || {
	echo "error: $IPSW_DIR/BuildManifest.plist not found" >&2
	echo "       unzip the IPSW first (unzip -q *.ipsw -d ipsw16)" >&2
	exit 1
}
[[ ! -e "$OUT" ]] || { echo "refusing to overwrite $OUT" >&2; exit 1; }

for t in hdiutil newfs_hfs fsck_hfs rsync python3 plutil; do
	command -v "$t" >/dev/null || { echo "error: missing $t" >&2; exit 1; }
done

# --- resolve the three image roles from the manifest ----------------------
role_path() {
	local key v
	for key in "$@"; do
		v=$(plutil -extract "BuildIdentities.0.Manifest.$key.Info.Path" raw \
			-o - "$IPSW_DIR/BuildManifest.plist" 2>/dev/null || true)
		if [[ -n $v ]]; then
			printf '%s\n' "$v"
			return 0
		fi
	done
	return 1
}
# iOS 16 manifests name the cryptexes "Cryptex1,SystemOS"/"Cryptex1,AppOS";
# older ones use plain SystemOS/AppOS.
OS_IMG=$(role_path OS) || true
SYSOS_IMG=$(role_path "Cryptex1,SystemOS" SystemOS) || true
APPOS_IMG=$(role_path "Cryptex1,AppOS" AppOS) || true
[[ -n $OS_IMG && -n $SYSOS_IMG && -n $APPOS_IMG ]] || {
	echo "error: manifest has no OS / SystemOS / AppOS roles (needs an iOS 16 IPSW)" >&2
	exit 1
}
for f in "$OS_IMG" "$SYSOS_IMG" "$APPOS_IMG"; do
	[[ -f "$IPSW_DIR/$f" ]] || { echo "error: $IPSW_DIR/$f missing" >&2; exit 1; }
done
echo "OS      : $OS_IMG ($(du -h "$IPSW_DIR/$OS_IMG" | cut -f1))"
echo "SystemOS: $SYSOS_IMG ($(du -h "$IPSW_DIR/$SYSOS_IMG" | cut -f1))"
echo "AppOS   : $APPOS_IMG ($(du -h "$IPSW_DIR/$APPOS_IMG" | cut -f1))"

# --- mount helpers -------------------------------------------------------
work=$(mktemp -d /tmp/iosroot.XXXXXX)
DEVICES=()
MOUNTS=()
HFSDEV=
cleanup() {
	# bash 3.2 (macOS) errors on "${arr[@]}" for an empty array under set -u
	for m in ${MOUNTS[@]:-}; do
		umount "$m" 2>/dev/null || hdiutil detach "$m" >/dev/null 2>&1 || true
	done
	for d in ${DEVICES[@]:-}; do hdiutil detach "$d" >/dev/null 2>&1 || true; done
	if [[ -n $HFSDEV ]]; then hdiutil detach "$HFSDEV" >/dev/null 2>&1 || true; fi
	rmdir "$work"/* "$work" 2>/dev/null || true
}
trap cleanup EXIT

# attach_apfs <image> <mountpoint>
attach_apfs() {
	local img=$1 mnt=$2
	mkdir -p "$mnt"
	if ! hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mnt" "$img" \
		>/dev/null 2>&1; then
		# raw APFS blob (the cryptex images are not UDIF): tell hdiutil so
		hdiutil attach -nobrowse -readonly -noverify \
			-imagekey diskimage-class=CRawDiskImage \
			-mountpoint "$mnt" "$img" >/dev/null || {
			echo "error: cannot attach $img" >&2; exit 1; }
	fi
	MOUNTS+=("$mnt")
}

attach_apfs "$IPSW_DIR/$OS_IMG"    "$work/os"
attach_apfs "$IPSW_DIR/$SYSOS_IMG" "$work/sysos"
attach_apfs "$IPSW_DIR/$APPOS_IMG" "$work/appos"

# apfs-fuse (Linux) exposes the volume under <mount>/root; hdiutil mounts the
# volume itself at <mount>. Accept either layout.
src_root() { if [[ -d "$1/root" ]]; then printf '%s' "$1/root"; else printf '%s' "$1"; fi; }
for d in os sysos appos; do
	r=$(src_root "$work/$d")
	if [[ ! -d "$r/System" && ! -d "$r/usr" ]]; then
		echo "error: $work/$d does not look like an iOS volume" >&2
		echo "       (contents: $(ls "$r" 2>/dev/null | head -3 | tr '\n' ' '))" >&2
		exit 1
	fi
done

# --- make the HFS+ volume ------------------------------------------------
# newfs_hfs only accepts a block device, not a plain file, so the sparse file
# is attached raw, formatted through its /dev/disk node, then re-attached.
echo "creating $OUT ($SIZE, sparse)"
mkfile -n "$SIZE" "$OUT"
HFSDEV=$(hdiutil attach -nomount -noverify -imagekey diskimage-class=CRawDiskImage "$OUT" |
	awk 'NR==1{print $1}')
[[ -n $HFSDEV ]] || { echo "error: cannot attach $OUT" >&2; exit 1; }
newfs_hfs -s -J -v iOSRoot "$HFSDEV" >/dev/null
hdiutil detach "$HFSDEV" >/dev/null
HFSDEV=
mkdir -p "$work/root"
# -owners on is mandatory: hdiutil otherwise mounts with noowners and every
# chown/install -o below is silently dropped, leaving launchd owned by the
# building user instead of root.
hdiutil attach -nobrowse -noverify -owners on -imagekey diskimage-class=CRawDiskImage \
	-mountpoint "$work/root" "$OUT" >/dev/null
MOUNTS=("$work/root" "${MOUNTS[@]}")

copy() {
	echo "copying $1 -> ${2#"$work/root"}"
	mkdir -p "$2"
	rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$(src_root "$work/os")"    "$work/root"
copy "$(src_root "$work/sysos")" "$work/root/private/preboot/Cryptexes/OS"
copy "$(src_root "$work/appos")" "$work/root/private/preboot/Cryptexes/App"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
for f in "$work/root/$dsc"/*; do
	[[ -e $f ]] || continue
	ln "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file that has no counterpart in the OS root.
for c in OS App; do
	(cd "$work/root/private/preboot/Cryptexes/$c" &&
		find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e "$work/root/$f" && ! -L "$work/root/$f" ]]; then
			mkdir -p "$work/root/$(dirname "$f")"
			src="$work/root/private/preboot/Cryptexes/$c/$f"
			# HFS+ cannot hard-link symlinks: copy those.
			if [[ -L $src ]]; then cp -P "$src" "$work/root/$f"; else ln "$src" "$work/root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores, normally made at restore: it checks owner _logd (272)
# and mode, plus a .migrated marker, else it crashes in libtrace.
db="$work/root/private/var/db"
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	# install(1) would try to copy the /dev/null *device*; create it instead
	: > "$db/$d/.migrated"
	chown 272:272 "$db/$d/.migrated"
	chmod 0644 "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
kb=$work/systembag.kb
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$kb"
# macOS install(1) cannot read /dev/stdin; stage the file first.
install -m 0600 -o 0 -g 0 "$kb" "$work/root/private/var/keybags/systembag.kb"
rm -f "$kb"

# macOS drops these on any volume it mounts; iOS does not want them.
rm -rf "$work/root/.fseventsd" "$work/root/.Spotlight-V100" "$work/root/.Trashes"

# --- SWEET tweaks: this is what makes it reach the home screen -----------
echo "applying sweet-root-tweaks.py"
python3 "$TOOLS/sweet-root-tweaks.py" "$work/root"

# --- ownership check: a noowners mount drops every chown ------------------
for p in sbin/launchd usr/libexec/safarifetcherd private/var/db/diagnostics \
	private/var/keybags/systembag.kb; do
	[[ -e "$work/root/$p" ]] && stat -f '  %u:%g %Sp %N' "$work/root/$p" |
		sed "s|$work/root||"
done
if [[ $(stat -f %u "$work/root/sbin/launchd") != 0 ]]; then
	echo "error: /sbin/launchd is not owned by root - the volume was mounted" >&2
	echo "       without owners (hdiutil -owners on); the image is unusable" >&2
	exit 1
fi

df -h "$work/root"
umount "$work/root"
MOUNTS=("${MOUNTS[@]:1}")

# Verify the volume. fsck_hfs -y cannot repair a plain file (it wants a
# character device) and blocks forever, so only the read-only check is run;
# the volume was unmounted cleanly above, which is what XNU needs.
fsck_hfs -f -n "$OUT" </dev/null || echo "warning: fsck_hfs reported problems" >&2

echo
echo "ok: $OUT"
ls -lh "$OUT"
echo
echo "This is a raw HFS+ volume, not a sparse image, so flash it without -S:"
echo "  fastboot flash userdata $OUT"
echo "It writes 16 GB and clears Android data on userdata - expected."
