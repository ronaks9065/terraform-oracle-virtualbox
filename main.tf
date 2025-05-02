resource "virtualbox_vm" "node" {
  count     = 1
  name      = "RP"
  image     = var.image_path
  cpus      = 2
  memory    = "1024 mib"
  
  network_adapter {
    type          = "bridged"
    host_interface = "enp5s0"
  }
}

output "IPAddr" {
  value = length(virtualbox_vm.node) > 0 ? virtualbox_vm.node[0].network_adapter[0].ipv4_address : ""
  description = "The IP address of the first VM"
}