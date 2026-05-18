#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Removing demo application"
oc delete namespace demo-app --ignore-not-found --wait=false

echo "[INFO] Removing Grafana namespace"
oc delete namespace grafana --ignore-not-found --wait=false

echo "[INFO] Removing Beyla resources"
oc delete namespace beyla --ignore-not-found --wait=false
oc delete scc beyla-scc --ignore-not-found || true
oc delete clusterrole beyla --ignore-not-found || true
oc delete clusterrolebinding beyla --ignore-not-found || true

echo "[INFO] Removing NetObserv resources"
oc delete flowcollector cluster --ignore-not-found || true
oc delete subscription netobserv-operator -n openshift-operators --ignore-not-found || true

echo "[INFO] Removing LokiStack and MinIO"
oc delete lokistack loki -n netobserv --ignore-not-found || true
oc delete secret loki-s3-secret -n netobserv --ignore-not-found || true
oc delete namespace minio --ignore-not-found --wait=false

echo "[INFO] Removing Loki Operator"
oc delete subscription loki-operator -n openshift-operators --ignore-not-found || true

echo "[INFO] Removing remaining lab namespaces"
oc delete namespace netobserv --ignore-not-found --wait=false
oc delete namespace netobserv-privileged --ignore-not-found --wait=false

echo "[INFO] Removing InstallPlans"
oc delete installplan -n grafana --all --ignore-not-found 2>/dev/null || true
oc delete installplan -n openshift-operators --all --ignore-not-found 2>/dev/null || true

echo "[INFO] Waiting a few seconds for namespace cleanup"
sleep 15

echo "[INFO] Checking for orphan Grafana CRs"

if oc get grafanadatasource,grafanadashboard -A >/dev/null 2>&1; then

  echo "[INFO] Recreating temporary grafana namespace for cleanup"
  oc create namespace grafana >/dev/null 2>&1 || true

  echo "[INFO] Removing GrafanaDatasource finalizers"

  for obj in $(oc get grafanadatasource -n grafana -o name 2>/dev/null); do
    echo "[INFO] Cleaning ${obj}"

    oc patch "$obj" -n grafana \
      --type=merge \
      -p '{"metadata":{"finalizers":[]}}' || true

    oc delete "$obj" -n grafana \
      --ignore-not-found || true
  done

  echo "[INFO] Removing GrafanaDashboard finalizers"

  for obj in $(oc get grafanadashboard -n grafana -o name 2>/dev/null); do
    echo "[INFO] Cleaning ${obj}"

    oc patch "$obj" -n grafana \
      --type=merge \
      -p '{"metadata":{"finalizers":[]}}' || true

    oc delete "$obj" -n grafana \
      --ignore-not-found || true
  done

  echo "[INFO] Removing temporary grafana namespace"
  oc delete namespace grafana --ignore-not-found --wait=false || true
fi

echo "[INFO] Waiting final cleanup"
sleep 10

echo ""
echo "============================================================"
echo " Remaining lab resources"
echo "============================================================"

oc get ns | egrep 'grafana|netobserv|beyla|minio|demo-app' || true

echo ""
echo "[INFO] Remaining Grafana CRs (should be empty)"

oc get grafana,grafanadatasource,grafanadashboard -A 2>/dev/null || true

echo ""
echo "============================================================"
echo " Uninstall completed"
echo "============================================================"
