
install_xrdp(){
  sudo apt-get --assume-yes install xrdp
  # configure xrdp to use xfce
  echo "xfce4-session" > ~/.xsession
  # start and enable xrdp service
  sudo systemctl enable xrdp
  sudo systemctl start xrdp
  # configure firewall for xrdp
  sudo ufw allow 3389/tcp
}

install_vnc(){
  sudo apt-get --assume-yes install tightvncserver
  # setup vnc password for ubuntu user
  sudo -u ubuntu mkdir -p /home/ubuntu/.vnc
  echo "ubuntu123" | sudo -u ubuntu vncpasswd -f > /home/ubuntu/.vnc/passwd
  sudo -u ubuntu chmod 600 /home/ubuntu/.vnc/passwd
  # create vnc startup script
  sudo -u ubuntu cat > /home/ubuntu/.vnc/xstartup <<EOF
#!/bin/bash
xrdb \$HOME/.Xresources
startxfce4 &
EOF
  sudo -u ubuntu chmod +x /home/ubuntu/.vnc/xstartup
  # add tightvncserver systemd service
  sudo cat > /lib/systemd/system/tightvncserver.service <<EOF
[Unit]
Description=TightVNC remote desktop server
After=sshd.service

[Service]
Type=forking
ExecStart=/usr/bin/tightvncserver :1 -geometry 1024x768 -depth 24
ExecStop=/usr/bin/tightvncserver -kill :1
User=ubuntu
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl enable tightvncserver
  sudo systemctl start tightvncserver
  # configure firewall for vnc
  sudo ufw allow 5901/tcp
}

install_xrdp
install_vnc
