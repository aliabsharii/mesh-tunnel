# tinc-mesh.sh

🌍 Languages:  
English | [فارسی](README-fa.md)

Minimal & Fast Tinc Mesh Tunnel Script
Build a private mesh network between your servers — without any panel

What is this?

tinc-mesh.sh is a lightweight bash script that:

Connects multiple servers together using Tinc VPN
Creates a full mesh tunnel automatically
Needs only server IP + SSH password
Installs & configures everything remotely
Keeps nodes synced

Perfect for:

Connecting Iran ↔ Foreign servers
Reverse tunnel backbone
V2Ray / Xray transport layer
Multi-location routing

Features

No web panel
One-command node add
Auto private IP assignment
Full mesh sync
KeepAlive enabled
MTU tuning (1380)
PMTU + MSS fix
Clean node removal
Password is prompted (not stored)

Requirements

Main server must have these installed:

tinc
iproute2
net-tools
sshpass

Remote servers install dependencies automatically.

Installation
```bash
wget -O tinc-mesh.sh https://raw.githubusercontent.com/aliabsharii/mesh-tunnel/main/tinc-mesh.sh
chmod +x tinc-mesh.sh
```

Step 1 — Initialize Main Server

Run on your MAIN server:
```bash
sudo ./tinc-mesh.sh init --net ali --name iranserver --pub YOUR_MAIN_PUBLIC_IP --priv 10.20.0.1 --mask 255.255.255.0
```
Step 2 — Add New Server

Only need public IP:
```bash
sudo ./tinc-mesh.sh addq --net ali --pub NODE_PUBLIC_IP
```
Script will:

Ask SSH password
Detect hostname
Assign private IP
Install Tinc remotely
Connect to mesh
Sync with all nodes

Optional:
```bash
sudo ./tinc-mesh.sh addq --net ali --pub NODE_PUBLIC_IP --ssh-user root
```
List Nodes
```bash
sudo ./tinc-mesh.sh list --net ali
```
Re-sync Mesh
```bash
sudo ./tinc-mesh.sh push --net ali
```
Remove Node
```bash
sudo ./tinc-mesh.sh del --net ali --name NODE_NAME
```
This removes the node from:

Mesh
All configs
Remote server

Restart Network
```bash
sudo ./tinc-mesh.sh restart --net ali
```
Firewall

Open port on ALL servers:

ufw allow 655/udp
ufw allow 655/tcp

State File

Saved here:

/etc/tinc/mesh_state/<net>.nodes

Passwords are NOT stored.

Use Cases

Iran bridge tunnel
Reverse routing backbone
Multi-server overlay
Transport layer for proxy systems

Disclaimer

Use responsibly according to your local laws and infrastructure policies.
