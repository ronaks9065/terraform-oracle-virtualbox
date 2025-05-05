resource "virtualbox_vm" "node" {
  count  = 1
  name   = "RP"
  image  = var.image_path
  cpus   = 4
  memory = "8192 mib"

  network_adapter {
    type           = "bridged"
    host_interface = "enp5s0"
  }

  # Add SSH configuration for provisioner access
  provisioner "file" {
    source      = "~/.ssh/id_ed25519.pub"
    destination = "/tmp/id_ed25519.pub"

    connection {
      type        = "ssh"
      user        = "vagrant"
      private_key = file("~/.vagrant.d/insecure_private_key") # Default Vagrant private key
      host        = self.network_adapter[0].ipv4_address
    }
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ~/.ssh",
      "cat /tmp/id_ed25519.pub >> ~/.ssh/authorized_keys",
      "chmod 600 ~/.ssh/authorized_keys"
    ]

    connection {
      type        = "ssh"
      user        = "vagrant"
      private_key = file("~/.vagrant.d/insecure_private_key")
      host        = self.network_adapter[0].ipv4_address
    }
  }

  # Second provisioner to create ubuntu user and install basic software
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo useradd -m -s /bin/bash ubuntu",
      "echo 'ubuntu:ubuntu123' | sudo chpasswd",
      "sudo usermod -aG sudo ubuntu",
      "sudo mkdir -p /home/ubuntu/.ssh",
      "sudo cp ~/.ssh/authorized_keys /home/ubuntu/.ssh/",
      "sudo chown -R ubuntu:ubuntu /home/ubuntu/.ssh",
      "sudo chmod 700 /home/ubuntu/.ssh",
      "sudo chmod 600 /home/ubuntu/.ssh/authorized_keys",
      "sudo apt-get install -y curl wget git vim htop net-tools unzip ansible",
      "sudo apt-get install -y python3 python3-pip",
      "sudo apt-get install -y docker.io",
      "sudo systemctl enable docker",
      "sudo usermod -aG docker ubuntu",
      "echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/ubuntu",
      "sudo chmod 440 /etc/sudoers.d/ubuntu"
    ]
    connection {
      type        = "ssh"
      user        = "vagrant"
      private_key = file("~/.vagrant.d/insecure_private_key")
      host        = self.network_adapter[0].ipv4_address
    }
  }

  # After VM is provisioned and ubuntu user created, run local provisioner to generate inventory
  provisioner "local-exec" {
    command = <<-EOT
      # Create Ansible inventory directory if it doesn't exist
      mkdir -p ansible/inventory
      
      # Generate inventory file with dynamic IP
      cat > ansible/inventory/hosts <<EOF
[k8s_node]
${self.network_adapter[0].ipv4_address} ansible_user=ubuntu ansible_ssh_private_key_file=/home/ubuntu/.ssh/id_ed25519 ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
      
      # Create ansible.cfg file to disable host key checking
      cat > ansible/ansible.cfg <<EOF
[defaults]
host_key_checking = False
EOF
      
      # Create playbook directory if it doesn't exist
      mkdir -p ansible/playbooks/files
      
      # Generate playbook file with proper indentation
      cat > ansible/playbooks/k8s_setup.yml <<EOF
---
- name: Run Kubernetes and App Setup Scripts
  hosts: k8s_node
  tasks:
    - name: Copy kubeadm.sh to remote host
      copy:
        src: files/kubeadm.sh
        dest: /tmp/kubeadm.sh
        mode: '0755'
    - name: Copy config.sh to remote host
      copy:
        src: files/config.sh
        dest: /tmp/config.sh
        mode: '0755'
    - name: Execute k8s setup script
      shell: /tmp/kubeadm.sh
      become: true
    - name: Set up kubeconfig for the current user
      shell: |
        mkdir -p $HOME/.kube
        cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        chown $(id -u):$(id -g) $HOME/.kube/config
      become: true
EOF
      
      # First remove any existing host key to avoid the "host key has changed" error
      ssh-keygen -f ~/.ssh/known_hosts -R "${self.network_adapter[0].ipv4_address}" || true
      
      # Run the Ansible playbook with the correct path and disable host key checking
      cd ansible && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory/hosts playbooks/k8s_setup.yml -v
    EOT
  }
}

output "IPAddr" {
  value       = length(virtualbox_vm.node) > 0 ? virtualbox_vm.node[0].network_adapter[0].ipv4_address : ""
  description = "The IP address of the first VM"
}