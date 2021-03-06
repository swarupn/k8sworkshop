
#!/bin/bash

# Global env variables / defaults
KUBERNETES_VERSION=1.19.3
POD_NETWORK_CIDR="192.168.0.0/16"

# Functions library
os_type() {
        cat /etc/*-release | grep '^NAME' | tr -d 'NAME="'
}

exists() {
        if command -v $1 >/dev/null 2>&1; then
                echo "Command $1 installed"
        else
                echo "Please install $1"
                exit 1
        fi
}

running_as_root() {
        if [[ $EUID > 0 ]]; then
          echo "Please run as root/sudo"
          exit 1
        fi
}

# Swap space in Linux is used when the amount of physical memory (RAM) is full. 
# If the system needs more memory resources and the RAM is full, inactive pages in memory are moved to the swap space. 
# While swap space can help machines with a small amount of RAM, it should not be considered a replacement for more RAM. 
# Swap space is located on hard drives, which have a slower access time than physical memory.
# Function desc: Swap disabled. You MUST disable swap in order for the kubelet to work properly.
disable_swap() {
       swapoff -a
       sed -i '/ swap / s/^/#/' /etc/fstab
       echo "swap memeory disbaled"
}


# Function desc: Make cgroup manager as systemd for the containers        
config_docker_ubuntu() {
        cat << EOF > /etc/docker/daemon.json
{
        "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
        systemctl restart docker
}

# Make sure that the br_netfilter module is loaded. This can be done by running lsmod | grep br_netfilter. To load it explicitly call sudo modprobe br_netfilter.
# As a requirement for your Linux Node's iptables to correctly see bridged traffic, you should ensure net.bridge.bridge-nf-call-iptables is set to 1 in your sysctl config
config_netfilter() {
        echo "configuring netfilter"
        sudo modprobe br_netfilter
        cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
        br_netfilter
EOF

        cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
        net.bridge.bridge-nf-call-ip6tables = 1
        net.bridge.bridge-nf-call-iptables = 1
EOF
        sudo sysctl --system
}

# Some times for cnis firewalls may block some traffic. So it can be disabled other wise enable traffic for the port opened.
disable_firewall() {
        echo "disabling firewall"
        systemctl stop ufw
        systemctl disable ufw
}

#install k8s
package_ubuntu() {
        apt-get update && apt-get install -y apt-transport-https
        sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
        echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
        apt-get update
        apt-get install -y kubelet=$KUBERNETES_VERSION-00 kubeadm=$KUBERNETES_VERSION-00 kubectl=$KUBERNETES_VERSION-00
        sudo apt-mark hold kubelet kubeadm kubectl
}


Install_k8s() {
        # Phase 1  Some pre requisite test
        # 1. Are we running as root or sudo?
        running_as_root

        # 2. Docker exists?
        exists "docker"

        #3. Disable swap
        disable_swap
       
        #4. Disable firewall
        disable_firewall

        #5. Enable netfiler
        config_netfilter

        # Phase 2 - install kubernetes and kubeadm packages
        case "$(os_type)" in
                *Ubuntu*)
                        config_docker_ubuntu
                        package_ubuntu
                        ;;
                *)
                        fail
                        ;;
        esac


        # Phase 3 - initialize the Kubernetes cluster
        kubeadm init --pod-network-cidr=$POD_NETWORK_CIDR --kubernetes-version=$KUBERNETES_VERSION | tee kubeadm.log

        export KUBECONFIG=/etc/kubernetes/admin.conf
        
        # Remove master taints to make master schedulable for pods. Generaly master nodes are not suggested to scedule other pods, so by default it is tainted.
        kubectl taint nodes --all node-role.kubernetes.io/master-
        sleep 30
        # Install networking. Even in single-node mode, before the master node will become
        # available for scheduling (Ready), it should detect a network plugin configuration.
        #kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
        kubectl apply -f calico.yaml
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        # NOTE: Execute below three commands to use kubectl from other users.
        # mkdir -p $HOME/.kube
        # sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        # sudo chown -R $(id -u):$(id -g) /home/root1/.kube/config
}

Uninstall_k8s() {
        kubeadm reset -f
        sudo apt-mark unhold kubelet kubeadm kubectl
        systemctl stop kubelet.service
        systemctl disable kubelet.service

        sudo apt-get purge kubeadm kubectl kubelet kubernetes-cni -y
        sudo apt-get autoremove  -y
        rm -rf /etc/systemd/system/kubelet.service /etc/systemd/system/kubelet.service.d/
        sudo rm -rf ~/.kube
        sudo rm -rf /var/lib/etcd
        sudo rm -rf /etc/kubernetes/
        sudo rm -rf /etc/cni/net.d
        sudo rm -rf /opt/cni
        sudo rm -rf /var/lib/kubelet
        sudo iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
}

Help() {
        # Display Help
        echo "This script install and uninstall k8s on a Single Node"
        echo ""
        echo "Syntax: singlenode.sh [-i|r|h]"
        echo "options:"
        echo "h     Print this Help."
        echo "i     Install k8s."
        echo "r     Uninstall k8s."
        echo ""
}

############################################################
############################################################
# Main program                                             #
############################################################
############################################################
############################################################
# Process the input options. Add options as needed.        #
############################################################
# Get the options
while getopts ":irh" option; do
   case $option in
      h) # display Help
         Help
         exit;;
      i) # install k8s
         echo "Installing k8s"
         Install_k8s
         exit;;
      r) # uninstall k8s
         echo "Uninstalling k8s"
         Uninstall_k8s
         exit;;
      \?) # Invalid option
         echo "Error: Invalid option"
         exit;;
   esac
done
