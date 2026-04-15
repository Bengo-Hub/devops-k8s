# ollama-shared

Consolidated Ollama StatefulSet in the `shared-infra` namespace. Replaces the previous per-namespace Ollama deployments (`marketflow/ollama`, `truload/ollama`).

Models loaded at boot:
- `nomic-embed-text` — 768-dim embeddings for marketflow-ai RAG
- `llama3.1:8b` — tool-calling capable LLM for truload-backend text-to-SQL and marketflow-ai agentic fallback

Service DNS: `ollama.shared-infra.svc.cluster.local:11434`.

## Consumers

| Service | Purpose | Env/Config |
|---------|---------|------------|
| marketflow-ai | embeddings (`nomic-embed-text`) | `MF_AI_OLLAMA_URL` |
| truload-backend | text-to-SQL (`llama3.1:8b`) | `Ollama:BaseUrl` (appsettings) |
| marketflow-worker | embedding pipeline | `MF_WORKER_OLLAMA_URL` |

## Migration

1. Apply `ollama-shared/app.yaml`; wait for `ollama-0` ready + both models present: `kubectl -n shared-infra exec ollama-0 -- ollama list`.
2. Roll marketflow-ai with updated `values.yaml` (URL → shared-infra).
3. Roll truload-backend with updated `appsettings.json` (URL + model → `llama3.1:8b`).
4. After 48h of clean logs, set old Applications (`apps/ollama`, `apps/truload/ollama`) to `syncPolicy: manual` or delete them. Remove old PVCs last.

## Rollback

Revert the single values.yaml / appsettings.json commit; re-enable the old ArgoCD Application. PVCs remain intact.
