Contributing to DevOps-K8s
==========================

Thank you for contributing to the CodeVertex DevOps infrastructure!

Getting Started
---------------

1. Read the documentation in `docs/` to understand the architecture
2. Review existing apps in `apps/` for reference
3. Check open issues for tasks that need help

Adding a New Application
-----------------------

1. Create directory: `apps/<app-name>/`
2. Add `values.yaml` with app-specific configuration
3. Add `app.yaml` (Argo CD Application manifest)
4. Add `README.md` explaining the app

Example structure:
```
apps/my-app/
├── values.yaml       # Helm values
├── app.yaml          # Argo CD Application
└── README.md         # Documentation
```

Modifying the Generic Chart
---------------------------

The chart at `charts/app/` is used by all applications. Changes here affect all deployments.

1. Test changes locally with `helm template`
2. Update version in `Chart.yaml`
3. Document breaking changes in commit message
4. Test with at least one app before merging

Documentation Updates
--------------------

- Keep docs in sync with actual implementation
- Use clear step-by-step instructions
- Include troubleshooting sections
- Add examples where helpful

Pull Request Guidelines
-----------------------

1. Create a feature branch from `main`
2. Make focused, atomic commits
3. Write clear commit messages
4. Test your changes
5. Update relevant documentation
6. Request review from @codevertex team

Commit Message Format
--------------------

```
<type>: <subject>

<body>

<footer>
```

Types:
- feat: New feature
- fix: Bug fix
- docs: Documentation only
- chore: Maintenance tasks
- refactor: Code restructuring

Example:
```
feat: add monitoring ServiceMonitor for ERP API

Added Prometheus ServiceMonitor to scrape /metrics endpoint
from ERP API service for better observability.

Relates to #123
```

Code of Conduct
---------------

- Be respectful and inclusive
- Provide constructive feedback
- Focus on the problem, not the person
- Follow CodeVertex IT Solutions values

Questions?
----------

Contact: codevertexitsolutions@gmail.com
Website: https://www.codevertexitsolutions.com

