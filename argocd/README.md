# Argo CD Access

## Admin Password (CHANGE IMMEDIATELY after first login)
```
F4TWjN9SuwNIh26j
```

## UI Access

**NodePort (No MetalLB)**:
- `/etc/hosts`: `192.168.12.51 argocd.home`
- NodePorts: `kubectl get svc ingress-nginx-controller -n ingress-nginx`
  (Current: HTTP 31016, HTTPS 30185)
- URL: `https://argocd.home:30185`

**Username**: admin

**Port-forward (test)**:
```
kubectl --kubeconfig k3s.yaml port-forward svc/argocd-server -n argocd 8080:80
```
http://localhost:8080 (insecure)

## Change Password
1. Login to UI
2. User Info (top-right) → **Set Password**

## Delete Initial Secret (Security)
```
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## Verify
```
kubectl -n argocd get ingress,certificate | grep argocd
kubectl -n argocd describe ingress argocd-server-ingress
```

---
**Argo CD deployed. Access via NodePort above. GitOps repo ready in `k3s-apps/`.**