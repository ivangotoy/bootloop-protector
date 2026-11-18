## v1.3

- Fixed an endless reboot loop: a SystemUI or soft reboot loop that starts after the boot and
  is not caused by a module (or is caused by a module set to Never disable) now ends in
  "Gave up" after one rescue, instead of a rescue and a reboot every few minutes
- A level 1 rescue that finds nothing it may switch off goes on with level 2 right away,
  without a reboot that could not change anything
- Level 2 and the recovery rescue keep the active metamodule (KernelSU / SukiSU, for example
  meta-mm). Before, it was switched off too, so modules lost their mounted files and the root
  manager refused to install any module until it was enabled again by hand
- Volume Up rescue now works for the whole boot timeout (it stopped after 150 seconds), and the
  key watcher is fully stopped once the boot completes
- Recovery rescue: the count on the module card shows only the items switched off by that flash
- The installer shows your own "trusted after N minutes" setting

## v1.2

- The WebUI opens fast again on a quick reopen: no more waiting about 8 seconds for the status

## v1.1

- The WebUI opens much faster: status and settings show up first, and the module list
  needs far less work per module
- Log: auto refresh no longer jumps back to the top while you scroll through older lines
- Log: new copy button
- Log: new save button - writes the log with a short report (version, phone, root manager,
  settings, rescue state, modules) to the Download folder, handy for bug reports
- Flashing the zip in recovery now resets the boot counter, so the first boot after it
  does not start another rescue
- A rescue records each item before switching it off, so Restore never misses one

## v1.0

First release.

- Catches boot loops, stuck boots, zygote crash loops, soft reboot loops and SystemUI failures
- Smart rescue: first switches off only the modules and scripts that are new or changed since your trusted setup, everything only if that does not help
- Gives up instead of rebooting forever when the problem is not caused by modules
- Restore brings back exactly what a rescue disabled
- Never disable switch for modules and scripts that must always keep running
- Volume Up × 3 during the boot animation starts a rescue by hand
- Flash the zip in TWRP to switch off all modules when the phone cannot boot at all
- WebUI with Status, Modules, Settings and Log tabs, plus a full help page
- Status on the module card in the root manager
- No internet, all data in one folder: /data/adb/bootloop-protector
- Cleans up the leftovers of Yet Another Bootloop Protector on install
