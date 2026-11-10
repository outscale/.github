#!/bin/bash
set -ex

# Management access (= OKS cluster)
octl profile rm management || /bin/true
octl profile add management --ak $OKS_ACCESS_KEY --sk $OKS_SECRET_KEY --region $OKS_REGION


# OKS kubeconfig
kubeconfig="$GITHUB_WORKSPACE/management.kubeconfig"
touch $kubeconfig
chmod 600 $kubeconfig
octl kube cluster kubeconfig management --profile management > $kubeconfig
export KUBECONFIG=$kubeconfig

# install API+CAPOSC
clusterctl init -i outscale || clusterctl upgrade apply --contract v1beta1

# build management cluster manifest
export OSC_SUBREGION_NAME=${OSC_REGION}a
ip=`curl -s -S --retry 5 --retry-all-errors https://api.ipify.org`
export OSC_ALLOW_FROM="$ip/32"
mip=`kubectl get nodes -o custom-columns=IP:.metadata.labels.public-ip --no-headers=true`
# mip=`kubectl run --image curlimages/curl:8.14.1 getip --restart=Never -ti --rm -q -- curl -s -S --retry 5 --retry-all-errors https://api.ipify.org`
export OSC_ALLOW_FROM_CAPI="$mip/32"
export OSC_NAT_IP_POOL=caposc
export KUBERNETES_VERSION=`echo $OSC_IMAGE_NAME|sed 's/.*\(v1[.0-9]*\).*/\1/'`
if [ -z "$WORKER_COUNT" ]; then
  WORKER_COUNT=1
fi

clusterctl generate cluster $OSC_CLUSTER_NAME --kubernetes-version $KUBERNETES_VERSION --control-plane-machine-count=1 --worker-machine-count=$WORKER_COUNT -n $OSC_CLUSTER_NAME --from $ACTION_PATH/cluster-template.yaml > clusterapi.yaml
# clusterctl generate cluster $OSC_CLUSTER_NAME --kubernetes-version $KUBERNETES_VERSION --control-plane-machine-count=1 --worker-machine-count=$WORKER_COUNT -n $OSC_CLUSTER_NAME -i outscale --flavor secure-opensource > clusterapi.yaml

kubectl create ns $OSC_CLUSTER_NAME || /bin/true
# CAPOSC credentials to build workload cluster
octl kube secret --name credentials --namespace $OSC_CLUSTER_NAME | kubectl apply -f -
# Cleanup old clusters
# Avoid deleting the namespace, the credentials will be deleted, preventing CAPOSC to run properly
kubectl delete cluster.cluster.x-k8s.io --all -n $OSC_CLUSTER_NAME

if [ -n "$KUSTOMIZE_PATH" ]; then
  mv clusterapi.yaml $GITHUB_WORKSPACE/$KUSTOMIZE_PATH
  kubectl apply -k $GITHUB_WORKSPACE/$KUSTOMIZE_PATH
else
  kubectl apply -f clusterapi.yaml
fi

# This can be removed once v1.0.0-alpha.3 is released and it is deployed on the CI.
# kubectl patch osccluster $OSC_CLUSTER_NAME -n $OSC_CLUSTER_NAME --type='merge' -p \
#   '{"spec":{"network":{"additionalSecurityRules":[{"roles":["worker"], "rules":[{"flow":"Inbound", "ipRange":"10.0.4.0/24", "fromPortRange":-1, "toPortRange": -1, "ipProtocol": "4"}]}]}}}'

for i in {1..10}; do
sleep 30
kubectl get -n $OSC_CLUSTER_NAME machine.cluster.x-k8s.io
kubectl get -n $OSC_CLUSTER_NAME kubeadmcontrolplane.controlplane.cluster.x-k8s.io
done
echo "waiting for control plane"
kubectl wait -n $OSC_CLUSTER_NAME --timeout=900s \
  --for=jsonpath='{.status.initialized}' kubeadmcontrolplane.controlplane.cluster.x-k8s.io/$OSC_CLUSTER_NAME-control-plane

# fetch kubeconfig
kubeconfig="$GITHUB_WORKSPACE/workload.kubeconfig"
touch $kubeconfig
chmod 600 $kubeconfig
clusterctl get kubeconfig $OSC_CLUSTER_NAME --namespace $OSC_CLUSTER_NAME > $kubeconfig
# switch to workload cluster
export KUBECONFIG=$kubeconfig

# install calico
kubectl \
  apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml

echo "waiting for nodes"
for i in {1..50}; do
  cnt=`kubectl get nodes --no-headers | tee /dev/stderr | wc -l`
  if [[ $cnt -ge 2 ]]; then
    break
  fi
  sleep 30
done

if [ "$CCM" = "true" ]; then
  KUBE_MAJORMINOR=`echo $KUBERNETES_VERSION|cut -d . -f 1,2`
  CCM_VERSION=$KUBE_MAJORMINOR.9
  echo "installing CCM $CCM_VERSION"
  octl kube secret --name osc-secret | kubectl apply -f -
  helm install --wait k8s-osc-ccm oci://registry-1.docker.io/outscalehelm/osc-cloud-controller-manager --set oscSecretName=osc-secret \
    --set image.tag=$CCM_VERSION
  echo "waiting for nodes"
  kubectl wait --for=condition=Ready nodes --all --timeout=900s
  kubectl get nodes -o wide
  echo "restarting pods"
  kubectl get po -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTNETWORK:.spec.hostNetwork --no-headers=true | grep '<none>' | awk '{print "-n "$1" "$2}' | xargs -L 1 -r kubectl delete pod
  echo "waiting for pods"
  kubectl wait --for=condition=Ready po --all -A --timeout=900s
  kubectl get po -A
fi

if [ "$CERT_MANAGER" = "true" ]; then
  echo "installing cert-manager"
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install \
    cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.21.2 \
    --set crds.enabled=true \
    --set prometheus.enabled=false \
    --set webhook.timeoutSeconds=4 \
    --set "webhook.nodeSelector.node-role\.kubernetes\.io/control-plane=" \
    --set "webhook.tolerations[0].key=node-role.kubernetes.io/control-plane" \
    --set "webhook.tolerations[0].operator=Exists" \
    --set "webhook.tolerations[0].effect=NoSchedule"
fi
