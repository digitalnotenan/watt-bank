#!/bin/bash
# Rebuilds the IR head firmware binaries that Watt Bank installs with one click (needs arduino-cli + the esp32 core).
#   brew install arduino-cli
#   arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
#   arduino-cli core update-index && arduino-cli core install esp32:esp32
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
# the prefix maps keep your home folder (user name) out of the binaries
MAP="-ffile-prefix-map=$HOME=~ -fmacro-prefix-map=$HOME=~"
arduino-cli compile --fqbn esp32:esp32:esp32 --clean --output-dir "$OUT" \
  --build-property "compiler.c.extra_flags=$MAP" --build-property "compiler.cpp.extra_flags=$MAP" wattbank_ir
mkdir -p build
cp "$OUT/wattbank_ir.ino.bin" build/wattbank_ir.bin
cp "$OUT/wattbank_ir.ino.bootloader.bin" build/wattbank_ir.bootloader.bin
cp "$OUT/wattbank_ir.ino.partitions.bin" build/wattbank_ir.partitions.bin
cp "$(ls -d "$HOME"/Library/Arduino15/packages/esp32/hardware/esp32/*/tools/partitions/boot_app0.bin | tail -1)" build/
echo "Firmware built into firmware/build/"
