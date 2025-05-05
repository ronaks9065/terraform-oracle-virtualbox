# Terraform Oracle VirtualBox

This repository provides Terraform configurations to automate the provisioning of VirtualBox virtual machines (VMs) on your local machine. It's ideal for developers and DevOps engineers aiming to create reproducible local environments for testing and development.

## Features

-  Provision VMs using the terra-farm/virtualbox Terraform provider.

- Customizable VM specifications: CPU, memory, disk size, and network configurations.

- Integration with Ansible for post-provisioning configuration management.

- Parameterization through terraform.tfvars for flexible deployments.

## Project Structure

```
├── ansible
│   ├── ansible.cfg
│   ├── inventory
│   │   └── hosts
│   └── playbooks
│       ├── files
│       │   ├── config.sh
│       │   └── kubeadm.sh
│       └── k8s_setup.yml
├── main.tf
├── provider.tf
├── terraform.tfstate
├── terraform.tfstate.backup
├── terraform.tfvars
├── variables.tf
└── virtualbox.box
```

## Terraform Execution Steps

Follow the steps below to provision your VirtualBox VM using Terraform:

### 1. Clone the Repository

```bash
git clone https://github.com/ronaks9065/terraform-oracle-virtualbox.git
cd terraform-oracle-virtualbox
```

### 2. Initialize Terraform

This will download the required provider plugins.

```bash
terraform init
```

### 4. Validate the Configuration

Ensure the configuration is syntactically valid.

```bash
terraform validate
```

### 5. Preview the Execution Plan

See what Terraform will do before making changes:

```bash
terraform plan
```

### 6. Apply the Configuration

This will create the VirtualBox VM as defined in your .tf files:

```bash
terraform apply --auto-approve
```

### 7. (Optional) Destroy the VM

When you're done, you can destroy the VM to clean up:

```bash
terraform destroy
```
