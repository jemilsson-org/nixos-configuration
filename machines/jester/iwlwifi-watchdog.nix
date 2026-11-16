{ pkgs, ... }:

# Reload the AX211 Wi-Fi driver after a firmware crash.
#
# 2026-11-16 09:41: "Microcode SW error detected" / NMI_INTERRUPT_UMAC_FATAL.
# The in-driver reset failed and every later command logged "Failed to send
# MAC_CONFIG_CMD ... -5" until reboot. Reloading iwlmvm and iwlwifi
# re-initialises the device and restores Wi-Fi without a reboot.
#
# The watch reads the kernel ring only (`journalctl -k`), so this unit's own
# log lines cannot re-trigger it. One reload per 120 s: a failed reset logs
# many matching lines, and the reload itself logs more.
{
  systemd.services.iwlwifi-watchdog = {
    description = "Reload iwlwifi after a firmware crash";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-journald.service" ];
    path = with pkgs; [ kmod systemd gnugrep coreutils ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
    script = ''
      last=0
      journalctl -kf -n0 -o cat \
        | grep --line-buffered -E 'iwlwifi 0000:00:14\.3: (Failed to send MAC_CONFIG_CMD|Failed to add PHY context)' \
        | while IFS= read -r line; do
            now=$(date +%s)
            if [ $((now - last)) -lt 120 ]; then
              continue
            fi
            last=$now
            echo "iwlwifi-watchdog: firmware error, reloading driver: $line"
            # modprobe -r fails if a module is busy; load anyway so a partial
            # unload still ends with the driver present.
            modprobe -r iwlmvm iwlwifi || echo "iwlwifi-watchdog: unload failed"
            modprobe iwlwifi || echo "iwlwifi-watchdog: load failed"
          done
    '';
  };
}
