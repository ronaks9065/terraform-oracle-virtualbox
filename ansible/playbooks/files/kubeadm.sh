#!/bin/bash

source /tmp/config.sh

exec > >(tee -a $LOG_FILE) 2>&1

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Function to check and install pre-requisite software
pre_install_software() {
    echo "Checking and installing pre-requisite software..."

    software_list=("git" "curl" "apt-transport-https")

    for software in "${software_list[@]}"; do
        if ! command -v $software &> /dev/null; then
            echo "$software is not installed. Installing..."
            if [[ $os == "ubuntu" || $os == "debian" ]]; then
                sudo apt-get install -y $software
            elif [[ $os == "centos" || $os == "rhel" ]]; then
                sudo yum install -y $software
            elif [[ $os == "fedora" ]]; then
                sudo dnf install -y $software
            fi
        else
            echo "$software is already installed. Skipping..."
        fi
    done
    echo "Pre-requisite software installation check completed."
}

# Automatically create database directories
setup_database_directories() {
    echo "Setting up database directories..."
    
    # For MongoDB
    sudo mkdir -p /mnt/data/mongodb
    sudo chmod 777 /mnt/data/mongodb
    
    # For MySQL
    sudo mkdir -p /mnt/data/mysql
    sudo chmod 777 /mnt/data/mysql
    
    # For Neo4j
    sudo mkdir -p /mnt/data/neo4j/data
    sudo mkdir -p /mnt/data/neo4j/logs
    sudo chmod -R 777 /mnt/data/neo4j
    
    echo "Database directories created successfully."
}

# Function to update node name in YAML files
update_node_names() {
    echo "Updating node names in YAML files..."
    
    # Get the current node name
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$NODE_NAME" ]]; then
        echo "Warning: Could not detect node name automatically."
        return 1
    fi
    
    echo "Detected node name: $NODE_NAME"
    
    cd thryvo-manifests || return 1
    
    # Replace placeholder with actual node name in all YAML files
    find . -name "*.yaml" -type f -exec sed -i "s/YOUR_NODE_NAME/$NODE_NAME/g" {} \;
    
    echo "Node name updated in YAML files."
    cd ..
}

# Function to generate self-signed certificate if not exists
generate_self_signed_certificate() {
    if [[ -f "$CERTIFICATE" && -f "$PRIVATE_RSA_KEY" ]]; then
        echo "Self-signed certificate already exists. Skipping generation."
        return
    fi

    echo "Generating self-signed certificate..."
    sudo apt install -y openssl
    openssl genpkey -algorithm RSA -out $PRIVATE_KEY -pkeyopt rsa_keygen_bits:2048
    openssl req -new -key $PRIVATE_KEY -out "$CERT_DIR/request.csr" -subj "/C=IN/ST=Gujarat/L=Ahmedabad/O=CAXSOLPVTLTD/OU=IT/CN=ronak.prajapati@caxsol.com"
    openssl x509 -req -days 365 -in "$CERT_DIR/request.csr" -signkey $PRIVATE_KEY -out $CERTIFICATE
    openssl pkcs8 -topk8 -inform PEM -outform PEM -in $PRIVATE_KEY -out $PRIVATE_RSA_KEY -nocrypt

    kubectl get secret nginx-selfsigned-cert -n default &>/dev/null
    if [[ $? -ne 0 ]]; then
        kubectl create secret tls nginx-selfsigned-cert --cert=$CERTIFICATE --key=$PRIVATE_RSA_KEY -n default
        echo "Kubernetes secret created successfully."
    else
        echo "Kubernetes secret already exists. Skipping creation."
    fi
}

# Function to configure Azure CLI
configure_azure_cli() {
    echo "Configuring Azure CLI..."

    # Check if Azure CLI is installed
    if ! command -v az &> /dev/null; then
        echo "Azure CLI is not installed. Installing..."
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    fi

    # Login to Azure using interactive login
    az login || {
        echo "Interactive login failed. Please verify Azure CLI is installed correctly."
        return 1
    }

    echo "Azure CLI configured successfully."
}

# Function to create Docker registry secret for ACR
create_acr_secret() {
    echo "Creating/updating Docker registry secret for ACR..."
    
    # Prompt for ACR info if not provided
    if [[ -z "$ACR_NAME" || -z "$ACR_RESOURCE_GROUP" ]]; then
        read -p "Enter Azure Container Registry name: " ACR_NAME
        read -p "Enter Resource Group for ACR: " ACR_RESOURCE_GROUP
    fi
    
    # Get ACR credentials
    ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $ACR_RESOURCE_GROUP --query loginServer --output tsv 2>/dev/null)
    
    if [[ -z "$ACR_LOGIN_SERVER" ]]; then
        echo "Could not retrieve ACR login server. Checking available ACRs..."
        az acr list --output table
        read -p "Enter complete ACR login server URL: " ACR_LOGIN_SERVER
    fi
    
    # Get credentials using admin access
    echo "Getting ACR credentials..."
    az acr update --name $ACR_NAME --admin-enabled true
    ACR_USERNAME=$(az acr credential show --name $ACR_NAME --resource-group $ACR_RESOURCE_GROUP --query username --output tsv)
    ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --resource-group $ACR_RESOURCE_GROUP --query passwords[0].value --output tsv)
    
    if [[ -z "$ACR_USERNAME" || -z "$ACR_PASSWORD" ]]; then
        echo "Could not retrieve automatic credentials. Please enter them manually:"
        read -p "Enter ACR username: " ACR_USERNAME
        read -sp "Enter ACR password: " ACR_PASSWORD
        echo
    fi
    
    echo "Creating Kubernetes secret with ACR credentials..."
    
    # Check if secret already exists
    if kubectl get secret thryvo-secret -n default &>/dev/null; then
        echo "Secret 'thryvo-secret' already exists. Deleting and recreating..."
        kubectl delete secret thryvo-secret -n default
    fi

    # Create the secret
    kubectl create secret docker-registry thryvo-secret \
        --docker-server="$ACR_LOGIN_SERVER" \
        --docker-username="$ACR_USERNAME" \
        --docker-password="$ACR_PASSWORD" \
        --namespace default
    
    if [[ $? -eq 0 ]]; then
        echo "ACR secret created successfully."
        return 0
    else
        echo "Failed to create ACR secret. Retrying with fallback method..."
        # Alternative: Generate docker config json directly
        kubectl create secret generic thryvo-secret \
            --from-literal=.dockerconfigjson="{\"auths\":{\"$ACR_LOGIN_SERVER\":{\"username\":\"$ACR_USERNAME\",\"password\":\"$ACR_PASSWORD\",\"auth\":\"$(echo -n $ACR_USERNAME:$ACR_PASSWORD | base64)\"}}}" \
            --type=kubernetes.io/dockerconfigjson \
            --namespace default
        
        if [[ $? -eq 0 ]]; then
            echo "ACR secret created successfully using fallback method."
            return 0
        else
            echo "All attempts to create ACR secret failed. Please verify Azure credentials and permissions."
            return 1
        fi
    fi
}

# Function to verify kubeadm installation
verify_kubeadm_installation() {
    if kubectl get nodes &>/dev/null; then
        echo "Kubernetes is already installed. Skipping installation."
        return 0
    else
        echo "Kubernetes not found. Proceeding with installation."
        return 1
    fi
}

# Function to clone the repo and deploy the YAML
deploy_application() {
  # Clone repository if not already cloned
  if [[ -d thryvo-manifests ]]; then
    echo "Repository already cloned. Pulling latest changes..."
    cd thryvo-manifests
    git pull || { echo "Failed to pull latest changes. Continuing with existing files..."; }
    cd ..
  else
    echo "Cloning repository..."
    git clone $REPO_URL thryvo-manifests || { echo "Failed to clone repository. Exiting..."; exit 1; }
  fi

  # Update node names in YAML files
  update_node_names

  cd thryvo-manifests

  # Deploy each application in the list
  for YAML_FILE in "${DEPLOYMENT_PATHS[@]}"; do
    echo "Processing deployment file: $YAML_FILE"

    # Skip if the file doesn't exist
    if [[ ! -f "$YAML_FILE" ]]; then
      echo "Warning: $YAML_FILE not found. Skipping..."
      continue
    fi

    # Check if specific deployment exists
    DEPLOYMENT_NAME=$(grep -m 1 "name:" "$YAML_FILE" | awk '{print $2}')

    if [[ -z "$DEPLOYMENT_NAME" ]]; then
      echo "Warning: Could not find deployment name in $YAML_FILE. Skipping..."
      continue
    fi

    echo "Found deployment: $DEPLOYMENT_NAME"

    if sudo kubectl get deployment "$DEPLOYMENT_NAME" -n default &>/dev/null; then
      echo "Deployment $DEPLOYMENT_NAME already exists. Updating..."
      sudo kubectl apply -f "$YAML_FILE" || { echo "Failed to update deployment $DEPLOYMENT_NAME. Continuing..."; }
      echo "Deployment $DEPLOYMENT_NAME updated successfully."
    else
      echo "Deploying $DEPLOYMENT_NAME..."
      sudo kubectl apply -f "$YAML_FILE" || { echo "Failed to apply deployment $DEPLOYMENT_NAME. Continuing..."; }
      echo "Deployment $DEPLOYMENT_NAME deployed successfully."
    fi
  done

  echo "All deployments processed."

  # Return to original directory
  cd ..
}

# Function to install Kubernetes with kubeadm on Ubuntu/Debian
install_kubeadm_ubuntu() {
    pre_install_software
    setup_database_directories

    if ! verify_kubeadm_installation; then
        echo "Installing containerd..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install containerd.io -y

        # Configure containerd
        sudo mkdir -p /etc/containerd
        sudo containerd config default | sudo tee /etc/containerd/config.toml
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        sudo systemctl restart containerd

        # Install Kubernetes components
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
        sudo apt-get update
        sudo apt-get install -y kubeadm kubelet kubectl kubernetes-cni

        # Disable swap
        sudo swapoff -a
        sudo sed -i '/swap/d' /etc/fstab

        # Enable kernel modules and adjust sysctl settings
        sudo modprobe br_netfilter
        sudo sysctl -w net.ipv4.ip_forward=1

        # Initialize the Kubernetes cluster
        sudo kubeadm init --pod-network-cidr=10.244.0.0/16

        # Setup kubeconfig for current user
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config

        # Allow pods to run on the master node (for single node setup)
        kubectl taint nodes --all node-role.kubernetes.io/control-plane-

        # Install Flannel as the pod network
        kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.20.2/Documentation/kube-flannel.yml

        echo "Waiting for nodes to be ready..."
        sleep 30
    fi

    generate_self_signed_certificate
    # configure_azure_cli
    # create_acr_secret
    # deploy_application
}

# Function to install Kubernetes with kubeadm on CentOS/RHEL
install_kubeadm_centos() {
    pre_install_software
    setup_database_directories

    if ! verify_kubeadm_installation; then
        echo "Installing containerd..."
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y containerd.io

        # Configure containerd
        sudo mkdir -p /etc/containerd
        sudo containerd config default | sudo tee /etc/containerd/config.toml
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        sudo systemctl restart containerd

        # Set up Kubernetes repo
        cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF

        # Install Kubernetes components
        sudo yum install -y kubelet kubeadm kubectl kubernetes-cni
        sudo systemctl enable kubelet

        # Disable swap
        sudo swapoff -a
        sudo sed -i '/swap/d' /etc/fstab

        # Enable kernel modules and adjust sysctl settings
        sudo modprobe br_netfilter
        sudo sysctl -w net.ipv4.ip_forward=1

        # Initialize the Kubernetes cluster
        sudo kubeadm init --pod-network-cidr=10.244.0.0/16

        # Setup kubeconfig for current user
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config

        # Allow pods to run on the master node (for single node setup)
        kubectl taint nodes --all node-role.kubernetes.io/control-plane-

        # Install Flannel as the pod network
        kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.20.2/Documentation/kube-flannel.yml

        echo "Waiting for nodes to be ready..."
        sleep 30
    fi

    generate_self_signed_certificate
    configure_azure_cli
    create_acr_secret
    deploy_application
}

# Function to install Kubernetes with kubeadm on Fedora
install_kubeadm_fedora() {
    pre_install_software
    setup_database_directories

    if ! verify_kubeadm_installation; then
        echo "Installing containerd..."
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf install -y containerd.io

        # Configure containerd
        sudo mkdir -p /etc/containerd
        sudo containerd config default | sudo tee /etc/containerd/config.toml
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        sudo systemctl restart containerd

        # Set up Kubernetes repo
        cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF

        # Install Kubernetes components
        sudo dnf install -y kubelet kubeadm kubectl kubernetes-cni
        sudo systemctl enable kubelet

        # Disable swap
        sudo swapoff -a
        sudo sed -i '/swap/d' /etc/fstab

        # Enable kernel modules and adjust sysctl settings
        sudo modprobe br_netfilter
        sudo sysctl -w net.ipv4.ip_forward=1

        # Initialize the Kubernetes cluster
        sudo kubeadm init --pod-network-cidr=10.244.0.0/16

        # Setup kubeconfig for current user
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config

        # Allow pods to run on the master node (for single node setup)
        kubectl taint nodes --all node-role.kubernetes.io/control-plane-

        # Install Flannel as the pod network
        kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.20.2/Documentation/kube-flannel.yml

        echo "Waiting for nodes to be ready..."
        sleep 30
    fi

    generate_self_signed_certificate
    configure_azure_cli
    create_acr_secret
    deploy_application
}

# Auto-detect OS
os=$(grep '^ID=' /etc/os-release | awk -F= '{print $2}' | tr -d '"')
case $os in
    ubuntu|debian)
        install_kubeadm_ubuntu
        ;;
    centos|rhel)
        install_kubeadm_centos
        ;;
    fedora)
        install_kubeadm_fedora
        ;;
    *)
        echo "Unsupported operating system: $os"
        exit 1
        ;;
esac

echo "Kubernetes cluster installation and configuration completed successfully."
echo "Verify the cluster status:"
kubectl get nodes
echo "Verify deployed applications:"
kubectl get pods -A
