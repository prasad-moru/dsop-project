#!/usr/bin/env bash
# =============================================================================
# istio-tracing-patch.sh
# Patches Istio 1.29.2 meshConfig to send traces to Jaeger.
# Run AFTER Jaeger is installed and running.
#
# What it does:
#   1. Enables 100% trace sampling (demo — reduce to 1% in production)
#   2. Points Envoy sidecars to Jaeger Zipkin collector on port 9411
#   3. Upgrades istiod Helm release with new meshConfig
#
# Run: bash istio-tracing-patch.sh
# =============================================================================

set -euo pipefail

ISTIO_NS="istio-system"
SAMPLING_RATE=100   # 100% for demo — change to 1 for production

echo "==> Patching Istio meshConfig to enable Jaeger tracing..."
echo "    Sampling rate: ${SAMPLING_RATE}%"
echo ""

# Verify Jaeger is running first
JAEGER_POD=$(kubectl get pod -n ${ISTIO_NS} \
  -l app.kubernetes.io/name=jaeger \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${JAEGER_POD}" ]; then
  echo "ERROR: Jaeger pod not found in ${ISTIO_NS}."
  echo "Install Jaeger first: helm install jaeger jaegertracing/jaeger -f jaeger-values.yaml -n ${ISTIO_NS}"
  exit 1
fi
echo "    Jaeger pod found: ${JAEGER_POD}"

# Get Jaeger ClusterIP
JAEGER_IP=$(kubectl get svc jaeger-collector \
  -n ${ISTIO_NS} \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || \
  kubectl get svc jaeger-all-in-one \
  -n ${ISTIO_NS} \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

echo "    Jaeger service ClusterIP: ${JAEGER_IP}"

# Upgrade istiod with tracing config
echo ""
echo "==> Upgrading istiod Helm release with tracing config..."

helm upgrade istiod istio/istiod \
  -n ${ISTIO_NS} \
  --reuse-values \
  --set meshConfig.enableTracing=true \
  --set meshConfig.defaultConfig.tracing.sampling=${SAMPLING_RATE} \
  --set "meshConfig.defaultConfig.tracing.zipkin.address=jaeger-collector.${ISTIO_NS}:9411"

echo "    istiod upgraded."

# Verify meshConfig was applied
echo ""
echo "==> Verifying meshConfig..."
kubectl get configmap istio -n ${ISTIO_NS} \
  -o jsonpath='{.data.mesh}' | grep -E "tracing|zipkin|sampling"

# Restart all application pods to pick up new tracing config
echo ""
echo "==> Restarting application pods to pick up tracing config..."
kubectl rollout restart deployment -n application
kubectl rollout restart deployment -n platform
kubectl rollout restart statefulset -n platform

echo ""
echo "==> Waiting for pods to restart..."
kubectl rollout status deployment -n application --timeout=3m
echo ""
echo "==================================================================="
echo " Tracing setup complete."
echo " Verify traces appear in Jaeger UI after 2 minutes of traffic."
echo " Jaeger UI: https://jaeger.devopsproduction.com"
echo "==================================================================="
