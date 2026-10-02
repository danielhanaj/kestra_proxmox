# kestra-proxmox

[Kestra](https://github.com/kestra-io/kestra) is an open-source, event-driven
orchestration platform: you describe workflows (YAML DSL) that run scripts,
queries, or APIs on a schedule, on events, or on demand. It ships with a web UI
(`http://<host>:8080`) for building, monitoring, and executing those workflows.

Single-file installer for a Kestra **standalone server** in a Proxmox VE LXC,
running **bare-metal** (no Docker): OpenJDK 25, the Kestra standalone launcher,
and a systemd service. Everything runs directly on the LXC from `/opt/kestra`.

`kestra.sh` is **fully self-contained** — the install fragment is embedded in
the script. The only network downloads at install time are official Kestra
artifacts: the latest version string (via the Kestra API) and the standalone
launcher itself (from `github.com/kestra-io/kestra/releases`, SHA256-verified
against the official `checksums_sha256.txt`).

## Usage

```sh
# on the Proxmox VE host
var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/danielhanaj/kestra_proxmox/refs/heads/main/kestra.sh)"
```

Choose Default or Advanced, wait for the build, then open
`http://<lxc-ip>:8080` — the Kestra editor starts empty; create your first
workflow in the UI.

To update later: open the container's console in the Proxmox GUI and run the
same `bash -c "$(wget -qLO - ...)"` command with the **newest** `kestra.sh`
— it shows the **Update** menu, which re-reads the latest Kestra version,
re-downloads the launcher (SHA256-verified), swaps it in, and restarts the
service.

## How it works

- **On the Proxmox host** the script bootstraps the community-scripts engine
  (`community-scripts/core`), materializes the embedded install fragment into a
  temp `COMMUNITY_SCRIPTS_ROOT`, and calls `build_container` — the engine reads
  `install/kestra-install.sh` from disk instead of the network and runs it
  inside the new LXC.
- **Inside the LXC** the install fragment: installs `openjdk-25-jre-headless` +
  `curl`/`jq`, reads the latest Kestra version from `api.kestra.io`, downloads
  the `kestra-<version>` standalone launcher (~125 MB), verifies it against the
  official SHA256, creates the `kestra` user, installs the launcher at
  `/opt/kestra/kestra`, and installs + starts the `kestra.service` unit.
- The service runs `kestra server local` under `/bin/sh`: the standalone server
  with an embedded **H2** database — self-contained, no external PostgreSQL/
  MySQL needed. Swap to `server standalone` (and provide a database) when you
  outgrow it.
- **Re-run inside the LXC** the same script detects the container and offers
  **Update** (re-download + verify + replace + restart).
- Helpers used from the engine: `update_os`, `motd_ssh`, `customize`,
  `cleanup_lxc`, `msg_*`. No Docker anywhere — this aligns with the
  community-scripts policy _"We do NOT use Docker for our installation scripts."_

## Native stack

| Component | Choice                                                 | Why                                                                                                                                                                                                                              |
| --------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OS        | Debian 13 (trixie)                                     | unprivileged LXC friendly; ships all needed packages                                                                                                                                                                             |
| Kestra    | latest version from `api.kestra.io/v1/versions/latest` | official single source of truth for the version (fallback `2.0.0`)                                                                                                                                                               |
| Launcher  | `kestra-<version>` from official GitHub releases       | public, checksum-verified (vs. the signed `api/v1/versions/download` redirect); it's a shebang-less batch/sh polyglot, so the unit runs it via `/bin/sh` (running it via `execve` directly gives `Exec format error` / 203-EXEC) |
| JVM       | `openjdk-25-jre-headless`                              | the 2.x launcher passes `--sun-misc-unsafe-memory-access=allow`, which only JDK ≥23 accepts                                                                                                                                      |
| DB        | embedded H2 (`server local`)                           | zero-config standalone; acceptable for a single-node LXC                                                                                                                                                                         |
| Service   | `kestra.service` (systemd, user `kestra`)              | auto-start, restart-on-failure, no Docker                                                                                                                                                                                        |

Data, logs, and the launcher live in `/opt/kestra` (same location as the
`kestra` user's home). Defaults: 2 vCPU, 4096 MB RAM, 16 GB disk.

## Layout

```
kestra-lxc/
├── LICENSE       # MIT
├── README.md
└── kestra.sh     # the whole installer (host + install fragment) — the only
                  #   file you run
```

## Notes

- Kestra minimums are ~2 vCPU / 4 GB RAM; the LXC defaults reflect that. The
  JVM heap is not pinned — it adapts to the container's memory.
- The standalone launcher ships **without plugins**; Kestra pulls the plugins a
  workflow needs at runtime. If you want the full plugin set up front, add
  `Environment=KESTRA_PLUGINS_AUTO_INSTALL_ENABLED=true` to
  `/etc/systemd/system/kestra.service` and restart.
- If the Kestra API is unreachable at install/update time, the version falls
  back to `2.0.0` (or, on update, the currently installed one).
- Inside the embedded fragment use `${APPLICATION}` (exported by the engine from
  the host `APP` variable) — plain `$APP` is unbound there and aborts the
  install under `set -u`.
