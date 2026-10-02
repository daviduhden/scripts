# SecureBlue systemd user services

These templates support the scripts in [the parent directory](../README.md).
They are user units, managed with `systemctl --user` rather than as system-wide
services. Inspect their executable and configuration paths before manual use.

| Unit | Purpose | Installer |
| --- | --- | --- |
| [arti.service](arti.service) | Runs Arti with the user's configuration. | `../install-arti-service.bash` |
| [arti-socks-proxy.service](arti-socks-proxy.service) | Bridges a user-local UNIX socket to Arti's TCP SOCKS port with socat. | `../install-arti-service.bash`, when socat is available |
| [xd.service](xd.service) | Runs XD with user-local configuration and data. | `../update-xd-torrent.bash` |

The installers copy/configure the relevant templates and enable their units.
To inspect status after installation:

```sh
systemctl --user status arti.service
systemctl --user status arti-socks-proxy.service
systemctl --user status xd.service
```
