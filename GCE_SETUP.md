# GCE SETUP
-----------

  * Setup gce instance and run easygce docker image

### Prerequisites
-----------------

  * Installed gcloud tool.
  * Authenticated with Google Cloud. Use `gcloud auth login` command to login.

### Script usage
----------------

  * For help on using script run `gce_server_deploy.sh -h`
  * For using script with predefined default run `GCE_PROJECT=<your_gce_project> ./gce_server_deploy.sh` or `./gce_server_deploy.sh -p <your_gce_project>` This command will do following:
    * Check for needed firewall ports and open them if they are not open.
    * Create ubuntu server in the `us-east1-c` zone.
    * Default server type is n1-standard-2.
    * Install XFCE desktop environment.
    * Install and configure remote desktop servers (XRDP and VNC).
    * Install docker and dependencies.
    * Clone easygce repo and build docker image.
    * Run docker image.
    * Print server ip to console when the process is complete.
  
### Overriding default values
-----------------------------

  * Overriding default values is done during script invocation:
    * `./gce_server_deploy.sh -p <your_gce_project> -n <gce_server_name> -z <gce_server_zone> -m <gce_machine_type>`
  * If `-b` switch is used during script invocation it will set google to auto delete boot disk on server deleting.

### Remote Desktop Access
---------------------

Once the VM is created, you can connect to it using remote desktop:

#### RDP (Remote Desktop Protocol) - Port 3389
* **Windows**: Use built-in Remote Desktop Connection
* **Mac**: Use Microsoft Remote Desktop from App Store
* **Linux**: Use Remmina or other RDP client
* **Credentials**: Username: `ubuntu`, Password: `ubuntu123`

#### VNC (Virtual Network Computing) - Port 5901
* **Any OS**: Use VNC Viewer or similar VNC client
* **Connection**: `<server_ip>:5901`
* **Password**: `ubuntu123`

#### Web-based VNC - Port 6901
* **Any OS with web browser**: Navigate to `http://<server_ip>:6901`
* **Password**: `ubuntu123`
