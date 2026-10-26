# Rotate the GitLab token that Argo CD uses

- Runbook for the platform team.
- Argo CD reads this repo, and any other repo under `https://gitlab.jodywan.com/servers/pcls.jodywan.com/`, with one credential.
- The steps below rotate it without downtime.

## 1. What it is

| Item | Value |
|---|---|
| Secret | `gitlab-group-creds` in namespace `argocd` |
| Type | credential template (label `argocd.argoproj.io/secret-type=repo-creds`) |
| URL prefix | `https://gitlab.jodywan.com/servers/pcls.jodywan.com/` |
| Username | `gitops` (a deploy token has its own generated username instead) |
| Password | the GitLab token (scope `read_repository`) |
| Used by | every Application with a Git source (`platform-gitops`, the values sources of the Helm apps, the plain-manifest apps) |

Never put the token in Git, in a file or in chat. It lives only in this secret and in GitLab.

## 2. When to rotate

- Before the token expires (access tokens expire; deploy tokens can have no expiry).
- When the token was exposed (pasted in chat, a log or a ticket).
- When the person who created it leaves, or on your regular schedule.

If it expires without rotation: Applications keep running, but nothing syncs and Argo CD shows
`ComparisonError ... authentication required`.

## 3. Steps (no downtime if done in this order)

1. **Create the new token in GitLab.** Group `servers/pcls.jodywan.com` (or the narrowest group that covers
   the repos), Settings > Repository > Deploy tokens, or Settings > Access tokens.
   - Scope: `read_repository` only. For an access token choose the **Reporter** role.
   - Note the username (deploy token) and the expiry date.
   - Do **not** revoke the old token yet.

2. **Update the secret.** Run on a machine with cluster-admin `kubectl`:
   ```bash
   read -r -s -p "New token: " T; echo
   printf '{"stringData":{"password":"%s"}}' "$T" | \
     kubectl -n argocd patch secret gitlab-group-creds --type merge --patch-file /dev/stdin
   unset T
   ```
   If the new token is a deploy token, also change the username. Put it in the same JSON:
   `{"stringData":{"username":"<deploy-token-username>","password":"<token>"}}` (use the same `read -s` pattern
   for the password; the username is not secret).

3. **Verify the secret is still a credential template:**
   ```bash
   kubectl -n argocd get secret gitlab-group-creds --show-labels
   ```
   Expect `argocd.argoproj.io/secret-type=repo-creds` in LABELS. If it is missing, re-add it:
   `kubectl -n argocd label secret gitlab-group-creds argocd.argoproj.io/secret-type=repo-creds --overwrite`

4. **Verify Argo CD can read the repo:**
   ```bash
   kubectl -n argocd annotate application platform-gitops argocd.argoproj.io/refresh=hard --overwrite
   sleep 15
   kubectl -n argocd get application platform-gitops storage-longhorn
   ```
   Expect `Synced` and `Healthy`. Check there is no `ComparisonError`:
   ```bash
   kubectl -n argocd get application platform-gitops -o jsonpath='{.status.conditions[*].message}'
   ```

5. **Revoke the old token in GitLab**, only after step 4 is clean.

6. **Record it** in the table below (dates only, never the token).

## 4. If it fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `authentication required` after the update | wrong value, wrong scope, expired, or wrong username (deploy token) | the old token still works until revoked: put the old value back with step 2, then fix the new one |
| `Unknown` sync status that does not clear | Argo CD cached the earlier failure | `kubectl -n argocd rollout restart deployment argocd-repo-server`, then refresh again |
| no credential used at all | the `repo-creds` label is missing | step 3 |
| works for this repo, fails for another | token's group or repo access does not cover it | create the token on a parent group, or add a credential for that repo |

Test a token outside Argo CD (it prints the commit hash of `main` if it works):
```bash
read -r -s -p "token: " T; echo
git -c credential.helper= -c "http.extraHeader=Authorization: Basic $(printf 'gitops:%s' "$T" | base64 -w0)" \
  ls-remote --heads https://gitlab.jodywan.com/servers/pcls.jodywan.com/k8s-1.jodywan.com/platform-gitops.git
unset T
```

## 5. Rotation log

| Date | Token | Expires | Done by | Reason |
|---|---|---|---|---|
| 2026-10-09 | personal access token for user `gitops`, pasted in chat during setup | unknown | | **exposed: rotate** |
| 2026-10-10 | new token written into `gitlab-group-creds` by the user (typed in their own terminal, never in chat) | see GitLab | adminjody | rotation after the exposure. Checked afterwards: the Secret kept the `repo-creds` label and the keys `url`, `username`, `password`; all Applications Synced and Healthy with no conditions; the old token was revoked. **Complete** |
| | | | | |

## 6. Related

- Tenant repos should get their own read-only credentials, scoped to one project: see
  `capsule-argocd-integration.md` and `argocd-gitops.md` section 8.
- Later idea: alert before expiry (a calendar entry now; an alert on the Argo CD repo-server errors, or a
  scheduled check with the test above, later).
