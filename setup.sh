#!/bin/bash

IP=
LB_IP_POOL=

cd ~

# disable firewall
sudo systemctl stop ufw
sudo systemctl disable ufw

# prevent auto upgrade
sudo sed -i 's/1/0/g' /etc/apt/apt.conf.d/20auto-upgrades

# install basic packages
sudo apt install -y net-tools nfs-common whois

# network configuration
sudo modprobe overlay \
    && sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

# install containerd
sudo apt-get update

sudo apt-get install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update \
    && sudo apt-get install -y containerd.io

sudo mkdir -p /etc/containerd \
    && sudo containerd config default | sudo tee /etc/containerd/config.toml

# ssh configuration
ssh-keygen -t rsa

ssh-copy-id -i ~/.ssh/id_rsa ${USER}@${IP}

# k8s installation via kubespray
sudo apt install -y python3-pip
git clone -b release-2.19 https://github.com/kubernetes-sigs/kubespray.git
cd kubespray
pip install -r requirements.txt

echo "export PATH=${HOME}/.local/bin:${PATH}" | sudo tee ${HOME}/.bashrc > /dev/null
source ${HOME}/.bashrc

cp -rfp inventory/sample inventory/mycluster
declare -a IPS=(${IP})
CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}

ansible-playbook -i inventory/mycluster/hosts.yaml  --become --become-user=root cluster.yml -K
cd ~

# enable kubectl in admin account and root
mkdir -p ${HOME}/.kube
sudo cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
sudo chown ${USER}:${USER} ${HOME}/.kube/config

# enable kubectl & kubeadm auto-completion
echo "source <(kubectl completion bash)" >> ${HOME}/.bashrc
echo "source <(kubeadm completion bash)" >> ${HOME}/.bashrc

echo "source <(kubectl completion bash)" | sudo tee -a /root/.bashrc
echo "source <(kubeadm completion bash)" | sudo tee -a /root/.bashrc

# install nvidia-container-toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
    && curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add - \
    && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update \
    && sudo apt-get install -y nvidia-container-toolkit

sudo mv ~/xiilab/config.toml /etc/containerd/
sudo systemctl restart containerd

# install helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# install rook ceph
git clone https://github.com/rook/rook.git 
helm repo add rook-release https://charts.rook.io/release
helm search repo rook-ceph
kubectl create namespace rook-ceph
helm install --namespace rook-ceph rook-ceph rook-release/rook-ceph
sleep 60

# enable toolbox
sed -i "26s/false/true/g" ~/rook/deploy/charts/rook-ceph-cluster/values.yaml
# reduce monitor daemon from 3 to 1
sed -i "s/count: 3/count: 1/g" ~/rook/deploy/charts/rook-ceph-cluster/values.yaml
# reduce manager daemon from 3 to 1
sed -i "s/count: 2/count: 1/g" ~/rook/deploy/charts/rook-ceph-cluster/values.yaml
# reduce cephBlock datapoolsize from 3 to 2
# reduce cephFilesystem metadata pool size from 3 to 2
# reduce cephFilesystem data pool size from 3 to 2
sed -i "s/size: 3/size: 2/g" ~/rook/deploy/charts/rook-ceph-cluster/values.yaml

#--- install rook ceph cluster
cd ~/rook/deploy/charts/rook-ceph-cluster
helm install -n rook-ceph rook-ceph-cluster --set operatorNamespace=rook-ceph rook-release/rook-ceph-cluster -f values.yaml
cd ~
sleep 60

# install helmfile
wget https://github.com/helmfile/helmfile/releases/download/v0.150.0/helmfile_0.150.0_linux_amd64.tar.gz
tar -zxvf helmfile_0.150.0_linux_amd64.tar.gz
sudo mv helmfile /usr/bin/
rm LICENSE && rm README.md && rm helmfile_0.150.0_linux_amd64.tar.gz

# deploy uyuni infra
git clone https://github.com/xiilab/Uyuni_Deploy.git
cd ~/Uyuni_Deploy/environments
cp -r default itmaya
sed -i "s/default.com/${IP}/gi" itmaya/values.yaml
sed -i "s/192.168.1.210/${IP}/gi" itmaya/values.yaml
sed -i "s/192.168.56.20-192.168.56.50/${LB_IP_POOL}/gi" itmaya/values.yaml
cd ~/Uyuni_Deploy
helmfile --environment itmaya -l type=base sync
cd ~

# set ceph-filesystem as default storageclass
#kubectl patch storageclass nfs-client -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
#kubectl patch storageclass ceph-block -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
#kubectl patch storageclass ceph-bucket -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
#kubectl patch storageclass ceph-filesystem -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# deploy uyuni suite
git clone https://github.com/xiilab/Uyuni_Kustomize.git
