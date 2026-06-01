#!/usr/bin/env bash
# platform.sh — orchestrates the local GitOps platform.
# Usage: ./platform.sh <command>
# Works from Git Bash on Windows and from any POSIX shell on macOS/Linux.
set -euo pipefail

CLUSTER="gitops-platform"
APP_IMAGE="gitops-platform-app"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# On Git Bash / MSYS, native Windows binaries (docker, k3d, helm, kubectl) need
# Windows-style paths. cygpath converts them; on Linux/macOS it's absent and we
# return the path unchanged. Pair with MSYS_NO_PATHCONV=1 when an arg like
# ":/src" must not be auto-mangled by the shell.
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { echo "missing required tool: $bin"; exit 1; }
  done
}

cmd_test() {
  log "Running Go tests in a container (no local Go needed)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "$(winpath "$ROOT/app"):/src" -w /src golang:1.23-alpine go test ./...
  ok "tests passed"
}

cmd_build() {
  require docker
  log "Building image $APP_IMAGE:dev"
  docker build -t "$APP_IMAGE:dev" --build-arg VERSION=dev "$(winpath "$ROOT/app")"
  ok "image built"
}

cmd_cluster() {
  require k3d kubectl
  if k3d cluster list | grep -q "^$CLUSTER\b"; then
    warn "cluster $CLUSTER already exists"
  else
    log "Creating k3d cluster"
    k3d cluster create --config "$(winpath "$ROOT/k3d-config.yaml")"
    ok "cluster created"
  fi
  kubectl config use-context "k3d-$CLUSTER" >/dev/null
}

cmd_ingress() {
  require helm kubectl
  log "Installing ingress-nginx"
  helm upgrade --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=LoadBalancer \
    --wait
  ok "ingress-nginx ready"
}

cmd_argocd() {
  require kubectl
  log "Installing ArgoCD"
  kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
  # Server-side apply: the applicationsets CRD exceeds the 256 KB annotation
  # limit of client-side apply's last-applied-configuration.
  kubectl apply -n argocd --server-side=true --force-conflicts -f "$ARGOCD_MANIFEST"
  log "Waiting for ArgoCD server to be ready"
  kubectl rollout status -n argocd deploy/argocd-server --timeout=180s
  ok "ArgoCD ready"
}

# Full local setup: cluster + ingress + ArgoCD + locally-built image imported.
cmd_up() {
  cmd_cluster
  cmd_ingress
  cmd_argocd
  cmd_build
  log "Importing local image into the cluster"
  k3d image import "$APP_IMAGE:dev" -c "$CLUSTER"
  ok "Platform base is up."
  echo
  cmd_info
}

# GitOps path: register the App-of-Apps root (requires the repo pushed to GitHub
# and './platform.sh configure <github-user>' already run).
cmd_bootstrap() {
  require kubectl
  if grep -rq "OWNER" "$ROOT/clusters"; then
    warn "clusters/ still contains the OWNER placeholder."
    warn "Run: ./platform.sh configure <your-github-username>  then push to GitHub."
    exit 1
  fi
  log "Applying App-of-Apps root"
  kubectl apply -f "$(winpath "$ROOT/clusters/bootstrap/root-app.yaml")"
  ok "ArgoCD will now sync the platform from Git."
}

# Local demo path (no GitHub needed): deploy the chart + monitoring directly
# via Helm, using the locally-built image. Great for a first look.
cmd_demo() {
  require helm kubectl
  log "Deploying demo-app via Helm (local image)"
  helm upgrade --install demo-app "$(winpath "$ROOT/charts/demo-app")" \
    --namespace demo --create-namespace \
    --set image.repository="$APP_IMAGE" --set image.tag=dev \
    --set serviceMonitor.enabled=false \
    --wait
  log "Deploying kube-prometheus-stack"
  helm upgrade --install monitoring kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts \
    --namespace monitoring --create-namespace \
    --set grafana.adminPassword=admin \
    --set grafana.ingress.enabled=true \
    --set grafana.ingress.ingressClassName=nginx \
    --set grafana.ingress.hosts[0]=grafana.localhost \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait --timeout 10m
  log "Re-enabling ServiceMonitor for the app"
  helm upgrade demo-app "$(winpath "$ROOT/charts/demo-app")" \
    --namespace demo \
    --set image.repository="$APP_IMAGE" --set image.tag=dev
  ok "Demo deployed."
  echo
  cmd_info
}

cmd_configure() {
  local user="${1:-}"
  [ -n "$user" ] || { echo "usage: ./platform.sh configure <github-username>"; exit 1; }
  log "Setting GitHub owner to '$user' across clusters/ and charts/"
  # Portable in-place sed (GNU + BSD).
  find "$ROOT/clusters" "$ROOT/charts" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
    | xargs -0 sed -i.bak "s#OWNER#$user#g"
  find "$ROOT" -name '*.bak' -delete
  ok "Done. Commit and push, then run: ./platform.sh bootstrap"
}

cmd_argocd_password() {
  require kubectl
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | { base64 -d 2>/dev/null || base64 --decode; }
  echo
}

cmd_info() {
  cat <<EOF
$(printf '\033[1;35m── Access ─────────────────────────────────────────────\033[0m')
  Demo app   : http://demo.localhost:8080
  Grafana    : http://grafana.localhost:8080   (admin / admin)
  ArgoCD UI  : kubectl -n argocd port-forward svc/argocd-server 8081:443
               then https://localhost:8081  (user: admin)
               password: ./platform.sh argocd-password

  curl test  : curl -H 'Host: demo.localhost' http://localhost:8080/metrics
EOF
}

cmd_status() {
  require kubectl
  kubectl get applications -n argocd 2>/dev/null || true
  echo
  kubectl get pods -A
}

cmd_down() {
  require k3d
  log "Deleting cluster $CLUSTER"
  k3d cluster delete "$CLUSTER"
  ok "cluster removed"
}

usage() {
  cat <<EOF
platform.sh — local GitOps platform

  up               Create cluster + ingress + ArgoCD + build/import image
  demo             Deploy app + monitoring locally via Helm (no GitHub needed)
  configure <usr>  Replace the OWNER placeholder with your GitHub username
  bootstrap        Register the App-of-Apps root (GitOps from GitHub)
  build            Build the app container image
  test             Run Go tests in a container
  status           Show ArgoCD apps and all pods
  info             Print access URLs
  argocd-password  Print the initial ArgoCD admin password
  down             Delete the cluster
EOF
}

case "${1:-}" in
  up)              cmd_up ;;
  demo)            cmd_demo ;;
  configure)       shift; cmd_configure "$@" ;;
  bootstrap)       cmd_bootstrap ;;
  build)           cmd_build ;;
  test)            cmd_test ;;
  cluster)         cmd_cluster ;;
  ingress)         cmd_ingress ;;
  argocd)          cmd_argocd ;;
  status)          cmd_status ;;
  info)            cmd_info ;;
  argocd-password) cmd_argocd_password ;;
  down)            cmd_down ;;
  *)               usage ;;
esac
