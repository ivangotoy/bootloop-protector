# Bootloop Protector - uninstall
# Switches back on what a rescue disabled (state/rescue.list), then removes the data folder.
# BP_ROOT is empty on the device; it only exists to test the logic off-device.
case $0 in */*) MODDIR=${0%/*} ;; *) MODDIR=${BP_ROOT:-}/data/adb/modules/bootloop-protector ;; esac
if [ -f "$MODDIR/common.sh" ] && [ -f "${BP_ROOT:-}/data/adb/bootloop-protector/state/rescue.list" ]; then
  BP_STAGE=uninstall
  . "$MODDIR/common.sh"
  restore >/dev/null 2>&1
fi
rm -rf "${BP_ROOT:-}/data/adb/bootloop-protector"
exit 0
