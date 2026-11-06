# DDK VPS Manager

DDK VPS Manager is a small, dependency-free web control panel for a server you own. It is built with Python's standard library and systemd; it does not send server data to an external service.

Supported Ubuntu releases: **20.04, 22.04, 24.04, 26.04 LTS and 26.10**. For a production VPS, use Ubuntu 26.04 LTS.

## First release

- Password-protected, mobile-friendly dashboard
- CPU, RAM, disk, uptime, listening-port and service status
- Start, stop, restart and logs for a limited list of local services
- Panel roles and audit log
- Optional integration point for an existing `ddk-vps-manager-python-proxy.service`
- Interactive installation and a menu command: `ddk-vps-manager`
- Complete uninstall for files created by this project

## Install

On an Ubuntu or Debian VPS that you own, run this one command:

```bash
curl -fsSL https://raw.githubusercontent.com/mrshahnawazyt/DDK-VPS-Manager/main/bootstrap.sh | sudo bash
```

The installer asks for the domain/IP, panel port and first admin username. It creates a strong password and shows it once. Open `http://YOUR-DOMAIN:PORT` and sign in.

After installation, the panel service starts automatically after every VPS reboot. For all management actions, run one command:

```bash
sudo ddk-vps-manager
```

The menu includes panel status/control, logs, optional Python service controls, HTTPS setup and complete uninstall.

## HTTPS

First point a domain to your VPS and make sure ports 80 and 443 are reachable. Then run `sudo ddk-vps-manager` and choose **Set up HTTPS**. The helper installs Nginx and Certbot, configures an HTTP reverse proxy, requests a Let's Encrypt certificate and redirects HTTP traffic to HTTPS.

## Optional Python proxy service

The **Running services** page can start, stop and restart an already installed
`ddk-vps-manager-python-proxy.service`. It also stores the selected port in
`/opt/ddk-vps-manager/data/python-proxy.env` as `DDK_VPS_MANAGER_PROXY_PORT`. Your
separate Python service can read that environment file; an example systemd unit
is in `systemd/ddk-vps-manager-python-proxy.service.example`. DDK VPS Manager does not
download or run an unreviewed proxy program on its own.

## Security notes

- Put the panel behind HTTPS before exposing it publicly.
- Use a unique administrator password and limit access with a firewall or reverse proxy.
- Do not commit passwords, tokens, private keys or server addresses into this repository.
- The project manages only its own `/opt/ddk-vps-manager` directory and `ddk-vps-manager*` services.

## Uninstall

Run `sudo ddk-vps-manager`, choose **Uninstall DDK VPS Manager**, then type the confirmation shown. This removes the panel, its configuration, database, logs, systemd units and menu command. It does not remove unrelated VPS services or user data.

## License

MIT. See [LICENSE](LICENSE).
