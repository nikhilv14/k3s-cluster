#!/bin/bash
set -e

export KUBECONFIG=./k3s.yaml

echo "Cleanup old Nginx..."
helm uninstall ing-nginx -n ingress-nginx || true
kubectl delete ingressclass nginx || true
kubectl delete ns ingress-nginx || true

echo "1. Installing MetalLB..."
helm repo add metallb https://metallb.github.io/metallb || true
helm repo update
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --version v0.14.5

echo "2. Applying MetalLB config..."
kubectl apply -f networking/metallb-config.yaml

echo "3. Installing Nginx Ingress..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace -f networking/nginx-values.yaml

echo "Waiting for Nginx controller ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=300s

echo "4. Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io || true
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --version v1.15.3

echo "5. Applying selfsigned issuer..."
kubectl apply -f networking/selfsigned-issuer.yaml

echo "6. Applying CA issuer..."
kubectl apply -f networking/ca-issuer.yaml

echo "Waiting for CA secret..."
for i in {1..60}; do
  if kubectl get secret ca-key-pair -n cert-manager &> /dev/null; then
    break
  fi
  sleep 5
done

echo "7. Exporting CA cert..."
kubectl get secret ca-key-pair -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
echo "CA cert exported to ca.crt - trust on devices."

echo "8. Deploying test app..."
kubectl apply -f networking/test-app.yaml

echo "Waiting for Nginx LB IP..."
for i in {1..60}; do
  IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  if [[ \"$IP\" != \"pending\" && \"$IP\" != \"<pending>\" && -n \"$IP\" ]]; then
    echo \"Nginx LB IP: $IP\"
    break
  fi
  sleep 5
done

echo \"Test: Add 'test.home $IP' to /etc/hosts (if assigned), curl -k https://test.home\"
echo \"All done!\"