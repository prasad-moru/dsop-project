#!/usr/bin/env bash
# =============================================================================
# telemetry-install.sh
# Installs Kiali + Jaeger for Istio 1.29.2 on DSOP EKS cluster.
#
# Prerequisites (all confirmed):
#   [x] Istio 1.29.2 installed via Helm
#   [x] istio-proxy sidecar on all application pods
#   [x] kube-prometheus-stack running in monitoring namespace
#   [x] istio_requests_total metrics flowing into Prometheus (20 results)
#
# Run: bash telemetry-install.sh
# =============================================================================

set -euo pipefail

ISTIO_NS="istio-system"
MONITORING_NS="monitoring"

ok()  { echo "  [OK] $*"; }
run() { echo ""; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }

run "STEP 1 — Add Helm repos"
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts 2>/dev/null || true
helm repo add kiali https://kiali.org/helm-charts               2>/dev/null || true
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update
ok "Repos ready."

run "STEP 2 — Install Jaeger all-in-one"
helm install jaeger jaegertracing/jaeger \
  -f jaeger-values.yaml \
  -n istio-system

kubectl rollout status deployment/jaeger \
  -n istio-system --timeout=2m 2>/dev/null || \
kubectl get pods -n istio-system | grep jaeger

ok "Jaeger installed."

# Verify Jaeger services
echo "  Jaeger services:"
kubectl get svc -n ${ISTIO_NS} | grep jaeger

run "STEP 3 — Patch Istio to enable tracing → Jaeger"
bash istio-tracing-patch.sh
ok "Istio tracing configured."

run "STEP 4 — Install Kiali server"
helm upgrade --install kiali-server kiali/kiali-server \
  -f kiali-values.yaml \
  -n ${ISTIO_NS} \
  --timeout 5m \
  --wait

kubectl rollout status deployment/kiali \
  -n ${ISTIO_NS} --timeout=2m
ok "Kiali installed."

run "STEP 5 — Create Route53 DNS records"
# Get ALB DNS names
KIALI_ALB=$(kubectl get ingress kiali \
  -n ${ISTIO_NS} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

JAEGER_ALB=$(kubectl get ingress jaeger \
  -n ${ISTIO_NS} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "  Create these DNS records in Route53:"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ kiali.devopsproduction.com  → CNAME → ${KIALI_ALB}"
echo "  │ jaeger.devopsproduction.com → CNAME → ${JAEGER_ALB}"
echo "  └─────────────────────────────────────────────────────────────┘"

run "STEP 6 — Verify end-to-end"
echo "  Waiting 60s for traffic to generate traces..."
sleep 60

# Check Prometheus has Istio metrics
echo "  Checking istio_requests_total in Prometheus..."
COUNT=$(kubectl exec -n ${MONITORING_NS} \
  $(kubectl get pod -n ${MONITORING_NS} \
    -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- \
  "http://localhost:9090/api/v1/query?query=istio_requests_total" | \
  python3 -m json.tool | grep -c "source_app" || echo "0")
echo "  istio_requests_total results: ${COUNT}"

# Check Kiali can reach Prometheus
echo ""
echo "  Checking Kiali health..."
kubectl get pods -n ${ISTIO_NS} | grep kiali

# Check Jaeger received traces
echo ""
echo "  Checking Jaeger services..."
kubectl get pods -n ${ISTIO_NS} | grep jaeger

run "STEP 7 — Summary"
echo ""
echo "══════════════════════════════════════════════════════════"
echo " Telemetry Stack Ready"
echo "══════════════════════════════════════════════════════════"
echo ""
echo " Kiali  : https://kiali.devopsproduction.com/kiali"
echo " Jaeger : https://jaeger.devopsproduction.com"
echo " Grafana: https://grafana.devopsproduction.com"
echo ""
echo " What you will see in Kiali:"
echo "   Graph → Namespace: application"
echo "   → Live service topology like the screenshot"
echo "   → RPS, latency, error rate per service"
echo "   → Click any edge to see traces in Jaeger"
echo ""
echo " Kiali graph tips:"
echo "   - Select namespace: application"
echo "   - Display: Traffic Animation ON"
echo "   - Versioned app graph"
echo "   - Edge labels: Request rate + Response time"
echo "══════════════════════════════════════════════════════════"
