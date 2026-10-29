
#. Set up gitlab form Helm

# Thêm Helm repo
helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm install gitlab gitlab/gitlab --namespace gitlab \
  --set global.hosts.domain=gitlab-ce.example.com \
  --set global.hosts.externalIP=application-load-balancer-616514798.ap-southeast-1.elb.amazonaws.com \
  --set certmanager-issuer.email=quang.hong.0991@gmail.com \
  --set postgresql.persistence.size=10Gi \
  --set redis.persistence.size=10Gi \
  --set gitlab-runner.runners.cache.cacheType=s3 \
  --set gitlab-runner.runners.cache.s3ServerAddress=s3.ap-southeast-1.amazonaws.com \
  --set gitlab-runner.runners.cache.bucketName=s3-quangch-storage-files-data \
  --set gitlab-runner.runners.cache.bucketLocation=ap-southeast-1

helm upgrade --install gitlab gitlab/gitlab \
  -n gitlab \
  -f values.yaml



# 4. Xem logs alb controller pod:

kubectl -n kube-system logs -l app.kubernetes.io/instance=aws-load-balancer-controller --tail=100

# 5. Set up helm gitlab 

# 1. Scale down StatefulSet
kubectl scale statefulset gitlab-postgresql -n gitlab --replicas=0

# 2. Xóa StatefulSet (PVCs sẽ được giữ lại)
kubectl delete statefulset  gitlab-postgresql -n gitlab

# 3. Upgrade lại Helm release


helm upgrade gitlab gitlab/gitlab -f values.yaml -n gitlab

helm upgrade --install gitlab gitlab/gitlab -n gitlab -f helm-install/gitlab/values.yaml

# 4. get password gitlab
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -ojsonpath='{.data.password}' | base64 --decode ; echo

kubectl get secret gitlab-wildcard-tls-ca -ojsonpath='{.data.cfssl_ca}' | base64 --decode > gitlab.example.com.ca.pem

user: root
password: If9i0ujEf50zcbbg05Hk5z5wSOBFWuvFt5ePuneWuU7BaeCaJQgkrnrGlYkL5KqB
token-root: glpat-LJ0M7toCewky3GNuhVUxPW86MQp1OjEH.01.0w1qkh02b
token-admin-quangch-user: 



# Lấy tên pod webservice
WEBSERVICE_POD=$(kubectl -n gitlab get pods -l app=webservice -o jsonpath='{.items[0].metadata.name}')
# Truy cập vào container
kubectl -n gitlab exec -it $WEBSERVICE_POD -- bash


#. 3. Xóa hàng loạt tất cả Ingress finalizers trong namespace

kubectl get ingress -n gitlab -o name | xargs -I {} kubectl patch {} -n gitlab --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

kubectl get ingress -n monitoring -o name | xargs -I {} kubectl patch {} -n monitoring --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'


# 2. Xóa Finalizers trong CRD
 #   - group.ingress.k8s.aws/alb-apps

kubectl get crd | grep 'alb-apps'

kubectl patch crd targetgroupbindings.elbv2.k8s.aws  --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

kubectl delete crd certificaterequests.cert-manager.io certificates.cert-manager.io targetgroupbindings.elbv2.k8s.aws