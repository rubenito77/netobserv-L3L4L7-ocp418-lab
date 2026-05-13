# OCP NetObserv + Beyla + LokiStack + Grafana Lab

Laboratorio para OpenShift 4.18 orientado a observabilidad de red y aplicaciones con:

- **Network Observability / NetObserv** para tráfico L3/L4.
- **LokiStack** como backend de flows/logs.
- **MinIO** como object storage S3 de laboratorio para Loki.
- **Beyla** con eBPF para métricas HTTP L7 / RED metrics.
- **Grafana Operator** con datasources Prometheus/Thanos y dashboards.
- **Demo app httpbin** y generadores de tráfico.

> Este repo está pensado para laboratorio. Para producción reemplazar MinIO por S3/ODF, pinnear versiones de imágenes, revisar recursos y políticas de seguridad.

---

## Estructura del repositorio

```text
ocp-netobserv-lab/
├── 00-namespaces/
│   └── namespaces.yaml
├── 01-loki/
│   ├── 01-loki-operator-subscription.yaml
│   ├── 02-minio-lab.yaml
│   └── 03-lokistack.yaml
├── 02-netobserv/
│   ├── 01-netobserv-subscription.yaml
│   └── 02-flowcollector.yaml
├── 03-beyla/
│   ├── 01-beyla-rbac.yaml
│   ├── 02-beyla-configmap.yaml
│   ├── 03-beyla-daemonset.yaml
│   ├── 04-demo-app.yaml
│   └── 05-beyla-route.yaml
├── 04-grafana/
│   ├── 01-grafana-operator.yaml
│   ├── 02-grafana-instance.yaml
│   ├── 03-grafana-datasources.yaml
│   ├── 04-grafana-dashboards.yaml
│   └── 05-traffic-generators.yaml
├── scripts/
│   ├── 00-create-grafana-token-secret.sh
│   └── validate.sh
├── install.sh
└── README.md
```

---

## Requisitos

- OpenShift 4.18 o superior.
- Usuario con permisos `cluster-admin`.
- `oc` CLI configurado.
- Catálogos `redhat-operators` y `community-operators` disponibles.
- StorageClass disponible. El LokiStack usa `gp3-csi` por defecto.

Validar StorageClass:

```bash
oc get sc
```

Si tu cluster no usa `gp3-csi`, editar:

```yaml
01-loki/03-lokistack.yaml
storageClassName: gp3-csi
```

---

## Instalación rápida

```bash
git clone <TU_REPO>
cd ocp-netobserv-lab
./install.sh
```

Validar:

```bash
./scripts/validate.sh
```

---

## Instalación paso a paso

### 1. Namespaces

```bash
oc apply -f 00-namespaces/namespaces.yaml
oc get ns | egrep 'netobserv|beyla|grafana|minio'
```

---

### 2. Loki Operator + MinIO + LokiStack

```bash
oc apply -f 01-loki/01-loki-operator-subscription.yaml
oc get csv -n openshift-operators | grep -i loki
```

Esperar `Succeeded`.

Instalar MinIO:

```bash
oc apply -f 01-loki/02-minio-lab.yaml
oc get pods,svc,job -n minio
oc logs job/minio-create-bucket -n minio
```

El Job debe mostrar:

```text
Bucket loki creado OK
```

Instalar LokiStack:

```bash
oc apply -f 01-loki/03-lokistack.yaml
oc get pods -n netobserv -w
```

Esperado:

```text
loki-compactor        Running
loki-distributor      Running
loki-gateway          Running
loki-index-gateway    Running
loki-ingester         Running
loki-querier          Running
loki-query-frontend   Running
```

---

### 3. Network Observability

```bash
oc apply -f 02-netobserv/01-netobserv-subscription.yaml
oc get pods -n openshift-operators | grep -i netobserv
oc apply -f 02-netobserv/02-flowcollector.yaml
oc get flowcollector
oc get pods -n netobserv
```

Esperado:

```text
FlowCollector cluster Ready
Agent: eBPF
Deployment model: Direct
```

En la consola de OpenShift debe aparecer:

```text
Observe → Network Traffic
```

---

### 4. Beyla + demo app

```bash
oc apply -f 03-beyla/01-beyla-rbac.yaml
oc apply -f 03-beyla/02-beyla-configmap.yaml
oc apply -f 03-beyla/03-beyla-daemonset.yaml
oc apply -f 03-beyla/04-demo-app.yaml
oc apply -f 03-beyla/05-beyla-route.yaml
```

Validar:

```bash
oc get pods -n beyla
oc get pods,svc,route,job -n demo-app
```

Probar demo app:

```bash
curl -k https://$(oc get route demo-api -n demo-app -o jsonpath='{.spec.host}')/get
curl -k https://$(oc get route demo-api -n demo-app -o jsonpath='{.spec.host}')/status/500
```

Validar métricas L7 de Beyla:

```bash
curl -k https://$(oc get route beyla-metrics -n beyla -o jsonpath='{.spec.host}')/metrics | grep 'service_name="demo-api"' | head
```

Esperado:

```text
http_server_... service_name="demo-api" service_namespace="demo-app"
```

---

### 5. Grafana Operator + Grafana + Datasources + Dashboards

Instalar operador:

```bash
oc apply -f 04-grafana/01-grafana-operator.yaml
oc get csv -n grafana | grep -i grafana
oc get pods -n grafana
```

Crear token para Prometheus/Thanos y actualizar datasources:

```bash
./scripts/00-create-grafana-token-secret.sh
```

Instalar Grafana:

```bash
oc apply -f 04-grafana/02-grafana-instance.yaml
oc get pods,svc,route -n grafana
```

Aplicar datasources y dashboards:

```bash
oc apply -f 04-grafana/03-grafana-datasources.yaml
oc apply -f 04-grafana/04-grafana-dashboards.yaml
```

Validar:

```bash
oc get grafana,grafanadatasource,grafanadashboard -n grafana
```

Debe aparecer sin `NO MATCHING INSTANCES`:

```text
prometheus-ocp
prometheus-beyla
beyla-red-metrics
netobserv-flows-inline
ocp-observabilidad-combinada
```

> **Nota sobre Loki datasource en Grafana**
>
> Este lab instala LokiStack porque NetObserv lo usa como backend de flows/logs.
> Sin embargo, los endpoints internos del LokiStack en OpenShift pueden requerir **mTLS obligatorio**.
> En ese modo, Grafana no puede consumir directamente el endpoint interno de Loki sin certificados cliente.
>
> Por eso este repo **no crea un datasource Loki en Grafana**.
> Para visualizar flows L3/L4 detallados usar:
>
> ```text
> OpenShift Console → Observe → Network Traffic
> ```
>
> Grafana queda enfocado en métricas vía Thanos/Prometheus:
>
> - `Prometheus-OCP`
> - `Prometheus-Beyla`
> - dashboards L3/L4/L7 combinados

---

### 6. Generadores de tráfico

```bash
oc apply -f 04-grafana/05-traffic-generators.yaml
oc get pods -n demo-app
```

Estos deployments generan:

- tráfico HTTP normal
- tráfico burst
- errores 404/500
- tráfico interno pod-to-pod

Para detenerlos:

```bash
oc scale deploy traffic-generator-http --replicas=0 -n demo-app
oc scale deploy traffic-generator-burst --replicas=0 -n demo-app
oc scale deploy traffic-generator-errors --replicas=0 -n demo-app
oc scale deploy traffic-generator-internal --replicas=0 -n demo-app
```

Para volver a activarlos:

```bash
oc scale deploy traffic-generator-http --replicas=2 -n demo-app
oc scale deploy traffic-generator-burst --replicas=1 -n demo-app
oc scale deploy traffic-generator-errors --replicas=1 -n demo-app
oc scale deploy traffic-generator-internal --replicas=2 -n demo-app
```

---

## Acceso a Grafana

URL:

```bash
echo https://$(oc get route grafana -n grafana -o jsonpath='{.spec.host}')
```

Credenciales por defecto de laboratorio:

```text
Usuario: admin
Password: grafana-lab
```

Dashboards incluidos:

- **Beyla RED Metrics**
- **NetObserv - Flujos de red L3/L4**
- **OCP - Observabilidad L3/L4/L7 combinada**

---

## Validaciones útiles

### Ver métricas HTTP L7 de Beyla

```bash
curl -k https://$(oc get route beyla-metrics -n beyla -o jsonpath='{.spec.host}')/metrics | \
  grep 'http_server_request_duration_seconds' | head
```

### Ver tráfico de demo-api en Beyla

```bash
curl -k https://$(oc get route beyla-metrics -n beyla -o jsonpath='{.spec.host}')/metrics | \
  grep 'service_name="demo-api"' | head
```

### Ver estado NetObserv

```bash
oc get flowcollector
oc get pods -n netobserv
```

### Ver datasources/dashboards Grafana

```bash
oc get grafanadatasource,grafanadashboard -n grafana
```

---

## Troubleshooting

### Loki compactor: `The specified bucket does not exist`

Validar que MinIO creó el bucket:

```bash
oc get job -n minio
oc logs job/minio-create-bucket -n minio
```

Si el Job no muestra `Bucket loki creado OK`, eliminar y recrear:

```bash
oc delete job minio-create-bucket -n minio
oc apply -f 01-loki/02-minio-lab.yaml
```

### Pods Loki en Pending por CPU

Revisar:

```bash
oc describe pod -n netobserv <pod>
```

Si aparece `Insufficient cpu`, usar `size: 1x.demo` si la versión del CRD lo soporta, o liberar recursos del cluster.

### Beyla no muestra `demo-api`

Validar ConfigMap:

```bash
oc get cm beyla-config -n beyla -o yaml
```

Debe tener:

```yaml
discovery:
  services:
    - k8s_namespace: "demo-app"
```

Reiniciar Beyla:

```bash
oc rollout restart ds/beyla -n beyla
```

Generar tráfico:

```bash
for i in {1..100}; do
  curl -k -s https://$(oc get route demo-api -n demo-app -o jsonpath='{.spec.host}')/get > /dev/null
  curl -k -s https://$(oc get route demo-api -n demo-app -o jsonpath='{.spec.host}')/status/500 > /dev/null
done
```

### Grafana no muestra datasources o dashboards

Validar label de la instancia:

```bash
oc get grafana grafana -n grafana --show-labels
```

Debe tener:

```text
dashboards=grafana
```

Validar CRs:

```bash
oc get grafanadatasource,grafanadashboard -n grafana
```

Si aparecen con `NO MATCHING INSTANCES`, revisar que todos tengan:

```yaml
instanceSelector:
  matchLabels:
    dashboards: grafana
```

Recrear CRs:

```bash
oc delete grafanadatasource --all -n grafana
oc delete grafanadashboard --all -n grafana
oc apply -f 04-grafana/03-grafana-datasources.yaml
oc apply -f 04-grafana/04-grafana-dashboards.yaml
```


### Loki datasource en Grafana: `Unable to connect with Loki`

Este repo no crea datasource Loki en Grafana intencionalmente.
En este lab se detectó que LokiStack interno responde con mTLS obligatorio:

```text
tlsv13 alert certificate required
```

Eso confirma que DNS/TLS funcionan, pero el endpoint exige certificado cliente.
La visualización detallada de flows debe hacerse desde:

```text
OpenShift Console → Observe → Network Traffic
```

Los dashboards de Grafana usan Prometheus/Thanos para métricas L3/L4/L7.

---

## Limpieza del lab

```bash
oc delete -f 04-grafana/05-traffic-generators.yaml --ignore-not-found
oc delete -f 04-grafana/04-grafana-dashboards.yaml --ignore-not-found
oc delete -f 04-grafana/03-grafana-datasources.yaml --ignore-not-found
oc delete -f 04-grafana/02-grafana-instance.yaml --ignore-not-found
oc delete -f 04-grafana/01-grafana-operator.yaml --ignore-not-found
oc delete -f 03-beyla/05-beyla-route.yaml --ignore-not-found
oc delete -f 03-beyla/04-demo-app.yaml --ignore-not-found
oc delete -f 03-beyla/03-beyla-daemonset.yaml --ignore-not-found
oc delete -f 03-beyla/02-beyla-configmap.yaml --ignore-not-found
oc delete -f 03-beyla/01-beyla-rbac.yaml --ignore-not-found
oc delete flowcollector cluster --ignore-not-found
oc delete -f 02-netobserv/01-netobserv-subscription.yaml --ignore-not-found
oc delete -f 01-loki/03-lokistack.yaml --ignore-not-found
oc delete -f 01-loki/02-minio-lab.yaml --ignore-not-found
oc delete -f 01-loki/01-loki-operator-subscription.yaml --ignore-not-found
oc delete -f 00-namespaces/namespaces.yaml --ignore-not-found
```
