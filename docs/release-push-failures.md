# Release push failures ("could not read Username")

Every service's release step ends by pushing the new image tag to `apps/<app>/values.yaml` in this
repository (`scripts/helm/update-values.sh`). On 2026-10-20 several services failed that push with
`warning: redirecting to ...` followed by `fatal: could not read Username`, reported as "check token
permissions". This page records what was ruled out, so the next occurrence starts from facts.

## What was checked

- **Timeline.** treasury-api: last good release 2026-10-19 07:29 UTC, first failure 2026-10-20 13:23
  UTC. The only commit in that window in treasury-api was the fix being released. In this repository
  nothing under `scripts/` or `.github/actions/` changed between those times, and treasury-api's
  `deploy.yml` and `build.sh` were last touched in March.
- **The tokens are valid.** A read-only probe workflow tested the `GH_PAT` and `PROPAGATE_PAT` held
  here, and the `GH_PAT` held by treasury-api: each answered HTTP 200 with admin and push rights, a
  classic token (`ghp_`, 40 characters, no expiry header, no stray whitespace), and a push dry run to
  `main` succeeded. So the earlier "dead token" reading and the re-sync advice do not explain it; the
  re-sync copies a token that works.
- **The exact sequence replays cleanly.** On a fresh runner (git 2.55.0, image 20261018.339) the same
  steps as the real release (clone with the `x-access-token` form in `build.sh`, swap the remote to
  `https://TOKEN@...`, fetch, checkout, commit, push) succeeded. The `redirecting to ...git/` warning
  appears on every step there, including the successful ones, so it is noise.
- **Not the runner image alone.** The failing treasury-api and subscriptions-api runs used the newer
  runner image, but erp-api and pos-ui passed on the same image.
- **Intermittent.** auth-api failed at 12:58 and passed at 14:06; erp-api and projects-api passed after
  failing; a failure came 3 seconds after another service's successful push. Re-running with a fresh
  `GH_PAT` did not make failures stop, which fits a cause outside the secret.

## What changed in the script

A push that fails without a conflict (`could not read Username`, a 401/403/429/5xx, a dropped
connection) was fatal on the first attempt. It is now retried up to 3 times with backoff, and each
failure logs the HTTP status GitHub gives the receive-pack discovery request at that moment (status
code only, never the token). A persistent failure therefore names its own cause (401 means the
token is rejected, 403 or 429 means throttling, 000 means the network). Both copies of the loop in
`update-values.sh` carry the change.

## If it fails again

Read the `GitHub answers receive-pack discovery with HTTP nnn` line in the release log first. Only a
401 on every retry points at the token. Until the cause is known, setting `image.tag` by hand in
`apps/<app>/values.yaml` ships the release.
