Monitoring and Alerts
---------------------

Recommended stack: Prometheus, Grafana, kube-state-metrics, metrics-server, Loki.

- Install with kube-prometheus-stack Helm chart.
- Configure alerts for pod restarts, HPA saturation, high latency.
- Expose application metrics via `/metrics` when possible.


