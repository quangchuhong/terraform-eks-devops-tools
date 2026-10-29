
# get pass admin grafana
kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo

user: admin
password: g0q9LgCmiHyxSfXjozIPIzakEUy4VNcKLHtezjnF


# prometheus

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/prometheus

# grafana

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install grafana grafana/grafana

# Xác nhận trong Grafana logs, check log url login
kubectl logs -n monitoring <grafana-pod-name> | grep "protocol"




