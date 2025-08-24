#!/usr/bin/env bash
set -euo pipefail

# grub-acpi-osi.sh
# Usage:
#   sudo ./grub-acpi-osi.sh --add [--no-update-grub] [--backup-dir DIR]
#   sudo ./grub-acpi-osi.sh --restore       # restores the original backup (.orig)
#   sudo ./grub-acpi-osi.sh --restore-file /path/to/backup
#   sudo ./grub-acpi-osi.sh --help

FILE="/etc/default/grub"
DEFAULT_BACKUP_DIR="/var/backups/grub-acpi-osi"
UPDATE_GRUB=true
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
ACTION=""
RESTORE_FILE=""

show_help() {
cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --add                 Add acpi_osi=! and acpi_osi="Windows 2009" to
                        GRUB_CMDLINE_LINUX_DEFAULT (idempotent).
  --restore             Restore the original grub file saved as <file>.orig
  --restore-file PATH   Restore a specific backup file (provide full path).
  --no-update-grub      Don't run update-grub after making changes/restoring.
  --backup-dir DIR      Store backups under DIR (default: $DEFAULT_BACKUP_DIR).
  -h, --help            Show this help and exit.

Notes:
 - The script creates a timestamped backup before modifying: <backup-dir>/grub.<timestamp>
 - On the very first --add it also creates an <file>.orig copy you can restore with --restore.
EOF
}

# Parse args
if [ $# -eq 0 ]; then
  show_help
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --add) ACTION="add"; shift ;;
    --restore) ACTION="restore"; shift ;;
    --restore-file) ACTION="restore-file"; RESTORE_FILE="$2"; shift 2 ;;
    --no-update-grub) UPDATE_GRUB=false; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown option: $1"; show_help; exit 2 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root (use sudo)."
  exit 1
fi

mkdir -p "$BACKUP_DIR"
timestamp() { date +%Y%m%d%H%M%S; }

# helper: create backup, returns backup path
create_backup() {
  local src="$1"
  local ts
  ts="$(timestamp)"
  local dest="$BACKUP_DIR/grub.$ts"
  cp -a -- "$src" "$dest"
  echo "$dest"
}

# helper: restore (from file to FILE)
do_restore_from() {
  local src="$1"
  if [ ! -f "$src" ]; then
    echo "Restore file not found: $src"
    return 1
  fi

  # backup current before overwriting
  local pre_backup
  pre_backup="$(create_backup "$FILE")"
  echo "Saved current $FILE to: $pre_backup"

  cp -a -- "$src" "$FILE"
  echo "Restored $FILE from $src"

  if $UPDATE_GRUB && command -v update-grub >/dev/null 2>&1; then
    echo "Running update-grub..."
    update-grub
    echo "update-grub finished."
  else
    if $UPDATE_GRUB; then
      echo "update-grub not found — please run 'sudo update-grub' manually to apply the change."
    else
      echo "Skipped update-grub (--no-update-grub)."
    fi
  fi
}

if [ "$ACTION" = "restore-file" ]; then
  if [ -z "$RESTORE_FILE" ]; then
    echo "--restore-file requires a path argument."
    exit 2
  fi
  do_restore_from "$RESTORE_FILE"
  exit $?
fi

if [ "$ACTION" = "restore" ]; then
  # restore from FILE.orig if it exists, otherwise fail / list backups
  ORIG="${FILE}.orig"
  if [ -f "$ORIG" ]; then
    do_restore_from "$ORIG"
    exit $?
  else
    echo "Original backup not found at $ORIG"
    echo "Available backups in $BACKUP_DIR:"
    ls -1 -- "$BACKUP_DIR" || true
    exit 2
  fi
fi

if [ "$ACTION" = "add" ]; then
  # create timestamped backup
  bak="$(create_backup "$FILE")"
  echo "Backup created: $bak"

  # if .orig doesn't exist, create it (so user can always restore original)
  if [ ! -f "${FILE}.orig" ]; then
    cp -a -- "$FILE" "${FILE}.orig"
    echo "Saved original copy: ${FILE}.orig"
  fi

  # Use embedded Python for robust editing
  python3 - "$FILE" <<'PY'
import sys, re

file = sys.argv[1]
with open(file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

out = []
done = False
for line in lines:
    if not done and re.match(r'^\s*GRUB_CMDLINE_LINUX_DEFAULT\s*=', line) and not re.match(r'^\s*#', line):
        m = re.match(r'^(\s*GRUB_CMDLINE_LINUX_DEFAULT\s*=\s*)(.*)$', line)
        if not m:
            out.append(line)
            continue
        prefix = m.group(1)
        val = m.group(2).rstrip('\n')

        # Extract inner value and quote
        if len(val) >= 2 and val[0] in ('"', "'") and val[-1] == val[0]:
            quote = val[0]
            inner = val[1:-1]
        else:
            quote = '"'
            inner = val.strip()

        # For checks, unescape backslash-escaped quotes
        inner_unescaped = inner.replace('\\\"', '"').replace("\\'", "'")

        has_acpi_bang = 'acpi_osi=!' in inner_unescaped
        has_acpi_windows2009 = 'acpi_osi' in inner_unescaped and 'Windows 2009' in inner_unescaped

        # Build parts preserving existing spacing tokens
        parts = [p for p in inner.split() if p != '']

        if not has_acpi_bang:
            parts.append('acpi_osi=!')
        if not has_acpi_windows2009:
            # add escaped quotes so they survive inside the file quoted string
            parts.append('acpi_osi=\\\"Windows 2009\\\"')

        new_inner = ' '.join(parts)
        new_line = prefix + quote + new_inner + quote + '\n'
        out.append(new_line)
        done = True
    else:
        out.append(line)

# If we never found the key, append it at the end
if not done:
    # create default line
    new_line = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash acpi_osi=! acpi_osi=\\\"Windows 2009\\\""\n'
    out.append('\n# Added by grub-acpi-osi.sh\n' + new_line)

with open(file, 'w', encoding='utf-8') as f:
    f.writelines(out)

print("Updated", file)
PY

  echo "Modification applied to $FILE"

  if $UPDATE_GRUB && command -v update-grub >/dev/null 2>&1; then
    echo "Running update-grub..."
    update-grub
    echo "update-grub finished."
  else
    if $UPDATE_GRUB; then
      echo "update-grub not found — please run 'sudo update-grub' manually to apply the change."
    else
      echo "Skipped update-grub (--no-update-grub)."
    fi
  fi

  exit 0
fi

echo "No action specified. Use --help for usage."
exit 1
