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

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"

  echo "[INFO] Waiting for deployment '${deployment}' in namespace '${namespace}'"

  for i in $(seq 1 60); do
    if oc get deploy "${deployment}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "[ERROR] Timeout waiting for deployment ${deployment}" >&2
  return 1
}

wait_for_ready_pod() {
  local namespace="$1"
  local selector="$2"
  local label="$3"

  echo "[INFO] Waiting for any Ready pod: ${label}"

  for i in $(seq 1 60); do
    if oc get pods -n "${namespace}" -l "${selector}" --no-headers 2>/dev/null | grep -q "1/1.*Running"; then
      oc get pods -n "${namespace}" -l "${selector}"
      return 0
    fi

    sleep 5
  done

  echo "[ERROR] Timeout waiting for Ready pod: ${label}" >&2
  oc get pods -n "${namespace}" -l "${selector}" || true
  return 1
}

scale_down_not_ready_grafana_rs() {
  echo "[INFO] Scaling old/not-ready Grafana ReplicaSets to zero if needed"

  local rs_list
  rs_list="$(oc get rs -n grafana --no-headers 2>/dev/null | grep '^grafana-deployment' || true)"

  if [ -z "${rs_list}" ]; then
    echo "[INFO] No Grafana ReplicaSets found yet"
    return 0
  fi

  echo "${rs_list}" | while read -r rs desired current ready age; do
    if [ "${ready}" = "0" ]; then
      echo "[INFO] Scaling down not-ready ReplicaSet ${rs}"
      oc scale rs "${rs}" -n grafana --replicas=0 || true
    fi
  done
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

wait_for_deployment grafana grafana-operator-controller-manager-v5

echo "[INFO] Patching Grafana Operator resources for sandbox environments"

oc patch deploy grafana-operator-controller-manager-v5 \
  -n grafana \
  --type=json \
  -p='[
    {
      "op":"replace",
      "path":"/spec/template/spec/containers/0/resources",
      "value":{
        "requests":{"cpu":"5m","memory":"32Mi"},
        "limits":{"cpu":"100m","memory":"256Mi"}
      }
    }
  ]' || true

echo "[INFO] Restarting Grafana Operator pod"

oc delete pod -n grafana \
  -l app.kubernetes.io/name=grafana-operator \
  --ignore-not-found || true

wait_for_ready_pod grafana "app.kubernetes.io/name=grafana-operator" "Grafana Operator"

wait_for_csv grafana grafana-operator

bash ./scripts/00-create-grafana-token-secret.sh

oc apply -f 04-grafana/02-grafana-instance.yaml

echo "[INFO] Waiting for Grafana deployment"

wait_for_deployment grafana grafana-deployment

echo "[INFO] Patching Grafana instance resources for sandbox environments"

oc patch deploy grafana-deployment \
  -n grafana \
  --type=json \
  -p='[
    {
      "op":"replace",
      "path":"/spec/template/spec/containers/0/resources",
      "value":{
        "requests":{"cpu":"25m","memory":"128Mi"},
        "limits":{"cpu":"200m","memory":"512Mi"}
      }
    }
  ]' || true

sleep 10
scale_down_not_ready_grafana_rs

echo "[INFO] Waiting for any Grafana pod to become Ready"

wait_for_ready_pod grafana "app=grafana" "Grafana instance"

echo "[8/8] Grafana datasources, dashboards and traffic generators"

echo "[INFO] Creating Grafana ServiceAccount for Prometheus/Thanos access"

oc create sa grafana-sa -n grafana --dry-run=client -o yaml | oc apply -f -

echo "[INFO] Granting cluster-monitoring-view to grafana-sa"

oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  system:serviceaccount:grafana:grafana-sa

echo "[INFO] Generating Prometheus token for grafana-sa"

PROM_TOKEN="$(oc create token grafana-sa -n grafana --duration=8760h)"

if [ -z "${PROM_TOKEN}" ]; then
  echo "[ERROR] Could not generate Prometheus token for grafana-sa" >&2
  exit 1
fi

echo "[INFO] Restoring datasource placeholder if backup exists"

if [ -f 04-grafana/03-grafana-datasources.yaml.bak ]; then
  cp 04-grafana/03-grafana-datasources.yaml.bak 04-grafana/03-grafana-datasources.yaml
fi

echo "[INFO] Injecting Prometheus token into Grafana datasource manifest"

if grep -q "REPLACE_PROM_TOKEN" 04-grafana/03-grafana-datasources.yaml; then
  cp 04-grafana/03-grafana-datasources.yaml 04-grafana/03-grafana-datasources.yaml.bak
  sed -i "s|REPLACE_PROM_TOKEN|${PROM_TOKEN}|g" 04-grafana/03-grafana-datasources.yaml
else
  echo "[WARN] REPLACE_PROM_TOKEN placeholder not found in 04-grafana/03-grafana-datasources.yaml"
  echo "[WARN] Make sure your datasource has a valid Bearer token configured"
fi

oc apply -f 04-grafana/03-grafana-datasources.yaml
oc apply -f 04-grafana/04-grafana-dashboards.yaml
oc apply -f 04-grafana/05-traffic-generators.yaml

echo "[INFO] Waiting 15 seconds for Grafana reconciliation"
sleep 15

echo "[INFO] Validating Grafana resources"

oc get grafana,grafanadatasource,grafanadashboard -n grafana

GRAFANA_URL="https://$(oc get route grafana -n grafana -o jsonpath='{.spec.host}' 2>/dev/null || true)"
GRAFANA_USER="admin"
GRAFANA_PASSWORD="grafana-lab"

echo ""
echo "============================================================"
echo " Grafana Access"
echo "============================================================"
echo " URL      : ${GRAFANA_URL}"
echo " User     : ${GRAFANA_USER}"
echo " Password : ${GRAFANA_PASSWORD}"
echo "============================================================"
echo ""
echo "[OK] Installation requested. Validate with: ./scripts/validate.sh"
