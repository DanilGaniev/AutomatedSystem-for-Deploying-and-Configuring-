packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_api_url" {
  type    = string
  default = "https://192.168.0.107:8006/api2/json"
}

variable "proxmox_api_token_id" {
  type    = string
  default = "terraform-user@pve!terraform-token" # Token ID
}

variable "proxmox_api_token_secret" {
  type      = string
  default   = "28100c72-cb3c-4d2a-aca9-44d26c47d0b4" # Токен Secret
  sensitive = true
}

source "proxmox-iso" "ubuntu-server" {
  proxmox_url = "${var.proxmox_api_url}"
  username    = "${var.proxmox_api_token_id}"
  token       = "${var.proxmox_api_token_secret}"
  node        = "proxmox"
  
  insecure_skip_tls_verify = true
  http_bind_address        = "192.168.0.110"
  http_directory           = "http"

  boot_iso {
    type         = "scsi"
    iso_file     = "local:iso/ubuntu-24.04.3-live-server-amd64.iso"
    unmount      = true
  }
  
  ssh_username = "dandi"
  ssh_password = "ubuntu"
  ssh_timeout  = "30m"

  vm_name      = "ubuntu-test"
  memory       = 3072
  cores        = 2
  sockets      = 1
  qemu_agent   = true
  
  network_adapters {
    model = "virtio"
    bridge = "vmbr0"
  }
  
  scsi_controller = "virtio-scsi-pci"
  
  disks {
    disk_size         = "10G"
    format            = "raw"
    storage_pool      = "local-lvm"
    type              = "virtio"
  }

  boot_wait = "15s"
  boot_command = [
    "<esc><wait>c<wait>",
    "linux /casper/vmlinuz autoinstall inst.georoute=nodefv4 cloud-config-url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/user-data ---",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot<enter>"
  ]
}

build {
  sources = ["source.proxmox-iso.ubuntu-server"]

  # Блок команд, которые Packer выполнит ПОСЛЕ установки ОС, зайдя по SSH
  provisioner "shell" {
    execute_command = "echo 'ubuntu' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    inline = [
      "set -e",

      # 1. Ждем окончания системной инициализации
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 1; done",

      # 2. Установка базовых утилит
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl gpg",
      "sudo mkdir -p -m 755 /etc/apt/keyrings",

      # 3. СТАБИЛЬНОЕ ЗЕРКАЛО ALIBABA (с правильными слэшами)
      "curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
      "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list",

      # 4. Быстрая установка пакетов
      "sudo apt-get update",
      "sudo apt-get install -y kubelet kubeadm kubectl containerd",
      "sudo apt-mark hold kubelet kubeadm kubectl",

      # 5. Настройка Containerd (CRI) под Systemd
      "sudo mkdir -p /etc/containerd",
      "containerd config default | sudo tee /etc/containerd/config.toml",
      "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml",
      "sudo systemctl restart containerd",

      # 6. Включение модулей ядра для сетевого моста K8s
      "cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf",
      "overlay",
      "br_netfilter",
      "EOF",
      "sudo modprobe overlay",
      "sudo modprobe br_netfilter",

      # 7. Системные сетевые параметры (sysctl)
      "cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf",
      "net.bridge.bridge-nf-call-iptables  = 1",
      "net.bridge.bridge-nf-call-ip6tables = 1",
      "net.ipv4.ip_forward                 = 1",
      "EOF",
      "sudo sysctl --system",

      "sudo cloud-init clean --logs",

      # 8. Очистка кэша
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*"
    ]
  }
}