# Valheim Server Mod Updater for AMP

A small updater for CubeCoders AMP Valheim servers that checks Thunderstore, downloads newer mod versions, backs up `BepInEx/config`, applies updates, and restarts the AMP instance only when updates are needed.

## What it does

- Reads AMP/server paths from `updater.settings.json`.
- Reads Thunderstore packages from `mods.json`.
- Checks installed versions using `state.json`.
- Downloads and extracts Thunderstore packages into the Valheim server folder.
- Supports package payloads under `BepInEx/`, `config/`, and top-level `patchers/`.
- Posts optional Discord webhook notifications if `discord_webhook` is set.
- Backs up `BepInEx/config` before applying updates.
- Leaves the server stopped if it was stopped before the updater ran.

## Files

- `thunderstore_sync.py` - Thunderstore resolver/downloader/deployer.
- `update_valheim_mods.sh` - AMP-aware safe update wrapper for scheduled runs.
- `instant_update_valheim_mods.sh` - Runs the same updater with no restart delay.
- `mods.example.json` - Example Thunderstore mod list.
- `updater.settings.example.json` - Example AMP/server path settings.

## Install

Copy the project to your AMP server, for example:

```bash
sudo mkdir -p /opt/valheim-modupdater
sudo cp thunderstore_sync.py update_valheim_mods.sh instant_update_valheim_mods.sh /opt/valheim-modupdater/
sudo cp mods.example.json /opt/valheim-modupdater/mods.json
sudo cp updater.settings.example.json /opt/valheim-modupdater/updater.settings.json
sudo chmod +x /opt/valheim-modupdater/*.sh /opt/valheim-modupdater/thunderstore_sync.py
```

Edit the config files:

```bash
sudo nano /opt/valheim-modupdater/updater.settings.json
sudo nano /opt/valheim-modupdater/mods.json
```

## Configure `updater.settings.json`

Set at least:

```json
{
  "amp": {
    "instance_name": "MyValheimInstance",
    "user": "amp",
    "ampinstmgr": "/opt/cubecoders/amp/ampinstmgr"
  },
  "valheim": {
    "target_root": "/home/amp/.ampdata/instances/MyValheimInstance/Valheim/896660"
  }
}
```

The target root is the folder that contains `BepInEx/`.

You can also point at another settings file for one run:

```bash
sudo SETTINGS_FILE=/path/to/updater.settings.json /opt/valheim-modupdater/update_valheim_mods.sh
```

Individual environment variables still override JSON values, for example:

```bash
sudo WAIT_SECONDS_OVERRIDE=0 /opt/valheim-modupdater/update_valheim_mods.sh
```

## Configure `mods.json`

Use Thunderstore package keys in `Owner-PackageName` format:

```json
{
  "discord_webhook": "",
  "mods": [
    "denikson-BepInExPack_Valheim",
    "ValheimModding-Jotunn"
  ]
}
```

Leave `discord_webhook` empty to disable Discord messages.

## Check Without Changing Anything

```bash
cd /opt/valheim-modupdater
sudo -u amp ./thunderstore_sync.py --config mods.json --target /path/to/valheim/root --check
```

Exit codes:

- `0` - no updates available
- `10` - updates available
- `2` - configuration or runtime error

## Run Updates

Scheduled/safe run with the configured delay:

```bash
sudo /opt/valheim-modupdater/update_valheim_mods.sh
```

Immediate run with no warning delay:

```bash
sudo /opt/valheim-modupdater/instant_update_valheim_mods.sh
```

Or:

```bash
sudo WAIT_SECONDS_OVERRIDE=0 /opt/valheim-modupdater/update_valheim_mods.sh
```

## Optional systemd Timer

Create `/etc/systemd/system/valheim-modupdate.service`:

```ini
[Unit]
Description=Update Valheim Thunderstore mods

[Service]
Type=oneshot
ExecStart=/opt/valheim-modupdater/update_valheim_mods.sh
```

Create `/etc/systemd/system/valheim-modupdate.timer`:

```ini
[Unit]
Description=Run Valheim mod updater daily

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now valheim-modupdate.timer
```

## Notes

This project intentionally does not include a live `mods.json`, `state.json`, webhooks, local backups, or server-specific mod cleanup rules. Keep your real `mods.json` private if it contains a Discord webhook.
