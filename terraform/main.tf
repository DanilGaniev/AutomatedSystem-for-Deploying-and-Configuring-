locals {
  nodes = {
    "ansible-master" = { id = 119, ip = "192.168.0.119" } 
    "k8s-master"     = { id = 200, ip = "192.168.0.120" }
    "k8s-worker-1"   = { id = 201, ip = "192.168.0.121" }
    "k8s-worker-2"   = { id = 202, ip = "192.168.0.122" }
  }
}

# 1. ГЕНЕРАЦИЯ НОВОГО КЛЮЧА ПРИ КАЖДОМ РАЗВЕРТЫВАНИИ
resource "tls_private_key" "ssh_key" {
  algorithm = "ED25519"
}

# 2. Конфиг для ОБЫЧНЫХ нод (Добавили динамический hostname)
resource "proxmox_virtual_environment_file" "user_data_cloud_config" {
  for_each     = { for k, v in local.nodes : k => v if k != "ansible-master" }
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "proxmox"

  source_raw {
    data = <<EOF
#cloud-config
hostname: ${each.key}
fqdn: ${each.key}.local
users:
  - name: dandi
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    password: $6$cVp7nsfkKMyz6Waw$YfP1NfOnoGhgtQsA7pyYNO5K6dzulxp7snY8d7YlkMpHvTWm.XHtGrntzz1V79hjYoIpZBhTD64/yjmrkM/SS1
    ssh_authorized_keys:
      - ${tls_private_key.ssh_key.public_key_openssh}
EOF
    file_name = "config-${each.key}.yaml"
  }
}

# 3. Конфиг для Ansible-master
resource "proxmox_virtual_environment_file" "user_data_ansible_master" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "proxmox"

  source_raw {
    data = <<EOF
#cloud-config
hostname: ansible-master
fqdn: ansible-master.local
users:
  - name: dandi
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    password: $6$cVp7nsfkKMyz6Waw$YfP1NfOnoGhgtQsA7pyYNO5K6dzulxp7snY8d7YlkMpHvTWm.XHtGrntzz1V79hjYoIpZBhTD64/yjmrkM/SS1
    ssh_authorized_keys:
      - ${tls_private_key.ssh_key.public_key_openssh}

write_files:
  - path: /home/dandi/.ssh/id_ed25519
    owner: dandi:dandi
    permissions: '0600'
    defer: true
    content: |
      ${indent(6, tls_private_key.ssh_key.private_key_openssh)}

  - path: /home/dandi/.ssh/id_ed25519.pub
    owner: dandi:dandi
    permissions: '0644'
    defer: true
    content: |
      ${tls_private_key.ssh_key.public_key_openssh}

  - path: /home/dandi/hosts.ini
    owner: dandi:dandi
    permissions: '0644'
    defer: true
    content: |
      [ansible]
      ansible-master ansible_host=${local.nodes["ansible-master"].ip}

      [masters]
      k8s-master ansible_host=${local.nodes["k8s-master"].ip}

      [workers]
      k8s-worker-1 ansible_host=${local.nodes["k8s-worker-1"].ip}
      k8s-worker-2 ansible_host=${local.nodes["k8s-worker-2"].ip}

      [all:vars]
      ansible_user=dandi
      ansible_python_interpreter=/usr/bin/python3
      ansible_ssh_common_args='-o StrictHostKeyChecking=no'
      # Защита от таймаутов sudo при высокой нагрузке на Proxmox:
      ansible_become_timeout=60

runcmd:
  - [ chown, "-R", "dandi:dandi", "/home/dandi/.ssh", "/home/dandi/hosts.ini" ]
  - [ chmod, "700", "/home/dandi/.ssh" ]
  - [ chmod, "600", "/home/dandi/.ssh/id_ed25519" ]
  - apt-get update
  - apt-get install -y ansible git
  - su - dandi -c "git clone https://github.com/DanilGaniev/DiplomaProject.git /home/dandi/DiplomaProject"
EOF
    file_name = "ansible-master-config.yaml"
  }
}

# 4. СОЗДАНИЕ ВИРТУАЛЬНЫХ МАШИН
resource "proxmox_virtual_environment_vm" "k8s_cluster" {
  for_each  = local.nodes
  name      = each.key
  vm_id     = each.value.id
  node_name = "proxmox"

  clone {
    vm_id = 101
  }

  memory {
    dedicated = each.key == "ansible-master" ? 2536 : (length(regexall("worker", each.key)) > 0 ? 6144 : 4584)
  }

  cpu {
    cores = each.key == "ansible-master" ? 1 : (length(regexall("worker", each.key)) > 0 ? 2 : 2)
  }

  # ---- ДОБАВЛЯЕМ ЭТОТ БЛОК ДЛЯ РАСШИРЕНИЯ ДИСКА ----
  disk {
    datastore_id = "local-lvm"  # Укажи имя своего датастора (обычно local-lvm или pve)
    size         = 30           # Выделяем 30 ГБ внутренней памяти для каждой ВМ
    interface    = "virtio0"
    file_format  = "raw"        # <-- ОБЯЗАТЕЛЬНО ДОБАВЛЯЕМ ЭТУ СТРОКУ
  }
  # ------------------------------------------------

  dynamic "disk" {
    for_each = length(regexall("worker", each.key)) > 0 ? [1] : []
    content {
      datastore_id = "local-lvm"
      size         = 20           # 20 ГБ под сырые данные Ceph на каждом воркере
      interface    = "virtio1"    # Важно: другой интерфейс (следующий по порядку)
      file_format  = "raw"
    }
  }

  initialization {
    datastore_id = "local"
    
    # Теперь файлы конфигурации привязаны к конкретным именам нод
    user_data_file_id = each.key == "ansible-master" ? proxmox_virtual_environment_file.user_data_ansible_master.id : proxmox_virtual_environment_file.user_data_cloud_config[each.key].id
    
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.0.1"
      }
    }
  }

  network_device {
    bridge = "vmbr0"
  }
}

# 5. АВТОМАТИЧЕСКИЙ ЗАПУСК ANSIBLE ПОСЛЕ СОЗДАНИЯ ИНФРАСТРУКТУРЫ
resource "null_resource" "ansible_run" {
  depends_on = [proxmox_virtual_environment_vm.k8s_cluster]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "dandi"
      private_key = tls_private_key.ssh_key.private_key_openssh
      host        = local.nodes["ansible-master"].ip
    }

    inline = [
      "echo 'Waiting for cloud-init to finish on ansible-master...'",
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 5; done",
      
      "echo 'Giving all nodes 2 minutes to completely settle down...'",
      "sleep 120", 
      
      "cd /home/dandi/DiplomaProject",
      
      "echo 'Step 1: prepsystem.yml...'",
      "ansible-playbook -i /home/dandi/hosts.ini prepsystem.yml -e 'ansible_become_timeout=60'",
      
      "echo 'Step 2: Install tools...'",
      "ansible-playbook -i /home/dandi/hosts.ini Installtools.yml -e 'ansible_become_timeout=60'",
      
      "echo 'Step 3: InitFile.yml...'",
      "ansible-playbook -i /home/dandi/hosts.ini InitFile.yml -e 'ansible_become_timeout=60'",

      # ---- ВОТ ОНА, НАША КРАСОТА ----
      "echo 'Step 4: Deploy Applications and Monitoring via Playbook...'",
      "ansible-playbook -i /home/dandi/hosts.ini deploy.yml -e 'ansible_become_timeout=60'",

      # ---- ДОБАВЛЯЕМ ВЫВОД ПАРОЛЯ В КОНСОЛЬ TERRAFORM ----
      "echo '=================================================='",
      "echo 'GRAFANA ADMIN PASSWORD: ' && cat /home/dandi/grafana_password.txt",
      "echo '=================================================='"
    ]
  }
}