locals {
  timestamp = timestamp()
  tags = {
    environment = var.env
    department  = var.department
    owner       = var.owner
    application = "${var.store_name} website"
  }
}

resource "azurerm_virtual_network" "hashilab" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.resource-rg.location
  address_space       = [var.address_space]
  resource_group_name = azurerm_resource_group.resource-rg.name
}

resource "azurerm_subnet" "hashilab" {
  name                 = "${var.prefix}-subnet"
  virtual_network_name = azurerm_virtual_network.hashilab.name
  resource_group_name  = azurerm_resource_group.resource-rg.name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_network_security_group" "hashilab" {
  name                = "${var.prefix}-sg"
  location            = azurerm_resource_group.resource-rg.location
  resource_group_name = azurerm_resource_group.resource-rg.name

  security_rule {
    name                       = "HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTPS"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SSH"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "hashilab" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.resource-rg.location
  resource_group_name = azurerm_resource_group.resource-rg.name

  ip_configuration {
    name                          = "${var.prefix}ipconfig"
    subnet_id                     = azurerm_subnet.hashilab.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.hashilab.id
  }
}

resource "azurerm_network_interface_security_group_association" "hashilab" {
  network_interface_id      = azurerm_network_interface.hashilab.id
  network_security_group_id = azurerm_network_security_group.hashilab.id
}

resource "azurerm_public_ip" "hashilab" {
  name                = "${var.prefix}-ip"
  location            = azurerm_resource_group.resource-rg.location
  resource_group_name = azurerm_resource_group.resource-rg.name
  allocation_method   = "Dynamic"
  domain_name_label   = "${var.prefix}-app"
}

resource "azurerm_linux_virtual_machine" "hashilab" {
  name                = "${var.prefix}-webapp"
  location            = azurerm_resource_group.resource-rg.location
  resource_group_name = azurerm_resource_group.resource-rg.name
  size                = var.vm_size

  network_interface_ids = [azurerm_network_interface.hashilab.id]

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    name                 = "${var.prefix}-osdisk"
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  computer_name  = var.prefix
  admin_username = var.admin_username
  admin_password = var.admin_password

  disable_password_authentication = false

  tags = local.tags

  # Added to allow destroy to work correctly.
  depends_on = [azurerm_network_interface_security_group_association.hashilab]
}

# We're using a little trick here so we can run the provisioner without
# destroying the VM. Do not do this in production.

resource "random_integer" "product" {
  min = 0
  max = length(var.hashi_products) - 1
  keepers = {
    "timestamp" = local.timestamp
  }
}

resource "null_resource" "configure-web-app" {
  depends_on = [azurerm_linux_virtual_machine.hashilab]

  triggers = {
    build_number = local.timestamp
  }

  connection {
    type     = "ssh"
    user     = var.admin_username
    password = var.admin_password
    host     = azurerm_public_ip.hashilab.fqdn
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections",
      "echo 'Installing nginx...' && sudo apt-get -qq -y update >/dev/null",
      "sudo apt-get -qq -y -o \"Dpkg::Options::=--force-confdef\" -o \"Dpkg::Options::=--force-confold\" install nginx >/dev/null",
      "echo 'Adding firewall rule...' && sudo ufw allow http >/dev/null",
      "echo 'Creating HTML folders...' && sudo mkdir -p /var/www/html/img",
      "echo 'Setting folder permissions...' && sudo chown -R ${var.admin_username} /var/www/html"
    ]
  }

  provisioner "file" {
    content = templatefile("files/index.html", {
      product_name     = var.hashi_products[random_integer.product.result].name
      product_color    = var.hashi_products[random_integer.product.result].color
      product_image    = var.hashi_products[random_integer.product.result].image_file
      store_name       = var.store_name
      youtube_video_id = var.youtube_video_id
    })
    destination = "/var/www/html/index.html"
  }

  provisioner "file" {
    source      = "files/img/"
    destination = "/var/www/html/img"
  }
}