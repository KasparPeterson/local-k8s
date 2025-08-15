sudo swapoff -a

# Stop and disable Docker if running (conflicts with containerd)
sudo systemctl stop docker
sudo systemctl stop docker.socket
sudo systemctl disable docker
sudo systemctl disable docker.socket

echo "kubeadm reset..."
sudo kubeadm reset -f --cleanup-tmp-dir --cri-socket=unix:///run/containerd/containerd.sock
rm -rf $HOME/.kube

# More thorough cleanup before reset
sudo systemctl stop kubelet
sudo systemctl stop containerd

sleep 10

# Unmount any remaining kubelet volumes (should be fewer now)
sudo umount /var/lib/kubelet/pods/*/volumes/*/* 2>/dev/null || true
sudo umount /var/lib/kubelet/pods/*/volumes/* 2>/dev/null || true

# Clean up Calico and CNI remnants
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/lib/kubelet/* 2>/dev/null || true
sudo rm -rf /etc/cni/
sudo rm -rf /opt/cni/bin/calico*
sudo rm -rf /var/lib/calico/

# Remove any lingering network interfaces
sudo ip link del cni0 2>/dev/null || true
sudo ip link del tunl0 2>/dev/null || true
sudo ip link del vxlan.calico 2>/dev/null || true
for iface in $(ip link show | grep cali | cut -d: -f2 | tr -d ' '); do
    sudo ip link del $iface 2>/dev/null || true
done

sudo systemctl start containerd
sudo systemctl start kubelet

sleep 20

echo "calling kubeadm init..."
sudo kubeadm init \
  --apiserver-advertise-address 192.168.18.16 \
  --apiserver-bind-port 6443 \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket=unix:///run/containerd/containerd.sock
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "kubeadm init done:"
kubectl get pods -n kube-system
echo "get pods -A:"
kubectl get pods -A
echo "sleeping for 20..."
sleep 20
echo "sleep done:"
kubectl get pods -n kube-system
echo "get pods -A:"
kubectl get pods -A

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
kubectl create -f "custom-resources.yaml"

sleep 10

kubectl taint nodes --all node.kubernetes.io/not-ready-
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

for i in {1..20}; do
    echo ""
    echo "Pods after calico - Iteration $i"
    kubectl get pods -A
    echo "get nodes-o wide:"
    kubectl get nodes -o wide
    sleep 3
done


# After steps

# Deploy nginx-ingress
# see what changes would be made, returns nonzero returncode if different
#kubectl get configmap kube-proxy -n kube-system -o yaml | \
#  sed -e "s/strictARP: false/strictARP: true/" | \
#  kubectl diff -f - -n kube-system
#
# actually apply the changes, returns nonzero returncode on errors only
#kubectl get configmap kube-proxy -n kube-system -o yaml | \
#  sed -e "s/strictARP: false/strictARP: true/" | \
#  kubectl apply -f - -n kube-system

# install nginx-ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/cloud/deploy.yaml
sleep 20
kubectl apply -f ingress/nginx-ingress.yaml
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  -p '{"spec": {"externalTrafficPolicy": "Cluster"}}'
kubectl patch deployment ingress-nginx-controller -n ingress-nginx -p '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"ClusterIP"}}'


# Deploy nginx "app"
kubectl apply -f nginx/nginx-deploy.yaml
# NodePort - should remove after ingress?
kubectl apply -f nginx/nginx-svc.yaml


