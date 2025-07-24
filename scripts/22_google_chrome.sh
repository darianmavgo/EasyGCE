
#!/bin/bash

install_google_chrome(){
  echo "Installing Google Chrome..."
  
  # Update system packages first
  sudo apt-get update
  
  # Install prerequisites
  sudo apt-get install -y wget gnupg2 software-properties-common apt-transport-https ca-certificates curl
  
  # Create keyring directory if it doesn't exist
  sudo mkdir -p /etc/apt/keyrings
  
  # Add Google's official GPG key (modern method)
  wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  
  # Add Google Chrome repository (modern method with signed-by)
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
  
  # Update package list
  sudo apt-get update
  
  # Install Google Chrome
  sudo apt-get install -y google-chrome-stable
  
  # Verify installation
  if command -v google-chrome &> /dev/null; then
    echo "✓ Google Chrome installed successfully"
    google-chrome --version
  else
    echo "✗ Google Chrome installation failed"
    return 1
  fi
  
  # Create desktop shortcut for ubuntu user
  if id "ubuntu" &>/dev/null; then
    sudo -u ubuntu mkdir -p /home/ubuntu/Desktop
    sudo -u ubuntu cp /usr/share/applications/google-chrome.desktop /home/ubuntu/Desktop/ 2>/dev/null || true
    sudo -u ubuntu chmod +x /home/ubuntu/Desktop/google-chrome.desktop 2>/dev/null || true
  fi
  
  # Fix Chrome sandbox issues for remote desktop
  echo "Configuring Chrome for remote desktop use..."
  
  # Create Chrome policy directory
  sudo mkdir -p /etc/opt/chrome/policies/managed
  
  # Add policy to allow Chrome to run in remote desktop environments
  sudo tee /etc/opt/chrome/policies/managed/remote_desktop.json > /dev/null <<EOF
{
  "CommandLineFlagSecurityWarningsEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "SafeBrowsingProtectionLevel": 1,
  "PasswordManagerEnabled": true,
  "AutofillAddressEnabled": true,
  "AutofillCreditCardEnabled": true,
  "DefaultSearchProviderEnabled": true,
  "DefaultSearchProviderName": "Google",
  "DefaultSearchProviderKeyword": "google.com",
  "DefaultSearchProviderSearchURL": "https://www.google.com/search?q={searchTerms}",
  "ExtensionInstallBlocklist": ["*"],
  "ExtensionInstallAllowlist": []
}
EOF
  
  echo "Google Chrome installation and configuration complete!"
}

# Alternative installation method using .deb package
install_chrome_deb_package(){
  echo "Installing Google Chrome via .deb package..."
  
  # Download the latest Chrome .deb package
  cd /tmp
  wget -q --continue --show-progress https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  
  # Install the package
  sudo dpkg -i google-chrome-stable_current_amd64.deb
  
  # Fix any dependency issues
  sudo apt-get install -f -y
  
  # Clean up
  rm -f google-chrome-stable_current_amd64.deb
  
  # Verify installation
  if command -v google-chrome &> /dev/null; then
    echo "✓ Google Chrome installed successfully via .deb package"
    google-chrome --version
  else
    echo "✗ Google Chrome installation failed"
    return 1
  fi
}

# Try the modern repository method first, fallback to .deb package
install_google_chrome || {
  echo "Repository installation failed, trying .deb package method..."
  install_chrome_deb_package
}
