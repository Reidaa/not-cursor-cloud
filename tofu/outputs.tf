output "devboxes" {
  description = "Hetzner DevBoxes by stable machine name."
  value = {
    for name, server in hcloud_server.devboxes : name => {
      ipv4        = server.ipv4_address
      status      = server.status
      server_type = server.server_type
      image       = server.image
      admin_user  = var.admin_user
    }
  }
}
