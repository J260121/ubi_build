#!/bin/bash
set -euo pipefail

IMAGE_MK="include/image.mk"
NETWORK_FILE="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"

echo "Apply iKuai Q6000 eMMC"

for file in "$IMAGE_MK" "$FILOGIC_MK"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file"
        exit 1
    fi
done

# Do not edit the Rust Makefile before feeds are updated.

# Add the build date to the image prefix.
python3 <<'PY'
from pathlib import Path

p = Path("include/image.mk")
text = p.read_text()
date_line = "BUILD_DATE := $(shell date +%Y%m%d)"

if date_line not in text:
    anchor = "IMG_PREFIX:="
    if anchor not in text:
        raise SystemExit(f"ERROR: {anchor} not found in {p}")
    text = text.replace(anchor, date_line + "\n" + anchor, 1)

lines = text.splitlines()
for i, line in enumerate(lines):
    if line.startswith("IMG_PREFIX:="):
        if "$(BUILD_DATE)" not in line and "$(SUBTARGET)" in line:
            lines[i] = line.replace(
                "$(SUBTARGET)", "$(SUBTARGET)-$(BUILD_DATE)", 1
            )
        break
else:
    raise SystemExit(f"ERROR: IMG_PREFIX not found in {p}")

p.write_text("\n".join(lines) + "\n")
print("OK: image filename date configured")
PY

# Add the device definition without fragile multiline sed escaping.
python3 <<'PY'
from pathlib import Path

p = Path("target/linux/mediatek/image/filogic.mk")
text = p.read_text()
name = "ikuai-q6000-emmc"
definition = f"define Device/{name}"
target = f"TARGET_DEVICES += {name}"

if definition not in text:
    anchor = "TARGET_DEVICES += cudy_wbr3000uax-v1-ubootmod"
    if anchor not in text:
        raise SystemExit(f"ERROR: insertion anchor not found in {p}: {anchor}")

    device = r"""
define Device/ikuai-q6000-emmc
  DEVICE_VENDOR := ikuai
  DEVICE_MODEL := q6000
  DEVICE_DTS := mt7986a-ikuai-q6000-emmc
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := e2fsprogs f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef

TARGET_DEVICES += ikuai-q6000-emmc
"""
    text = text.replace(anchor, device.strip() + "\n\n" + anchor, 1)
    p.write_text(text)
    print("OK: eMMC device definition inserted")
else:
    print("INFO: eMMC device definition already exists; skip")

text = p.read_text()
if text.count(definition) != 1:
    raise SystemExit("ERROR: device definition missing or duplicated")
if text.count(target) != 1:
    raise SystemExit("ERROR: TARGET_DEVICES entry missing or duplicated")
print("OK: eMMC device definition validated")
PY

# Add the board network match rule if its anchor exists.
if [ -f "$NETWORK_FILE" ]; then
    python3 <<'PY'
from pathlib import Path

p = Path("target/linux/mediatek/filogic/base-files/etc/board.d/02_network")
text = p.read_text()

if "ikuai,q6000|" in text:
    print("INFO: network rule already exists; skip")
else:
    lines = text.splitlines(keepends=True)
    anchor = next(
        (i for i, line in enumerate(lines) if "netis,nx31|" in line),
        None,
    )
    if anchor is None:
        print("WARNING: netis,nx31 anchor not found; network rule skipped")
    else:
        newline = "\r\n" if "\r\n" in text else "\n"
        lines.insert(anchor + 1, "\tikuai,q6000|\\\n".replace("\n", newline))
        p.write_text("".join(lines))
        print("OK: network rule inserted")
PY
else
    echo "WARNING: Network file not found; skip network rule"
fi

git diff --check
echo "iKuai Q6000 eMMC DIY completed"
