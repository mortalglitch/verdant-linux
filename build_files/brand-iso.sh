#!/usr/bin/env bash
#
# Brand the bootc-image-builder installer ISO as Verdant.
#
# BIB builds the ISO from Fedora's installer packages, so it ships saying
# "Fedora Linux" in three places: the volume label, the GRUB boot menu, and
# Anaconda's welcome screen (.buildstamp). This script rebrands the finished
# ISO in place:
#
#   1. Volume label  Fedora-S-dvd-x86_64-44 -> Verdant-44-x86_64, plus every
#      grub.cfg search/hd:LABEL reference (EFI menu, BIOS menu, and the copy
#      inside /IMAGES/EFIBOOT.IMG).
#   2. Boot menu titles: "Install Fedora Linux 44" -> "Install Verdant 44"
#      etc. (defensive — after the image's os-release rename, BIB already
#      emits "Install Verdant 44"; this covers ISOs built before that).
#   3. /IMAGES/PRODUCT.IMG — Anaconda's official per-release override image.
#      The installer initrd fetches and unpacks it over the installer
#      environment at boot (see usr/lib/anaconda-lib.sh), so it ships:
#        .buildstamp                    -> welcome screen product name
#        usr/share/anaconda/pixmaps/*   -> Verdant stylesheet + logo art
#
# Tools: isoinfo, xorriso, mtools, cpio, gzip, ImageMagick.
# Usage: brand-iso.sh <install.iso> [version]

set -euo pipefail

IN=${1:-output/bootiso/install.iso}
VERSION=${2:-44}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOGO="$REPO/logo/verdant_1.png"

[[ -f "$IN" ]]   || { echo "brand-iso: missing $IN (run just build-iso first)" >&2; exit 1; }
[[ -f "$LOGO" ]] || { echo "brand-iso: missing $LOGO" >&2; exit 1; }

OLD_LABEL=$(isoinfo -d -i "$IN" 2>/dev/null | sed -n 's/^Volume id: *//p')
NEW_LABEL="Verdant-$VERSION-x86_64"
[[ -n "$OLD_LABEL" ]] || { echo "brand-iso: could not read volume label from $IN" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo ">> Label: $OLD_LABEL -> $NEW_LABEL"

# --- 1. Pull out the files we rewrite ----------------------------------------
mkdir -p "$WORK/iso/EFI/BOOT" "$WORK/iso/BOOT/GRUB2" "$WORK/iso/IMAGES"
isoinfo -i "$IN" -x "/EFI/BOOT/GRUB.CFG;1"  > "$WORK/iso/EFI/BOOT/GRUB.CFG"
isoinfo -i "$IN" -x "/BOOT/GRUB2/GRUB.CFG;1" > "$WORK/iso/BOOT/GRUB2/GRUB.CFG"
isoinfo -i "$IN" -x "/IMAGES/EFIBOOT.IMG;1"  > "$WORK/iso/IMAGES/EFIBOOT.IMG"

rewrite_cfg() {
  sed -i \
    -e "s/$OLD_LABEL/$NEW_LABEL/g" \
    -e "s/Fedora Linux $VERSION/Verdant $VERSION/g" \
    -e "s/Fedora Linux/Verdant/g" \
    "$1"
}
rewrite_cfg "$WORK/iso/EFI/BOOT/GRUB.CFG"
rewrite_cfg "$WORK/iso/BOOT/GRUB2/GRUB.CFG"

# The EFI firmware menu lives inside EFIBOOT.IMG (FAT). mtype emits CRLF;
# strip it and rewrite. mtools 4.0.49 cannot overwrite a FAT file in place
# (silent failure), so delete and recreate.
mtype -i "$WORK/iso/IMAGES/EFIBOOT.IMG" ::/EFI/BOOT/GRUB.CFG \
  | sed \
    -e 's/\r$//' \
    -e "s/$OLD_LABEL/$NEW_LABEL/g" \
    -e "s/Fedora Linux $VERSION/Verdant $VERSION/g" \
    -e "s/Fedora Linux/Verdant/g" \
  > "$WORK/efiboot-grub.cfg"
mdel -i "$WORK/iso/IMAGES/EFIBOOT.IMG" ::/EFI/BOOT/GRUB.CFG
mcopy -i "$WORK/iso/IMAGES/EFIBOOT.IMG" "$WORK/efiboot-grub.cfg" ::/EFI/BOOT/GRUB.CFG

# --- 2. Build /IMAGES/PRODUCT.IMG (Anaconda override) -------------------------
PXM="$WORK/product/usr/share/anaconda/pixmaps"
mkdir -p "$PXM"

cat > "$WORK/product/.buildstamp" <<EOF
[Main]
product = Verdant
version = $VERSION
isfinal = True
uuid = $(date -u +%Y%m%d%H%M).x86_64

[Compose]
osbuild = devel
EOF

cat > "$PXM/fedora.css" <<'EOF'
/* Anaconda gtk style overrides for Verdant */

/* vendor-specific colors */
@define-color verdant #9CAF88;

/* logo and sidebar classes */

/* The sidebar consists of three parts: a background, a logo, and a product
 * logo, rendered in that order.
 */
.logo-sidebar {
    background-image: url('/usr/share/anaconda/pixmaps/sidebar-bg.png');
    background-color: @verdant;
    background-repeat: no-repeat;
}

/* Add a logo to the sidebar */
.logo {
    background-image: url('/usr/share/anaconda/pixmaps/sidebar-logo.png');
    background-position: 50% 20px;
    background-repeat: no-repeat;
    background-color: transparent;
}

/* This is a placeholder to be filled by a product-specific logo. */
.product-logo {
    background-image: none;
    background-color: transparent;
}

AnacondaSpokeWindow #nav-box {
    background-color: #1B1A16;
    background-image: url('/usr/share/anaconda/pixmaps/topbar-bg.png');
    background-repeat: repeat;
    color: white;
}
EOF

# Verdant art (dimensions match Fedora's originals so the layout holds):
#   sidebar-logo 150x69 (w150), anaconda_header x36, sidebar-bg 406x767,
#   topbar-bg 1040x132 (sage accent line over a dark gradient; tiles in x).
magick "$LOGO" -trim +repage -resize 150x   "$PXM/sidebar-logo.png"
magick "$LOGO" -trim +repage -resize x36    "$PXM/anaconda_header.png"
magick -size 406x767 gradient:'#3A3931'-'#1B1A16' "$PXM/sidebar-bg.png"
magick -size 1040x2 xc:'#9CAF88' \
  \( -size 1040x130 gradient:'#24231F'-'#1B1A16' \) \
  -append "$PXM/topbar-bg.png"

(cd "$WORK/product" && find . -print0 | cpio --null --create --format=newc | gzip -9) \
  > "$WORK/iso/IMAGES/PRODUCT.IMG"

# --- 3. Rewrite the ISO (full rewrite via -indev/-outdev) ---------------------
# xorriso's tree paths use the original (lowercase) file names, NOT the uppercase
# ISO9660 names that isoinfo shows: /EFI/BOOT/grub.cfg, not /EFI/BOOT/GRUB.CFG.
#   -update  replaces an existing file in place (no suffixed duplicates)
#   -map     inserts a brand-new file (product.img)
#   -boot_image any replay  preserves the El Torito catalog (BIOS + UEFI
#           isohybrid) and keeps the isohybrid MBR valid (offsets recalculated).
echo ">> Rewriting ISO (label + cfgs + product.img)..."
xorriso -indev "$IN" -outdev "$IN.tmp" \
  -volid "$NEW_LABEL" \
  -boot_image any replay \
  -update "$WORK/iso/EFI/BOOT/GRUB.CFG"   /EFI/BOOT/grub.cfg \
  -update "$WORK/iso/BOOT/GRUB2/GRUB.CFG" /boot/grub2/grub.cfg \
  -update "$WORK/iso/IMAGES/EFIBOOT.IMG"  /images/efiboot.img \
  -map    "$WORK/iso/IMAGES/PRODUCT.IMG"  /images/product.img
mv -f "$IN.tmp" "$IN"

# --- 4. Verify ------------------------------------------------------------------
echo ">> Verifying..."
echo "   label: $(isoinfo -d -i "$IN" 2>/dev/null | sed -n 's/^Volume id: *//p')"
isoinfo -i "$IN" -x "/EFI/BOOT/GRUB.CFG;1" 2>/dev/null | grep -E "menuentry|search" | sed 's/^[[:space:]]*/   /'
echo "   product.img:"
isoinfo -i "$IN" -x "/IMAGES/PRODUCT.IMG;1" 2>/dev/null | gzip -dc | cpio -t 2>/dev/null | sed 's/^/     /'
xorriso -indev "$IN" -report_el_torito plain 2>/dev/null | head -4 | sed 's/^/   /'
echo ">> Done: $IN"
