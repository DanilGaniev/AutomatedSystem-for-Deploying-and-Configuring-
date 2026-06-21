variable "pm_api_url" {
  type        = string
  description = "URL Proxmox API"
  default     = "https://192.168.0.107:8006/api2/json" # Замени на IP своего Proxmox, если он другой
}

variable "pm_api_token_id" {
  type        = string
  description = "ID Токена Proxmox"
  default     = "terraform-user@pve!terraform-token" # Замени на точное имя твоего токена
}

variable "pm_api_token_secret" {
  type        = string
  description = "Секретный ключ токена"
  sensitive   = true
  default     = "28100c72-cb3c-4d2a-aca9-44d26c47d0b4" # Вставь сюда длинный secret, который сгенерировал Proxmox
}