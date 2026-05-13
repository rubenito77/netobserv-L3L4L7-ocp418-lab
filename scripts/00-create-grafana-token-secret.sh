#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana"
SA="grafana-sa"
DS_FILE="04-grafana/03-grafana-datasources.yaml"

if [[ ! -f "${DS_FILE}" ]]; then
  echo "[ERROR] Run this script from the repository root. Missing ${DS_FILE}" >&2
  exit 1
fi

echo "[INFO] Creating ServiceAccount ${SA} in namespace ${NAMESPACE}"
oc create sa "${SA}" -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

echo "[INFO] Granting cluster-monitoring-view to ${SA}"
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z "${SA}" -n "${NAMESPACE}"

echo "[INFO] Creating long-lived lab token"
TOKEN="$(oc create token "${SA}" -n "${NAMESPACE}" --duration=8760h)"

if grep -q 'REPLACE_PROM_TOKEN' "${DS_FILE}"; then
  echo "[INFO] Injecting token into ${DS_FILE}"
  sed -i.bak "s|REPLACE_PROM_TOKEN|${TOKEN}|g" "${DS_FILE}"
  echo "[OK] Token injected. Backup created at ${DS_FILE}.bak"
else
  echo "[WARN] Placeholder REPLACE_PROM_TOKEN not found in ${DS_FILE}."
  echo "[WARN] The file may already contain a token. No replacement performed."
fi

echo "[OK] Grafana Prometheus datasource token ready"
