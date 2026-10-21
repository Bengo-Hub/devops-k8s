# Secrets and keys in production

How the platform's secrets reach the pods, what was checked on 2026-10-20, and what is still open.
This file lists names and process only. No value belongs here.

## Where secrets come from

- `scripts/infrastructure/create-service-secrets.sh` builds `<service>-secrets` in each namespace
  during the service's deploy. Values that must never rotate are generated once and then preserved
  (read the existing key first): encryption keys, `TERMINAL_JWT_SECRET` (library-api and, since
  2026-10-20, pos-api), `SESSION_SECRET`.
- `INTERNAL_SERVICE_KEY` is the one shared service-to-service key. The script never generates it; it
  copies the platform value. A new service that calls others must be added to the script's
  `NEEDS_ISK` list.
- Provider credentials (payment gateways, SMS, email, eTIMS) are not environment secrets. They are
  configured in the database through each service's integration settings, encrypted at rest. A key
  missing from the environment for one of those is therefore normal, not a gap.
- The Helm values reference secrets with `secretKeyRef`. A reference marked `optional: true` does not
  stop the pod when the key is missing; it leaves the variable unset, and code then falls back or
  fails open or closed depending on how it was written. Prefer non-optional references for keys a
  service cannot run safely without.

## Auditing

`scripts/tools/audit-secret-refs.sh` is read-only and prints names and presence only:

    printf 'pos pos-api\ntreasury treasury-api\n' | scripts/tools/audit-secret-refs.sh

It reports secrets a deployment references that do not exist and keys missing from existing ones.

## Result of the 2026-10-20 audit

- `INTERNAL_SERVICE_KEY` is present, 48 characters and identical in all 14 API deployments and in
  the UIs that use it. Treasury (`SUBSCRIPTIONS_API_KEY`) and auth-api (`AUTH_SUBSCRIPTION_API_KEY`)
  have their own variable names that are unset; both fall back to the shared key in code, so
  nothing is broken.
- Fixed: maskani-ui referenced `maskani-ui-secrets`, which did not exist, so its subscription proxy
  had no key. The secret now exists with the shared key (the secrets script already lists maskani-ui).
- Fixed: pos-api had no `TERMINAL_JWT_SECRET`, so PIN-terminal tokens were signed with the shared
  service key (anyone holding it could mint terminal tokens for any tenant). pos-api now has its own
  secret, generated once by the script and read by the deployment without a fallback.
- Fixed (code): ordering-backend had no webhook secrets and treated an unsigned request as valid, so
  the public `POST /api/v1/webhooks/treasury` route could mark an order paid. Both ordering webhooks
  now refuse unsigned, badly signed and unconfigured requests. Nothing legitimate sends them: treasury
  has no webhook endpoints or deliveries and logistics has no sender. Set `TREASURY_WEBHOOK_SECRET`
  and `LOGISTICS_WEBHOOK_SECRET` only if a sender is ever configured.
- Known and intentional (provider keys live in the database): treasury KRA eTIMS and OSCU
  credentials, marketflow Meta, Claude, Groq and Tavily keys, isp-billing SMS, SMTP and MikroTik
  defaults.
- Still to review: isp-billing-frontend has no `NEXTAUTH_SECRET` value in its secret (its source does
  not appear to use next-auth, so it is probably a leftover reference), and auth-api's
  `PLATFORM_API_KEY` reference points at a key that does not exist (harmless because of the
  fallback; remove the reference).
- Sentry DSNs (projects-ui, ticketing-ui, isp-billing) and the projects-ui Mapbox token are optional
  and unset.
