#!/bin/bash

# Update package index and upgrade existing packages
echo "Updating system..."
sudo apt update && sudo apt upgrade -y

# Install prerequisite packages for HTTPS repositories
echo "Installing dependencies..."
sudo apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
echo "Adding Docker GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the official Docker repository for Ubuntu 24.04 (Noble)
echo "Setting up Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and related plugins
echo "Installing Docker Engine and Compose..."
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker services
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to the 'docker' group to run commands without sudo
echo "Adding user '$USER' to the docker group..."
sudo usermod -aG docker $USER

echo "--------------------------------------------------"
echo "Installation complete. Docker version:"
sudo docker --version
echo "--------------------------------------------------"
echo "IMPORTANT: Activating docker group for current session..."
echo "You can now run docker commands without sudo."
echo "--------------------------------------------------"

# Apply group changes immediately without logout
newgrp docker