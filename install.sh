#!/usr/bin/env bash
set -euo pipefail

wait_for_csv() {
  local namespace="$1"
  local pattern="$2"
  echo "[INFO] Waiting for CSV matching '${pattern}' in namespace '${namespace}'"
  for i in $(seq 1 60); do
    if oc get csv -n "${namespace}" 2>/dev/null | grep -i "${pattern}" | grep -q Succeeded; then
      oc get csv -n "${namespace}" | grep -i "${pattern}"
      return 0
    fi
    sleep 10
  done
  echo "[ERROR] Timeout waiting for CSV ${pattern}" >&2
  return 1
}

echo "[1/8] Namespaces"
oc apply -f 00-namespaces/namespaces.yaml

echo "[2/8] Loki Operator"
oc apply -f 01-loki/01-loki-operator-subscription.yaml
wait_for_csv openshift-operators loki

echo "[3/8] MinIO object store"
oc apply -f 01-loki/02-minio-lab.yaml
oc wait --for=condition=complete job/minio-create-bucket -n minio --timeout=180s

echo "[4/8] LokiStack"
oc apply -f 01-loki/03-lokistack.yaml

echo "[5/8] NetObserv Operator and FlowCollector"
oc apply -f 02-netobserv/01-netobserv-subscription.yaml
wait_for_csv openshift-operators network-observability
oc apply -f 02-netobserv/02-flowcollector.yaml

echo "[6/8] Beyla and demo app"
oc apply -f 03-beyla/01-beyla-rbac.yaml
oc apply -f 03-beyla/02-beyla-configmap.yaml
oc apply -f 03-beyla/03-beyla-daemonset.yaml
oc apply -f 03-beyla/04-demo-app.yaml
oc apply -f 03-beyla/05-beyla-route.yaml

echo "[7/8] Grafana Operator and instance"
oc apply -f 04-grafana/01-grafana-operator.yaml
wait_for_csv grafana grafana-operator
./scripts/00-create-grafana-token-secret.sh
oc apply -f 04-grafana/02-grafana-instance.yaml

echo "[8/8] Grafana datasources, dashboards and traffic generators"
oc apply -f 04-grafana/03-grafana-datasources.yaml
oc apply -f 04-grafana/04-grafana-dashboards.yaml
oc apply -f 04-grafana/05-traffic-generators.yaml

echo "[OK] Installation requested. Validate with: ./scripts/validate.sh"
