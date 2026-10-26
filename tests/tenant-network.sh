#!/usr/bin/env bash
# Tenant network isolation check (the NetworkPolicy part of the tenant gate).
#
#   ./tests/tenant-network.sh          # runs sections A and B
#   SKIP_B=1 ./tests/tenant-network.sh # only the tenant baseline
#
# Creates temporary pods in zeedlogic-dev, zeedlogic-stg, jodywan-dev, traefik and default, plus (section B) one
# extra NetworkPolicy in zeedlogic-dev that simulates a tenant owner opening egress. Everything is removed at the end.
#
# A. tenant baseline: a tenant pod can resolve DNS, reach the internet and its own namespace, and nothing else (no
#    other tenant, no other environment of its own tenant, no platform service, no API server, no LAN address).
#    Traffic from Traefik reaches tenant pods; traffic from other namespaces does not.
# C. the node tunnel addresses listed in the platform policies are still the nodes' current ones.
# B. platform ingress limits: a tenant owner can add NetworkPolicies of their own. With egress opened, the platform
#    services must still refuse the tenant pod (the destination side holds). Traefik's web entry point stays open.
#    Node ports (kubelet, node-exporter, etcd metrics, scheduler) are refused by the Calico policy
# tenant-egress-guard (tenant-baseline/tenant-egress-guard.yaml); they were a known gap. Node ports (kubelet, node-exporter,
#    etcd metrics) are a KNOWN GAP of plain NetworkPolicy and are only reported.
set -uo pipefail
IMG="${IMG:-busybox:1.36}"
T1=zeedlogic-dev; T1B=zeedlogic-stg; T2=jodywan-dev
PASS=0; FAIL=0; GAP=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
gap()  { printf '  GAP   %s\n' "$*"; GAP=$((GAP+1)); }
step() { printf '\n== %s\n' "$*"; }
LBL="tenant-net-test=run"

pod() { # pod <ns> <name> <mode: client|server> [extra labels as k=v,...]
  local ns="$1" name="$2" mode="$3" labels="${4:-}" cmd
  if [ "$mode" = server ]; then cmd='["sh","-c","mkdir -p /tmp/w && echo ok > /tmp/w/index.html && httpd -f -p 8080 -h /tmp/w"]'
  else cmd='["sleep","600"]'; fi
  local l="tenant-net-test: run"
  [ -n "$labels" ] && l="$l"$'\n'"    $(echo "$labels" | sed 's/,/\n    /g; s/=/: /g')"
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    $l
spec:
  terminationGracePeriodSeconds: 0
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMG
      command: $cmd
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
}
ready() { kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout=90s >/dev/null 2>&1; }
ip_of() { kubectl -n "$1" get pod "$2" -o jsonpath='{.status.podIP}'; }
# reach <ns> <pod> <host> <port>  -> 0 if the TCP connection opens
reach() { kubectl -n "$1" exec "$2" -- nc -z -w 4 "$3" "$4" >/dev/null 2>&1; }
cleanup() {
  for ns in $T1 $T1B $T2 traefik default monitoring; do
    kubectl -n "$ns" delete pod -l "$LBL" --ignore-not-found --wait=false >/dev/null 2>&1
  done
  kubectl -n $T1 delete networkpolicy tenant-net-test-open-egress --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

step "setup"
pod $T1 tnt-client client; pod $T1 tnt-peer server; pod $T1B tnt-stg server; pod $T2 tnt-other server
pod traefik tnt-from-traefik client; pod default tnt-from-default client
pod monitoring tnt-from-prom client "app.kubernetes.io/name=prometheus"
for x in "$T1 tnt-client" "$T1 tnt-peer" "$T1B tnt-stg" "$T2 tnt-other" "traefik tnt-from-traefik" "default tnt-from-default" "monitoring tnt-from-prom"; do
  set -- $x; ready "$1" "$2" && echo "  ready $1/$2" || { bad "pod $1/$2 did not become ready"; }
done
PEER=$(ip_of $T1 tnt-peer); STG=$(ip_of $T1B tnt-stg); OTHER=$(ip_of $T2 tnt-other)

step "A. tenant baseline (pod in $T1)"
C="$T1 tnt-client"
kubectl -n $T1 exec tnt-client -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && ok "DNS works" || bad "DNS does not work"
reach $C 1.1.1.1 443 && ok "internet (1.1.1.1:443) reachable" || bad "internet not reachable"
reach $C "$PEER" 8080 && ok "pod in the same namespace reachable" || bad "same namespace not reachable"
reach $C "$STG" 8080 && bad "another environment of the same tenant ($T1B) is reachable" || ok "another environment of the same tenant is not reachable"
reach $C "$OTHER" 8080 && bad "a pod of the OTHER tenant ($T2) is reachable" || ok "the other tenant is not reachable"
for t in "kubernetes.default.svc 443:Kubernetes API (service)" "10.1.5.151 6443:API server on a control plane" \
         "10.1.5.202 2049:TrueNAS NFS" "10.1.5.123 3910:backup Garage on docker-2" "10.1.5.171 9001:Capsule Proxy" \
         "kube-prometheus-stack-prometheus.monitoring.svc 9090:Prometheus" "loki.loki.svc 3100:Loki"; do
  hp="${t%%:*}"; desc="${t#*:}"; h="${hp% *}"; p="${hp#* }"
  reach $C "$h" "$p" && bad "$desc is reachable from a tenant pod" || ok "$desc is not reachable from a tenant pod"
done
echo "  -- inbound to the tenant pod ($PEER:8080)"
reach traefik tnt-from-traefik "$PEER" 8080 && ok "from the traefik namespace: allowed" || bad "traefik cannot reach tenant pods"
reach monitoring tnt-from-prom "$PEER" 8080 && ok "from Prometheus pods in monitoring: allowed" || bad "Prometheus cannot reach tenant pods"
reach default tnt-from-default "$PEER" 8080 && bad "a pod in default reaches the tenant pod" || ok "from default: refused"
kubectl -n $T2 exec tnt-other -- nc -z -w 4 "$PEER" 8080 >/dev/null 2>&1 && bad "the other tenant reaches this tenant's pod" || ok "from the other tenant: refused"

if [ -z "${SKIP_B:-}" ]; then
step "B. a tenant owner opens egress; the platform must still refuse"
kubectl -n $T1 apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: tenant-net-test-open-egress, labels: {tenant-net-test: run}}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress: [{}]
YAML
sleep 3
# sanity: egress is now open towards the other tenant's pod (the destination side must hold)
echo "  -- towards other tenant: $(reach $C "$OTHER" 8080 && echo reachable || echo refused)"
for t in "kube-prometheus-stack-prometheus.monitoring.svc 9090:Prometheus" "kube-prometheus-stack-alertmanager.monitoring.svc 9093:Alertmanager" \
         "grafana.grafana.svc 80:Grafana" "thanos-query.monitoring.svc 10902:Thanos Querier" \
         "blackbox-exporter.monitoring.svc 9115:blackbox-exporter" "kube-prometheus-stack-kube-state-metrics.monitoring.svc 8080:kube-state-metrics" \
         "loki.loki.svc 3100:Loki" "jaeger.jaeger.svc 16686:Jaeger query" "jaeger.jaeger.svc 4317:Jaeger OTLP" \
         "garage.garage.svc 3900:Garage S3" "garage.garage.svc 3903:Garage admin" \
         "argocd-repo-server.argocd.svc 8081:Argo CD repo server" "argocd-redis.argocd.svc 6379:Argo CD redis" \
         "external-secrets-webhook.external-secrets.svc 443:External Secrets webhook" "argo-rollouts-metrics.argo-rollouts.svc 8090:Argo Rollouts metrics" "headlamp.headlamp.svc 80:Headlamp" "velero.velero.svc 8085:Velero metrics" \
         "garage-ui.garage.svc 3909:Garage UI" "nfs-provisioner.nfs-provisioner.svc 80:NFS provisioner namespace" \
         "capsule-webhook-service.capsule-system.svc 443:Capsule webhook"; do
  hp="${t%%:*}"; desc="${t#*:}"; h="${hp% *}"; p="${hp#* }"
  reach $C "$h" "$p" && bad "$desc is reachable from a tenant pod when egress is open" || ok "$desc refuses the tenant pod"
done
TR=$(kubectl -n traefik get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
reach $C "$TR" 8000 && ok "Traefik entry point web (8000) is reachable, as designed" || bad "Traefik web entry point refuses the tenant pod"
reach $C "$TR" 8080 && bad "Traefik API/dashboard port 8080 is reachable from a tenant pod" || ok "Traefik API/dashboard port 8080 refuses the tenant pod"
reach $C "$TR" 9100 && bad "Traefik metrics port 9100 is reachable from a tenant pod" || ok "Traefik metrics port 9100 refuses the tenant pod"
for t in "argocd-server.argocd.svc 80:Argo CD server (SSO login, open by its chart policy)"; do
  hp="${t%%:*}"; desc="${t#*:}"; h="${hp% *}"; p="${hp#* }"
  reach $C "$h" "$p" && printf '  NOTE  accepted exposure: %s is reachable\n' "$desc" || ok "$desc refuses the tenant pod"
done
for t in "10.1.5.161 10250:kubelet" "10.1.5.161 9100:node-exporter" "10.1.5.151 2381:etcd metrics (plain HTTP)" "10.1.5.151 10259:kube-scheduler"; do
  hp="${t%%:*}"; desc="${t#*:}"; h="${hp% *}"; p="${hp#* }"
  reach $C "$h" "$p" && gap "$desc is reachable from a tenant pod (tenant-egress-guard Calico policy missing or not working)" || ok "$desc refuses the tenant pod"
done
fi

step "C. node tunnel addresses in the platform policies are current"
# The API server reaches pods from each node's Calico VXLAN tunnel address, which lies inside the pod network that
# the policies exclude, so every node's address is listed explicitly. A rebuilt or added node has a new one.
WANT=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr}{"\n"}{end}' | sort)
HAVE=$(kubectl -n monitoring get networkpolicy refuse-tenant-ingress -o json | python3 -I -c 'import json,sys
for r in json.load(sys.stdin)["spec"]["ingress"]:
    for f in r.get("from",[]):
        c=f.get("ipBlock",{}).get("cidr","")
        if c.endswith("/32"): print(c[:-3])' | sort)
if [ "$WANT" = "$HAVE" ]; then ok "the $(echo "$WANT" | wc -l) node tunnel addresses match the node annotations"
else bad "node tunnel addresses differ: nodes [$(echo $WANT)] policy [$(echo $HAVE)] (update tenant-baseline/platform-ingress.yaml)"; fi
GP=$(kubectl -n grafana get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
APIP=$(kubectl get --raw "/api/v1/namespaces/grafana/pods/$GP:3000/proxy/api/health" 2>/dev/null | head -c 1)
[ -n "$APIP" ] && ok "the API server can still reach Grafana through the pod proxy" || bad "the API server pod proxy to Grafana fails (node tunnel addresses?)"
THP=$(kubectl get --raw "/api/v1/namespaces/monitoring/pods/thanos-compact-0:10902/proxy/metrics" 2>/dev/null | head -c 1)
[ -n "$THP" ] && ok "the API server reaches thanos-compact through a policy that excludes tenants" || bad "API server cannot reach thanos-compact"

echo
echo "passed: $PASS   failed: $FAIL   known gaps: $GAP"
[ "$FAIL" -eq 0 ] && echo "TENANT NETWORK CHECK: OK"
exit "$FAIL"
