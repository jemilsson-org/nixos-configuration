{ pkgs, ... }:

# Losslessly archives Claude Code session logs older than 7 days, and keeps
# them for possible future fine-tuning. Nothing is deleted without a verified
# copy. Each run writes ONE ~/archive/claude-logs/<YYYY-MM-DD>.tar.zst holding
# every eligible session (<proj>/<id>.jsonl plus its <proj>/<id>/ directory of
# subagent logs and tool results), so the root filesystem (91% of inodes used)
# pays one inode per run instead of hundreds per day. A session is skipped
# while its <id>/ directory holds any file newer than 7 days. Other files
# (bridge-pointer.json, memory/) and orphan directories are left alone. If
# nothing is eligible, no file is written. A failure fails the unit and leaves
# the originals in place.

{
  systemd.user.services.claude-log-archive = {
    unitConfig = {
      Description = "Archive old Claude Code session logs";
    };
    path = with pkgs; [ gnutar zstd findutils coreutils ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail

      archive_root="$HOME/archive/claude-logs"
      cd "$HOME/.claude/projects"

      # NUL-separated list of eligible paths. The ./ prefix keeps project
      # names that start with "-" from being read as options.
      list="$(mktemp)"
      trap 'rm -f "$list"' EXIT

      find . -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mtime +7 -print0 |
      while IFS= read -r -d "" file; do
        proj="$(basename "$(dirname "$file")")"
        id="$(basename "$file" .jsonl)"

        # Session still active: some file under <id>/ is newer than 7 days.
        if [ -d "./$proj/$id" ] && [ -n "$(find "./$proj/$id" -type f -mtime -7 -print -quit)" ]; then
          continue
        fi

        printf '%s\0' "./$proj/$id.jsonl" >> "$list"
        if [ -d "./$proj/$id" ]; then
          printf '%s\0' "./$proj/$id" >> "$list"
        fi
      done

      if [ ! -s "$list" ]; then
        exit 0
      fi

      mkdir -p "$archive_root"
      final="$archive_root/$(date +%F).tar.zst"
      if [ -e "$final" ]; then
        final="$archive_root/$(date +%F)-$(date +%s).tar.zst"
      fi
      tmp="$final.tmp"

      tar -I 'zstd -10 -T0' --null -T "$list" -cf "$tmp"
      zstd -tq "$tmp"
      zstd -dc "$tmp" | tar -tf - > /dev/null
      mv "$tmp" "$final"

      xargs -0 rm -rf -- < "$list"
    '';
  };

  systemd.user.timers.claude-log-archive = {
    unitConfig = {
      Description = "Daily archive of old Claude Code session logs";
    };
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };
}
