#!/usr/bin/env bash
# Install scheduled etcd snapshots on ONE control plane. Run on each control plane, as a user with sudo.
#
#   ./etcd-snapshot-node-prep.sh            # dry run: checks and prints what it would do
#   ./etcd-snapshot-node-prep.sh --apply    # does it, then takes one snapshot as a test
#
# What it installs (see platform-gitops/docs/etcd-backup.md):
#   /usr/local/bin/etcd-snapshot.sh              takes a snapshot of the LOCAL member, verifies it, prunes old ones,
#                                                then uploads it to the backup Garage (if the S3 env file exists)
#   /usr/local/bin/etcd-snapshot-upload.py       dependency-free SigV4 upload + size check (from this directory)
#   /etc/etcd-snapshot-s3.env                    NOT created here (secret): S3_ENDPOINT, S3_BUCKET, S3_KEY_ID, S3_SECRET
#   /etc/systemd/system/etcd-snapshot.service    runs the script
#   /etc/systemd/system/etcd-snapshot.timer      every 6 hours (00:15, 06:15, 12:15, 18:15 + up to 10 min delay)
#   /var/backups/etcd-snapshots/                 the snapshots (root only), newest 28 kept = 7 days
#
# It touches nothing in etcd: a snapshot is a read. It refuses to run if etcd is not active here, the admin client
# certificate for this node is missing, or etcd-snapshot-upload.py is not next to this script.
# Without /etc/etcd-snapshot-s3.env the snapshots stay local only (the service still succeeds).
set -euo pipefail

DIR=/var/backups/etcd-snapshots
KEEP=28
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

say()  { printf '%s\n' "$*"; }
doit() { say "+ $*"; [ "$APPLY" = 1 ] && eval "$@"; return 0; }
die()  { say "ABORT: $*"; exit 1; }

NODE=$(hostname -s)
say "host: $NODE   mode: $([ "$APPLY" = 1 ] && echo APPLY || echo dry-run)"
sudo -n true 2>/dev/null || die "passwordless sudo needed"

# ---- guards -----------------------------------------------------------------------------
systemctl is-active --quiet etcd || die "etcd is not active on this node (not a control plane?)"
for f in /usr/local/bin/etcdctl /usr/local/bin/etcdutl \
         /etc/ssl/etcd/ssl/ca.pem "/etc/ssl/etcd/ssl/admin-$NODE.pem" "/etc/ssl/etcd/ssl/admin-$NODE-key.pem"; do
  sudo -n test -e "$f" || die "missing $f"
done
UPLOADER="$(cd "$(dirname "$0")" && pwd)/etcd-snapshot-upload.py"
[ -f "$UPLOADER" ] || die "missing $UPLOADER (copy it next to this script)"
say "guards passed"

# ---- 1. the snapshot script ----------------------------------------------------------------
say; say "== 1. /usr/local/bin/etcd-snapshot.sh"
TMP=$(mktemp)
cat > "$TMP" <<EOF
#!/usr/bin/env bash
# Managed by platform-gitops/node-prep/etcd-snapshot-node-prep.sh. Snapshot the local etcd member.
set -euo pipefail
DIR=$DIR
KEEP=$KEEP
NODE=\$(hostname -s)
SSL=/etc/ssl/etcd/ssl
umask 077
mkdir -p "\$DIR"
NAME="etcd-\$NODE-\$(date -u +%Y%m%dT%H%M%SZ).db"
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=\$SSL/ca.pem \\
  --cert=\$SSL/admin-\$NODE.pem --key=\$SSL/admin-\$NODE-key.pem \\
  snapshot save "\$DIR/\$NAME.partial"
# a snapshot that cannot be read back is not a backup: fail (and keep the old ones) if it is bad
etcdutl snapshot status "\$DIR/\$NAME.partial" -w table
mv "\$DIR/\$NAME.partial" "\$DIR/\$NAME"
rm -f "\$DIR"/*.partial
# keep the newest \$KEEP
ls -1t "\$DIR"/etcd-*.db | tail -n +\$((KEEP + 1)) | xargs -r rm -v --
# off-node copy: a failed upload fails the unit (the local snapshot is already safe)
if [ -r /etc/etcd-snapshot-s3.env ]; then
  /usr/local/bin/etcd-snapshot-upload.py "\$DIR/\$NAME"
else
  echo "no /etc/etcd-snapshot-s3.env: snapshot kept on this node only"
fi
echo "ok \$DIR/\$NAME \$(stat -c %s "\$DIR/\$NAME") bytes"
EOF
say "+ install -m 0750 -o root -g root <generated> /usr/local/bin/etcd-snapshot.sh"
[ "$APPLY" = 1 ] && sudo install -m 0750 -o root -g root "$TMP" /usr/local/bin/etcd-snapshot.sh
rm -f "$TMP"

# ---- 1b. the uploader ------------------------------------------------------------------------
say; say "== 1b. /usr/local/bin/etcd-snapshot-upload.py"
doit "sudo install -m 0750 -o root -g root '$UPLOADER' /usr/local/bin/etcd-snapshot-upload.py"
sudo -n test -r /etc/etcd-snapshot-s3.env && say "S3 env file present: snapshots will be uploaded" \
  || say "NOTE: /etc/etcd-snapshot-s3.env does not exist: snapshots stay on this node until it is created (mode 600)"

# ---- 2. systemd units --------------------------------------------------------------------------
say; say "== 2. systemd service and timer"
if [ "$APPLY" = 1 ]; then
  sudo tee /etc/systemd/system/etcd-snapshot.service >/dev/null <<'EOF'
[Unit]
Description=etcd snapshot of the local member
After=etcd.service
Wants=etcd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/etcd-snapshot.sh
Nice=10
IOSchedulingClass=idle
EOF
  sudo tee /etc/systemd/system/etcd-snapshot.timer >/dev/null <<'EOF'
[Unit]
Description=etcd snapshot every 6 hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:15:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now etcd-snapshot.timer
else
  say "+ write etcd-snapshot.service (oneshot) and etcd-snapshot.timer (OnCalendar 00,06,12,18:15, Persistent)"
  say "+ systemctl daemon-reload; systemctl enable --now etcd-snapshot.timer"
fi

# ---- 3. test snapshot ------------------------------------------------------------------------------
say; say "== 3. one snapshot now"
doit "sudo systemctl start etcd-snapshot.service"

# ---- result ------------------------------------------------------------------------------------------
say; say "== result"
systemctl list-timers etcd-snapshot.timer --no-pager || true
sudo -n ls -lh "$DIR" 2>/dev/null || say "$DIR: not created yet (expected in dry-run)"
sudo -n journalctl -u etcd-snapshot.service -n 5 --no-pager 2>/dev/null || true
