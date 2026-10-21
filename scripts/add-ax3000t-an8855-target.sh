#!/usr/bin/env bash
set -euo pipefail

OPENWRT_DIR="${1:-openwrt}"
cd "$OPENWRT_DIR"

MAKEFILE="target/linux/mediatek/image/filogic.mk"
NETWORK="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
PLATFORM="target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
DTS="target/linux/mediatek/dts/mt7981b-xiaomi-mi-router-ax3000t-an8855.dts"

for f in "$MAKEFILE" "$NETWORK" "$PLATFORM" target/linux/mediatek/dts/mt7981b-xiaomi-mi-router-ax3000t.dtsi; do
  [[ -f "$f" ]] || { echo "Required OpenWrt source file is missing: $f" >&2; exit 1; }
done

if grep -q 'xiaomi_mi-router-ax3000t-an8855' "$MAKEFILE" ||
   grep -q 'xiaomi,mi-router-ax3000t-an8855' "$NETWORK" ||
   grep -q 'xiaomi,mi-router-ax3000t-an8855' "$PLATFORM"; then
  echo "AN8855 target or board mapping already exists; refusing to patch twice." >&2
  exit 1
fi

python3 - "$MAKEFILE" "$NETWORK" "$PLATFORM" "$DTS" <<'PY_AN8855'
from pathlib import Path
import re
import sys

mk_path, network_path, platform_path, dts_path = map(Path, sys.argv[1:5])
mk = mk_path.read_text()
network = network_path.read_text()
platform = platform_path.read_text()

marker = "TARGET_DEVICES += xiaomi_mi-router-ax3000t\n"
if mk.count(marker) != 1:
    raise SystemExit(f"Expected one stock AX3000T target marker, found {mk.count(marker)}")

block = r'''
define Device/xiaomi_mi-router-ax3000t-an8855
  DEVICE_VENDOR := Xiaomi
  DEVICE_MODEL := Mi Router AX3000T (AN8855)
  DEVICE_VARIANT := single UBI
  DEVICE_DTS := mt7981b-xiaomi-mi-router-ax3000t-an8855
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
ifeq ($(IB),)
ifneq ($(CONFIG_TARGET_ROOTFS_INITRAMFS),)
  ARTIFACTS := initramfs-factory.ubi
  ARTIFACT/initramfs-factory.ubi := append-image-stage initramfs-kernel.bin | ubinize-kernel
endif
endif
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += xiaomi_mi-router-ax3000t-an8855
'''
mk_new = mk.replace(marker, marker + block + "\n", 1)

net_marker = "\txiaomi,mi-router-ax3000t|\\\n"
if network.count(net_marker) != 2:
    raise SystemExit(f"Expected two AX3000T board cases in 02_network, found {network.count(net_marker)}")
network_new = network.replace(net_marker, net_marker + "\txiaomi,mi-router-ax3000t-an8855|\\\n")

pattern = re.compile(r'(?m)^([ \t]*)jiorouter,ax6000-jidu6j01\)\n([ \t]*CI_UBIPART="ubi")')
if len(list(pattern.finditer(platform))) != 1:
    raise SystemExit("Expected one single-UBI upgrade anchor for AN8855.")
platform_new = pattern.sub(
    lambda m: f"{m.group(1)}jiorouter,ax6000-jidu6j01|\\\n"
              f"{m.group(1)}xiaomi,mi-router-ax3000t-an8855)\n{m.group(2)}",
    platform, count=1)

dts = '''// SPDX-License-Identifier: GPL-2.0-or-later OR MIT

/dts-v1/;
#include "mt7981b-xiaomi-mi-router-ax3000t.dtsi"

/ {
	model = "Xiaomi Mi Router AX3000T (AN8855)";
	compatible = "xiaomi,mi-router-ax3000t-an8855", "mediatek,mt7981";
};

&spi_nand {
	mediatek,nmbm;
	mediatek,bmt-max-ratio = <1>;
	mediatek,bmt-max-reserved-blocks = <64>;
	mediatek,bmt-mtd-overridden-oobsize = <64>;
};

&partitions {
	/* V2/AN8855 uses its single-UBI stock-layout partition map. */
	partition@600000 {
		label = "ubi";
		reg = <0x600000 0x7000000>;
	};
};
'''
mk_path.write_text(mk_new)
network_path.write_text(network_new)
platform_path.write_text(platform_new)
dts_path.write_text(dts)
PY_AN8855

grep -q 'compatible = "xiaomi,mi-router-ax3000t-an8855"' "$DTS"
grep -q 'label = "ubi"' "$DTS"
grep -q 'TARGET_DEVICES += xiaomi_mi-router-ax3000t-an8855' "$MAKEFILE"
grep -q 'xiaomi,mi-router-ax3000t-an8855' "$NETWORK"
grep -q 'xiaomi,mi-router-ax3000t-an8855' "$PLATFORM"
echo "AX3000T V2 AN8855 target and single-UBI upgrade mappings added."
