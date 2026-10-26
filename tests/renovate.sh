#!/usr/bin/env bash
# Renovate pass check.
#
#   ./tests/renovate.sh              # config checks and cluster object checks
#   DRYRUN=1 ./tests/renovate.sh     # also a real dry run in the cluster (needs the Secret renovate-env)
#
# 1. renovate.json is valid JSON and its regex managers find every pinned chart and image in the repo
# 2. the CronJob exists, is suspended until the Secret exists (and is not suspended afterwards)
# 3. (DRYRUN=1) a one-off Job with RENOVATE_DRY_RUN=full runs to completion: it reads the project, looks up every
#    registry and reports the updates it would propose, without creating branches or merge requests.
set -uo pipefail
NS="${NS:-renovate}"
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  NOTE  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

step "1. renovate.json"
python3 -I - <<'PY' > /tmp/renovate-check.$$ 2>&1
import json,re,glob,os,sys
try: cfg=json.load(open("renovate.json"))
except Exception as e: print("INVALID",e); sys.exit()
print("VALID", len(cfg.get("customManagers",[])), "managers,", len(cfg.get("packageRules",[])), "rules")
found=set()
for m in cfg["customManagers"]:
    pats=[re.compile(p.replace("(?<","(?P<")) for p in m["matchStrings"]]
    for fp in m["managerFilePatterns"]:
        rx=re.compile(fp.strip("/").replace("\\/","/"))
        for root,_,files in os.walk("."):
            if "/.git" in root: continue
            for fn in files:
                f=os.path.join(root,fn)[2:]
                if not rx.search(f): continue
                try: txt=open(f).read()
                except Exception: continue
                for p in pats:
                    for g in p.finditer(txt):
                        d=g.groupdict(); name=d.get("depName") or m.get("depNameTemplate") or d.get("packageName")
                        found.add((m["datasourceTemplate"],name))
# every chart pin in the appsets must be found
want=set()
for f in glob.glob("appsets/*.yaml"):
    t=open(f).read()
    for g in re.finditer(r"chart:\s*(\S+)\s*\n(?:\s*#[^\n]*\n)*\s*targetRevision:\s*\"?([0-9][^\"\s#]*)",t): want.add(("helm",g.group(1)))
print("FOUND", len(found))
print("MISSING", sorted(want-found))
print("HAS", sorted(n for d,n in found if n in ("jaeger","garage","velero","kube-prometheus-stack")))
PY
head -1 /tmp/renovate-check.$$ | grep -q '^VALID' && ok "renovate.json is valid JSON ($(head -1 /tmp/renovate-check.$$ | cut -d' ' -f2-))" || bad "renovate.json: $(head -1 /tmp/renovate-check.$$)"
N=$(grep '^FOUND' /tmp/renovate-check.$$ | awk '{print $2}')
[ "${N:-0}" -ge 19 ] && ok "the managers track $N distinct dependencies (charts, git tags, images)" || bad "only ${N:-0} dependencies found (expected 19 or more)"
M=$(grep '^MISSING' /tmp/renovate-check.$$ | cut -d' ' -f2-)
[ "$M" = "[]" ] && ok "every chart pin in appsets/ is found" || bad "chart pins not found by any manager: $M"
grep '^HAS' /tmp/renovate-check.$$ | grep -q "jaeger" && ok "Jaeger is tracked, so the rule that keeps it below 4.14 applies" || bad "jaeger not found: its pin rule would not apply"
rm -f /tmp/renovate-check.$$

step "2. cluster objects"
kubectl -n "$NS" get cronjob renovate >/dev/null 2>&1 && ok "CronJob renovate exists in $NS" || bad "CronJob renovate missing"
SUS=$(kubectl -n "$NS" get cronjob renovate -o jsonpath='{.spec.suspend}' 2>/dev/null)
HAS=$(kubectl -n "$NS" get secret renovate-env -o jsonpath='{.data.RENOVATE_TOKEN}' 2>/dev/null | wc -c)
if [ "${HAS:-0}" -gt 0 ]; then
  ok "Secret renovate-env has a RENOVATE_TOKEN"
  [ "$SUS" = false ] && ok "CronJob is active" || note "token exists but the CronJob is still suspended: set cronjob.suspend to false in base/renovate/values.yaml"
else
  [ "$SUS" = true ] && ok "no token yet and the CronJob is suspended (nothing fails at night)" || bad "no token but the CronJob is not suspended: it will fail every night"
fi

if [ -n "${DRYRUN:-}" ]; then
  step "3. dry run in the cluster"
  if [ "${HAS:-0}" -le 0 ]; then bad "DRYRUN needs the Secret renovate-env with RENOVATE_TOKEN"
  else
    J="renovate-dryrun-$(date +%s)"
    kubectl -n "$NS" create job "$J" --from=cronjob/renovate >/dev/null 2>&1
    kubectl -n "$NS" patch job "$J" --type json -p '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"RENOVATE_DRY_RUN","value":"full"}}]' >/dev/null 2>&1 || true
    for i in $(seq 1 90); do
      S=$(kubectl -n "$NS" get job "$J" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null)
      case "$S" in 1/*|*/1) break;; esac; sleep 5
    done
    LOG=$(kubectl -n "$NS" logs "job/$J" 2>/dev/null)
    [ "${S%%/*}" = 1 ] && ok "dry run finished" || bad "dry run did not succeed ($S)"
    echo "$LOG" | grep -i -E "WARN|ERROR" | head -5 | sed 's/^/        /'
    echo "$LOG" | grep -E "Would|branch|Dependency Dashboard" | head -10 | sed 's/^/        /'
    kubectl -n "$NS" delete job "$J" --ignore-not-found >/dev/null 2>&1
  fi
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "RENOVATE CHECK: OK"
exit "$FAIL"
