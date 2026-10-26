#!/usr/bin/env bash
# Tenant guardrail check: what a tenant user can and cannot create (Pod Security baseline and Service types).
#
#   ./tests/tenant-guardrails.sh
#
# Also: tenants may use any hostname except the platform's own (tenant-baseline/ingress-platform-hosts-policy.yaml).
# Read-only: `kubectl create --dry-run=server` with impersonation, as a developer and as an owner of each tenant.
# KNOWN GAPS are reported, not failed: root user, any registry (accepted), :latest, and a NetworkPolicy that opens
# egress (see docs/tenant-guardrails.md).
set -uo pipefail
PASS=0; FAIL=0; GAP=0
ok()  { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
gap() { printf '  GAP   %s\n' "$*"; GAP=$((GAP+1)); }
SC='allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 1000, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}'
pod() { # pod <name> <extra pod spec> <container securityContext> [extra container fields]
  printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: gate-%s}\nspec:\n  %s\n  containers:\n    - name: c\n      image: %s\n      command: ["sleep","60"]\n      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}\n      securityContext: {%s}\n%s' \
    "$1" "$2" "${IMAGE:-busybox:1.36}" "$3" "$4"; }
ing() { printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata: {name: gate-%s}\nspec:\n  ingressClassName: traefik\n  %s\n' "$1" "$2"; }
irule() { printf 'rules: [{host: %s, http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: s, port: {number: 80}}}}]}}]' "$1"; }
svc() { printf 'apiVersion: v1\nkind: Service\nmetadata: {name: gate-%s}\nspec: {type: %s, selector: {a: b}, ports: [{port: 80}]}\n' "$1" "$2"; }
for t in zeedlogic jodywan; do
  case $t in zeedlogic) U1=dev@zeedlogic.com; G1=zeedlogic-developers; U2=owner@zeedlogic.com; G2=zeedlogic-owners;;
             jodywan)   U1=dev@jodywan.dev;   G1=jodywan-developers;   U2=owner@jodywan.dev;   G2=jodywan-owners;; esac
  for who in "$U1 $G1 $t-dev" "$U2 $G2 $t-prod"; do
    set -- $who; U=$1; G=$2; NS=$3
    A="--as=$U --as-group=oidc:$G --as-group=system:authenticated"
    echo "== $U in $NS"
    try() { kubectl create $A --dry-run=server -n "$NS" -f - 2>&1 | grep -q "created"; }   # 0 = allowed
    refuse() { if try; then bad "$U: $1 is ALLOWED"; else ok "$U: $1 refused"; fi; }
    allow()  { if try; then ok "$U: $1 allowed"; else bad "$U: $1 was refused"; fi; }
    refuse "privileged container" < <(pod priv "" "privileged: true" "")
    refuse "hostPath mount of the node" < <(pod hp 'volumes: [{name: h, hostPath: {path: /}}]' "" "      volumeMounts: [{name: h, mountPath: /host}]")
    refuse "hostNetwork" < <(pod hn "hostNetwork: true" "" "")
    refuse "hostPID" < <(pod hpid "hostPID: true" "" "")
    refuse "hostIPC" < <(pod hipc "hostIPC: true" "" "")
    refuse "SYS_ADMIN and NET_ADMIN capabilities" < <(pod caps "" 'capabilities: {add: [SYS_ADMIN, NET_ADMIN]}' "")
    refuse "hostPort" < <(pod hport "" "" "      ports: [{containerPort: 80, hostPort: 80}]")
    refuse "Service type LoadBalancer" < <(svc lb LoadBalancer)
    refuse "Service type NodePort" < <(svc np NodePort)
    refuse "Service type ExternalName" < <(svc en ExternalName)
    allow "a normal restricted pod" < <(pod ok "" "$SC" "")
    allow "a ClusterIP Service" < <(svc cip ClusterIP)
    allow "an Ingress for an ordinary hostname" < <(ing ok "$(irule app.example.org)")
    allow "an Ingress for a hostname of another domain" < <(ing ok2 "$(irule shop.zeedlogic.com)")
    refuse "an Ingress for the platform hostname grafana-k8s.jodywan.com" < <(ing p1 "$(irule grafana-k8s.jodywan.com)")
    refuse "an Ingress for the platform hostname argocd.jodywan.com" < <(ing p2 "$(irule argocd.jodywan.com)")
    refuse "an Ingress rule without a host" < <(ing nh 'rules: [{http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: s, port: {number: 80}}}}]}}]')
    refuse "an Ingress with a defaultBackend" < <(ing db 'defaultBackend: {service: {name: s, port: {number: 80}}}')
    if try < <(pod root "" "runAsUser: 0" ""); then gap "$U: a container may run as root (uid 0): baseline allows it"; else ok "$U: root user refused"; fi
    refuse "a pod pinned with nodeName" < <(pod node 'nodeName: control-plane-1' "$SC" "")
    refuse "a catch-all toleration" < <(pod tolall 'tolerations: [{operator: Exists}]' "$SC" "")
    refuse "a toleration of the control-plane taint" < <(pod tolcp 'tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]' "$SC" "")
    allow "an ordinary toleration" < <(pod tolok 'tolerations: [{key: example.com/spot, operator: Exists}]' "$SC" "")
    if try < <(IMAGE=evil.example.com/x:1 pod reg "" "$SC" ""); then gap "$U: images from any registry are allowed"; else ok "$U: unknown registry refused"; fi
    if try < <(IMAGE=nginx:latest pod lat "" "$SC" ""); then gap "$U: :latest tags are allowed"; else ok "$U: :latest refused"; fi
    if try < <(printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: gate-open}\nspec: {podSelector: {}, policyTypes: [Egress], egress: [{}]}\n'); then gap "$U: a NetworkPolicy that opens egress can be created (harmless: tenant-egress-guard and the platform ingress limits hold)"; else ok "$U: open-egress NetworkPolicy refused"; fi
  done
done
echo; echo "passed: $PASS   failed: $FAIL   known gaps: $GAP"
[ "$FAIL" -eq 0 ] && echo "TENANT GUARDRAILS CHECK: OK"
exit "$FAIL"
