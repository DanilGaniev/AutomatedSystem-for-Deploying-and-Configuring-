terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.66.1"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://192.168.0.107:8006/"
  # Используем токен, это правильнее
  api_token = "root@pam!terraform=2798c44b-0837-41a3-87f3-567eab6a5a7c"
  insecure  = true

  # Блок SSH ОБЯЗАТЕЛЕН для работы с файлами (snippets)
  ssh {
    agent    = true
    username = "root"
    # Для SSH всё равно нужен пароль или ключ самого сервера Proxmox
    password = "171023810Aa" 
  }
}