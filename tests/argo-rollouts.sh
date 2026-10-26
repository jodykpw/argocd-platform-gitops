#!/usr/bin/env bash
# Argo Rollouts pass check: controller ready, CRDs, the Gateway API plugin loaded; a canary Rollout shifts the HTTPRoute
# weights step by step through the Traefik Gateway and ends on the new version; an update whose analysis fails is aborted
# and the route goes back to the stable version; tenants can create a plain Rollout and nothing more (no trafficRouting,
# no analysis, no AnalysisTemplate), viewers read; Prometheus holds the controller's metrics.
#
#   ./tests/argo-rollouts.sh
#   NS=argo-rollouts ./tests/argo-rollouts.sh
#
# Creates and removes the namespace `rollouts-test` (labelled gateway-access=platform). Takes about 3 to 5 minutes.
set -uo pipefail
NS="${NS:-argo-rollouts}"
T=rollouts-test
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null; kubectl delete ns "$T" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

step "1. controller, CRDs and plugin"
R=$(kubectl -n "$NS" get deploy argo-rollouts -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment argo-rollouts ready" || bad "deployment argo-rollouts not ready"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys
n=0
for p in json.load(sys.stdin)["items"]:
    for c in p["status"].get("containerStatuses",[]): n+=c["restartCount"]
print(n)')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
for c in rollouts analysistemplates analysisruns experiments clusteranalysistemplates; do
  kubectl get crd "$c.argoproj.io" >/dev/null 2>&1 && ok "CRD $c installed" || bad "CRD $c missing"
done
kubectl -n "$NS" get cm argo-rollouts-config -o jsonpath='{.data.trafficRouterPlugins}' | grep -q 'argoproj-labs/gatewayAPI' && ok "the Gateway API plugin is configured" || bad "plugin not configured"
kubectl -n "$NS" logs deploy/argo-rollouts --tail=300 2>/dev/null | grep -qi 'argoproj-labs/gatewayAPI' && ok "the controller loaded the plugin (log)" || bad "no plugin line in the controller log"
L=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[ "$L" = baseline ] && ok "namespace $NS enforces Pod Security baseline" || bad "namespace $NS Pod Security is '$L'"
AGG=$(kubectl get clusterrole -l 'rbac.authorization.k8s.io/aggregate-to-edit=true' -o name | grep -c -i -E 'rollouts.*(analysis|experiment)|argo-rollouts')
[ "$AGG" -eq 0 ] && ok "the chart's aggregated roles are off (no analysis rights flow into edit)" || bad "chart aggregates roles into edit ($AGG)"

step "2. canary through the Gateway"
kubectl create ns "$T" >/dev/null 2>&1
kubectl label ns "$T" gateway-access=platform --overwrite >/dev/null
mkapp() { # mkapp <image-arg-version>
  cat <<YAML
apiVersion: v1
kind: Service
metadata: {name: stable}
spec: {selector: {app: demo}, ports: [{port: 80, targetPort: 8080}]}
---
apiVersion: v1
kind: Service
metadata: {name: canary}
spec: {selector: {app: demo}, ports: [{port: 80, targetPort: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: demo}
spec:
  parentRefs: [{name: traefik-gateway, namespace: traefik, sectionName: web}]
  hostnames: [rollouts-test.jodywan.com]
  rules:
    - backendRefs:
        - {name: stable, port: 80, weight: 100}
        - {name: canary, port: 80, weight: 0}
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: demo}
spec:
  replicas: 2
  revisionHistoryLimit: 1
  selector: {matchLabels: {app: demo}}
  template:
    metadata: {labels: {app: demo}}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh","-c","mkdir -p /tmp/www && echo \$VERSION > /tmp/www/index.html && exec httpd -f -p 8080 -h /tmp/www"]
          env: [{name: VERSION, value: "$1"}]
          ports: [{containerPort: 8080}]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
  strategy:
    canary:
      stableService: stable
      canaryService: canary
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: demo
            namespace: $T
      steps:
        - setWeight: 50
        - pause: {duration: 25s}
YAML
}
mkapp v1 | kubectl -n "$T" apply -f - >/dev/null
for i in $(seq 1 40); do P=$(kubectl -n "$T" get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null); [ "$P" = Healthy ] && break; sleep 3; done
[ "$P" = Healthy ] && ok "first revision is Healthy" || bad "Rollout phase is '$P' (events: $(kubectl -n "$T" describe rollout demo | tail -3 | tr '\n' ' '))"
ACC=$(kubectl -n "$T" get httproute demo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$ACC" = True ] && ok "HTTPRoute accepted by the Gateway" || bad "HTTPRoute not accepted ($ACC)"
body() { curl -s -m 5 --resolve rollouts-test.jodywan.com:80:10.1.5.170 http://rollouts-test.jodywan.com/ 2>/dev/null | tr -d '\n'; }
B=""; for i in $(seq 1 10); do B=$(body); [ "$B" = v1 ] && break; sleep 2; done
[ "$B" = v1 ] && ok "Traefik answers v1 through the route" || bad "route answered '$B'"
mkapp v2 | kubectl -n "$T" apply -f - >/dev/null
SEEN50=0
for i in $(seq 1 40); do
  W=$(kubectl -n "$T" get httproute demo -o jsonpath='{.spec.rules[0].backendRefs[*].weight}' 2>/dev/null)
  [ "$W" = "50 50" ] && { SEEN50=1; break; }; sleep 2
done
[ "$SEEN50" = 1 ] && ok "the plugin moved the HTTPRoute weights to 50 / 50 during the canary step" || bad "weights never reached 50/50 (last: $W)"
for i in $(seq 1 60); do
  P=$(kubectl -n "$T" get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null)
  W=$(kubectl -n "$T" get httproute demo -o jsonpath='{.spec.rules[0].backendRefs[*].weight}' 2>/dev/null)
  [ "$P" = Healthy ] && [ "$W" = "100 0" ] && break; sleep 3
done
[ "$P" = Healthy ] && ok "the new revision became Healthy" || bad "Rollout phase after the update is '$P'"
[ "$W" = "100 0" ] && ok "weights are back to 100 / 0 (the new version is the stable one)" || bad "weights after promotion: $W"
B=""; for i in $(seq 1 10); do B=$(body); [ "$B" = v2 ] && break; sleep 2; done
[ "$B" = v2 ] && ok "Traefik answers v2 after the promotion" || bad "route answered '$B' after promotion"

step "3. a failing analysis aborts the update"
cat <<YAML | kubectl -n "$T" apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: {name: always-fails}
spec:
  metrics:
    - name: zero
      interval: 5s
      count: 1
      failureLimit: 0
      successCondition: "result[0] > 0"
      provider:
        prometheus:
          address: http://thanos-query.monitoring.svc.cluster.local:10902
          query: vector(0)
YAML
mkapp v3 | python3 -I -c '
import sys
s=sys.stdin.read()
s=s.replace("        - pause: {duration: 25s}\n","        - analysis: {templates: [{templateName: always-fails}]}\n        - pause: {duration: 25s}\n")
print(s,end="")' | kubectl -n "$T" apply -f - >/dev/null
for i in $(seq 1 60); do
  P=$(kubectl -n "$T" get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$P" = Degraded ] && break; sleep 3
done
[ "$P" = Degraded ] && ok "the Rollout was aborted (phase Degraded) after the failed analysis" || bad "phase after a failing analysis is '$P'"
W=$(kubectl -n "$T" get httproute demo -o jsonpath='{.spec.rules[0].backendRefs[*].weight}' 2>/dev/null)
[ "$W" = "100 0" ] && ok "the route went back to the stable version (100 / 0)" || bad "weights after the abort: $W"
B=$(body); [ "$B" = v2 ] && ok "Traefik still answers v2 (the failed v3 never took traffic)" || bad "route answered '$B' after the abort"

step "4. tenants"
OWN=(--as=owner@zeedlogic.com --as-group=oidc:zeedlogic-owners --as-group=system:authenticated)
DEV=(--as=dev@zeedlogic.com --as-group=oidc:zeedlogic-developers --as-group=system:authenticated)
ro() { # ro <extra strategy yaml>
  cat <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: t}
spec:
  replicas: 1
  selector: {matchLabels: {app: t}}
  template:
    metadata: {labels: {app: t}}
    spec:
      containers: [{name: c, image: busybox:1.36, command: ["sleep","3600"], resources: {limits: {memory: 32Mi}}}]
  strategy:
$1
YAML
}
dry() { printf '%s\n' "$1" | kubectl create --dry-run=server -n zeedlogic-dev -f - "${DEV[@]}" 2>&1; }
R=$(dry "$(ro '    canary: {steps: [{setWeight: 50}, {pause: {duration: 5s}}]}')")
case "$R" in *"(server dry run)"*) ok "developer can create a plain canary Rollout in zeedlogic-dev";; *) bad "plain Rollout refused: $R";; esac
R=$(dry "$(ro '    blueGreen: {activeService: a, previewService: p}')")
case "$R" in *"(server dry run)"*) ok "developer can create a blue-green Rollout";; *) bad "blue-green Rollout refused: $R";; esac
R=$(dry "$(ro $'    canary:\n      trafficRouting: {plugins: {argoproj-labs/gatewayAPI: {httpRoute: grafana, namespace: grafana}}}\n      steps: [{setWeight: 50}]')")
case "$R" in *"must not use trafficRouting"*) ok "trafficRouting that names a platform HTTPRoute is refused";; *) bad "trafficRouting not refused: $R";; esac
R=$(dry "$(ro $'    canary:\n      steps: [{analysis: {templates: [{templateName: x}]}}]')")
case "$R" in *"must not use analysis"*) ok "a step with analysis is refused";; *) bad "analysis step not refused: $R";; esac
R=$(dry "$(ro $'    blueGreen:\n      activeService: a\n      prePromotionAnalysis: {templates: [{templateName: x}]}')")
case "$R" in *"must not use analysis"*) ok "blue-green pre-promotion analysis is refused";; *) bad "blue-green analysis not refused: $R";; esac
R=$(printf '%s\n' "$(ro '    canary: {}')" | kubectl create --dry-run=server -n jodywan-dev -f - "${DEV[@]}" 2>&1)
case "$R" in *orbidden*) ok "developer cannot create a Rollout in the other tenant's namespace";; *) bad "created in jodywan-dev: $R";; esac
for k in analysistemplates experiments analysisruns; do
  C=$(kubectl auth can-i create "$k.argoproj.io" -n zeedlogic-dev "${OWN[@]}" 2>/dev/null)
  [ "$C" = no ] && ok "even the tenant owner cannot create $k" || bad "owner can create $k"
done
C=$(kubectl auth can-i create clusteranalysistemplates.argoproj.io "${OWN[@]}" 2>/dev/null | tail -1)
[ "$C" = no ] && ok "even the tenant owner cannot create clusteranalysistemplates" || bad "owner can create clusteranalysistemplates"
C=$(kubectl auth can-i create rollouts.argoproj.io -n zeedlogic-dev --as=viewer@zeedlogic.com --as-group=oidc:zeedlogic-viewers --as-group=system:authenticated 2>/dev/null)
[ "$C" = no ] && ok "a viewer cannot create Rollouts" || bad "viewer can create Rollouts"
C=$(kubectl auth can-i list rollouts.argoproj.io -n zeedlogic-dev --as=viewer@zeedlogic.com --as-group=oidc:zeedlogic-viewers --as-group=system:authenticated 2>/dev/null)
[ "$C" = yes ] && ok "a viewer can read Rollouts" || bad "viewer cannot read Rollouts"

step "5. metrics"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19096:9090 >/dev/null 2>&1 & PF=$!
sleep 3
N=0
for i in $(seq 1 12); do
  N=$(curl -s -m 15 -G "http://127.0.0.1:19096/api/v1/query" --data-urlencode 'query=count({__name__=~"rollout_.*|controller_clientset_k8s_request_total"})' | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)
  [ "${N:-0}" != 0 ] && break; sleep 10
done
[ "${N:-0}" != 0 ] && ok "Prometheus has the controller's metrics ($N series)" || bad "no rollout_* series (ServiceMonitor, scrape interval)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ARGO ROLLOUTS CHECK: OK"
exit "$FAIL"
