#!/usr/bin/env bash
set -euo pipefail

echo "== Namespaces =="
oc get ns netobserv beyla grafana minio demo-app

echo "\n== Loki =="
oc get pods -n netobserv
oc get lokistack -n netobserv || true

echo "\n== NetObserv =="
oc get flowcollector

echo "\n== Beyla =="
oc get pods,svc,route -n beyla

echo "\n== Demo app =="
oc get pods,svc,route -n demo-app

echo "\n== Grafana =="
oc get pods,svc,route -n grafana
oc get grafana,grafanadatasource,grafanadashboard -n grafana

echo "\n== URLs =="
echo "Grafana: https://$(oc get route grafana -n grafana -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo "Demo API: https://$(oc get route demo-api -n demo-app -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo "Beyla metrics: https://$(oc get route beyla-metrics -n beyla -o jsonpath='{.spec.host}' 2>/dev/null || true)/metrics"
