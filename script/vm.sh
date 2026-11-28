#!/usr/bin/env bash
# The windowless defi-e2e Tart VM. Each session boots a throwaway APFS clone of the image and deletes it
# on exit, so sessions never grow the image; only `prepare` boots and changes the image itself.
# Usage: script/vm.sh prepare       clean and tune the image; run once after creating the VM
#        script/vm.sh shell ['CMD']  a guest shell, or one command, in a session clone
# test_vm.sh, perf_release.sh and glitch_vm.sh source it for vm_lock, vm_start and vm.
VM="${DEFI_VM:-defi-e2e}"
RUN_VM="${RUN_VM:-$VM-session}"
KEY="$HOME/.tart/${VM}_ed25519"
VM_SSH=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)
command -v tart >/dev/null || { echo "Install Tart first: https://tart.run" >&2; exit 2; }
tart get "$VM" >/dev/null 2>&1 || {
  echo "Create the VM first: tart clone ghcr.io/cirruslabs/macos-golden-gate-base:latest $VM && tart set $VM --cpu 4 --memory 4096 && script/vm.sh prepare" >&2
  exit 2
}

vm() {
  ssh "${VM_SSH[@]}" "admin@$(tart ip "$RUN_VM")" "$@"
}

# Runs the given script again under the per-VM lock: concurrent sessions would share one guest desktop.
vm_lock() {
  export DEFI_VM_LOCKED=1
  exec lockf -k "$HOME/.tart/$VM.lock" "$@"
}

vm_stop() {
  tart stop "$RUN_VM" >/dev/null 2>&1 || true
  [[ "$RUN_VM" == "$VM" ]] || tart delete "$RUN_VM" >/dev/null 2>&1 || true
}

vm_boot() {
  XCODE="$(cd "$(xcode-select -p)/../.." && pwd)"
  nohup tart run "$RUN_VM" --no-graphics --no-audio "--dir=xcode:$XCODE:ro" >/dev/null 2>&1 &
  tart ip "$RUN_VM" --wait 180 >/dev/null
  for attempt in {1..60}; do
    tart exec "$RUN_VM" /usr/bin/true 2>/dev/null && break
    [[ "$attempt" -lt 60 ]] || { echo "The VM guest agent did not answer" >&2; exit 1; }
    sleep 2
  done
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "$VM" -f "$KEY"
  tart exec "$RUN_VM" /bin/sh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qsF '$(cat "$KEY.pub")' ~/.ssh/authorized_keys || echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
}

vm_start() {
  # Holding the lock makes stopping a running image and a leftover clone safe; a running image would clone torn.
  tart stop "$VM" >/dev/null 2>&1 || true
  vm_stop
  tart clone "$VM" "$RUN_VM"
  trap vm_stop EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  vm_boot

  # Post-boot daemons saturate the guest and would slow the tests' own timing.
  # Read instantaneous idle time: the load average keeps decaying for minutes after the burst ends.
  calm=0
  for _ in {1..60}; do
    if [[ "$(vm "top -l 2 -s 3 -n 0 | awk '/CPU usage/ {idle = \$7} END {print int(idle)}'")" -ge 70 ]]; then calm=$((calm + 1)); else calm=0; fi
    [[ "$calm" -ge 3 ]] && break
  done
}

vm_prepare() {
  RUN_VM="$VM"
  vm_stop
  trap vm_stop EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  vm_boot
vm 'defaults write com.apple.WindowManager StandardHideWidgets -int 1; rm -rf ~/Library/Caches/* 2>/dev/null; true'
vm 'sudo -n sh -s' <<'GUEST'
mdutil -a -i off >/dev/null 2>&1
# Guest tools such as /usr/bin/python3 resolve through the shared host Xcode, not Command Line Tools.
ln -sfn "/Volumes/My Shared Files/xcode" /Applications/Xcode.app && xcode-select -s /Applications/Xcode.app ||
  echo "The guest could not select the shared Xcode; /usr/bin/python3 will not work in it" >&2
for k in AutomaticDownload ConfigDataInstall CriticalUpdateInstall AutomaticallyInstallMacOSUpdates; do
  defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool false
done

# Keep the image at its bare minimum: the home keeps its standard folders, the guest's installed app,
# the ssh key and the shell profile that reaches the guest agent; every other leftover goes.
cd /Users/admin && for f in * .[!.]*; do
  case "$f" in
    Applications|Desktop|Documents|Downloads|Library|Movies|Music|Pictures|Public|.ssh|.zprofile|.profile|.CFUserTextEncoding|.homebrew) ;;
    *) rm -rf "$f" ;;
  esac
done
rm -rf /Users/admin/.Trash/* /Users/admin/Library/Caches/* /Library/Caches/* /private/var/folders/*/*/T/* \
  /private/var/folders/*/*/C/com.apple.dt.InstrumentsCLI 2>/dev/null
mkdir -p /Users/admin/.Trash && chown admin:staff /Users/admin/.Trash
# Grants for binaries that sessions copied into the home, such as repro tools, outlive the files.
sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \
  "delete from access where client like '/Users/admin/%' and client not like '/Users/admin/Applications/%';"
# Downloaded assets for services Defi never uses: Look Up dictionaries, Siri, speech and search models.
rm -rf /System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_* /System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_* \
  /System/Library/AssetsV2/com_apple_MobileAsset_TTSAXResourceModelAssets /System/Library/AssetsV2/com_apple_MobileAsset_UAF_SearchQueryUnderstanding
log erase --all >/dev/null

# Trim services Defi never touches; launchd keeps this across reboots, so it applies from the next boot.
pattern='intelligen|siri|workflow|shortcut|imagent|imtransfer|facetime|cloud|bird|photo|mediaanalysis|knowledge|suggest|parsec|maps|news|weather|stocks|calendar|remind|game|music|podcast|appstore|commerce|triald|modelcatalog|generative|homed|backupd|corespotlight|biome'
for plist in /System/Library/LaunchAgents/*.plist; do
  label="$(basename "$plist" .plist)"
  if echo "$label" | grep -Eiq "$pattern"; then launchctl disable "gui/501/$label"; fi
done
for plist in /System/Library/LaunchDaemons/*.plist; do
  label="$(basename "$plist" .plist)"
  if echo "$label" | grep -Eiq "$pattern"; then launchctl disable "system/$label"; fi
done
# The image's login-item banner would otherwise stay up and block the pointer over it.
rm -rf "/Users/admin/Library/Group Containers/group.com.apple.usernoted/db2"
# tart stop drops writes still in the guest's cache.
sync
GUEST
vm 'df -h /System/Volumes/Data | tail -1'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    prepare | shell) [[ -n "${DEFI_VM_LOCKED:-}" ]] || vm_lock "${BASH_SOURCE[0]}" "$@" ;;
    *) sed -n '4,5p' "$0" >&2; exit 2 ;;
  esac
  if [[ "$1" == prepare ]]; then
    vm_prepare
  else
    shift
    vm_start
    if [[ $# -gt 0 ]]; then vm "$*"; else ssh "${VM_SSH[@]}" -t "admin@$(tart ip "$RUN_VM")"; fi
  fi
fi
