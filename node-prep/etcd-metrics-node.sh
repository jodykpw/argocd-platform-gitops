#!/usr/bin/env bash
# Add the etcd metrics listener on THIS control plane and restart etcd. Run on one node at a time.
set -euo pipefail
IP=$(ip -4 -o addr show | awk '{print $4}' | grep -E '^10\.1\.5\.15[1-3]/' | cut -d/ -f1)
NODE=$(hostname -s)
URLS="http://$IP:2381,http://127.0.0.1:2381"
sudo cp -a /etc/etcd.env /etc/etcd.env.bak-2026-10-10
if sudo grep -q '^ETCD_LISTEN_METRICS_URLS=' /etc/etcd.env; then echo "already set"; else
  echo "ETCD_LISTEN_METRICS_URLS=$URLS" | sudo tee -a /etc/etcd.env >/dev/null; fi
sudo systemctl restart etcd
for i in $(seq 1 30); do
  if sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem \
       --cert=/etc/ssl/etcd/ssl/admin-$NODE.pem --key=/etc/ssl/etcd/ssl/admin-$NODE-key.pem endpoint health >/dev/null 2>&1; then
    echo "$NODE: etcd healthy after restart (${i}x2s)"; break; fi; sleep 2; done
echo "$NODE metrics: $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$IP:2381/metrics) size $(curl -s -m 5 http://$IP:2381/metrics | wc -c)"
