# Release push failures ("could not read Username")

Every service's release step ends by pushing the new image tag to `apps/<app>/values.yaml` in this
repository (`scripts/helm/update-values.sh`). On 2026-10-20 several services failed that push with
`warning: redirecting to ...` followed by `fatal: could not read Username`, reported as "check token
permissions". It looked like a dead `GH_PAT`, and re-syncing the secret was tried repeatedly. It was
not the token.

## Root cause

The script pushed to `https://TOKEN@github.com/Bengo-Hub/devops-k8s.git`: the token alone as the
URL's username, with no password. GitHub now answers `.git` URLs with a redirect to `.git/`. After a
redirect git has no password to resend, so it tries to prompt, finds no terminal and aborts with
`could not read Username`. The same push worked while GitHub did not redirect, which is why this
appeared suddenly and why it looked intermittent (the redirect did not reach every request at first).

The proof, from a CI runner (git 2.55.0) pushing a throwaway branch to this repository with the same
`GH_PAT`:

| URL form | Result |
|---|---|
| `https://TOKEN@github.com/Bengo-Hub/devops-k8s.git` | fails: could not read Username |
| the same with a trailing `/`, with no `.git`, or with `-c http.followRedirects=true` | fails the same way |
| `https://x-access-token:TOKEN@github.com/Bengo-Hub/devops-k8s.git` | pushes |

## What was ruled out, and why the first probes missed it

- **The tokens.** `GH_PAT` and `PROPAGATE_PAT` here, and the `GH_PAT` held by treasury-api, all answer
  HTTP 200 with admin and push rights (classic tokens, no expiry, no stray whitespace). GitHub answered
  the push discovery request with HTTP 200 for the same token at the moment a push failed.
- **Timeline.** treasury-api's last good release was 2026-10-19 07:29 UTC and the first failure
  2026-10-20 13:23 UTC; nothing in `scripts/`, `.github/actions/` or treasury-api's workflow changed
  in between. The only thing that changed was GitHub's behaviour.
- **`git push --dry-run` is not a test.** It stops after the discovery request and never sends the
  pack, so it passed while the real push failed. Probe with a real push of a throwaway branch.
- The `warning: redirecting to ...git/` line also appears on pushes that succeed; it is the symptom
  of the redirect, not the failure.

## What changed in the script

- All six URLs in `update-values.sh` (clone, remote and push, in both `update_helm_values` and
  `update_plain_manifest_image`) now use `https://x-access-token:TOKEN@github.com/...`, the form
  `build.sh` already used for its own clone.
- A push that fails without a conflict is retried up to 3 times with backoff, and each failure logs
  the HTTP status GitHub gives the receive-pack discovery request (status code only, never the
  token), so a persistent failure names its own cause.

## If it fails again

Read the `GitHub answers receive-pack discovery with HTTP nnn` line first: 401 on every retry points
at the token, 403 or 429 at throttling. Otherwise suspect the URL form before the token. Until it is
fixed, setting `image.tag` by hand in `apps/<app>/values.yaml` ships the release. Any other script
that builds `https://${token}@github.com/` has the same defect and needs the same change.
