# Build Prerequisites

Only hostap is compiled from source. The Identus Cloud Agents and the PRISM
node run as published images and require no JVM toolchain on the build host.

## System Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 8 GB | 16 GB or more |
| Disk | 20 GB free | 50 GB or more with a live ledger node |
| Docker | 24.0 | 29.0 or later |
| Docker Compose | v2.20 | v2.30 or later |

The deployment runs eleven containers under the `identus` profile and three
more under `eap`. Memory is the binding constraint; the agents are JVM
processes.

## Build Host

Required for `make build`, which compiles hostapd and wpa_supplicant outside
the container image. The container image builds the same sources independently
and needs none of these on the host.

| Tool | Version | Debian/Ubuntu package |
|---|---|---|
| GCC | 12 or later | `build-essential` |
| Make | 4.0 or later | `make` |
| Git | 2.30 or later | `git` |
| pkg-config | any | `pkg-config` |
| libssl-dev | 3.0 or later | `libssl-dev` |
| libcurl4-openssl-dev | 7.80 or later | `libcurl4-openssl-dev` |
| zlib1g-dev | 1.2.11 or later | `zlib1g-dev` |
| libnl-3-dev | 3.5 or later | `libnl-3-dev libnl-genl-3-dev libnl-route-3-dev` |
| libdbus-1-dev | 1.14 or later | `libdbus-1-dev` |

`libdbus-1-dev` is required by wpa_supplicant only. Omitting it fails the
wpa_supplicant link while leaving hostapd buildable, which is a confusing
failure mode if the EAP-DID sources are all that is under test.

## Documentation

Required for `make -C doc`, which renders the PlantUML diagrams. Optional
otherwise; the `.puml` sources are authoritative and rendered images are not
committed.

| Tool | Purpose |
|---|---|
| PlantUML | Diagram rendering |
| Graphviz | PlantUML layout dependency |
| Java | PlantUML runtime |

## Installation (Debian/Ubuntu)

```sh
sudo apt-get install -y \
    build-essential make git pkg-config \
    libssl-dev libcurl4-openssl-dev zlib1g-dev \
    libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
    libdbus-1-dev \
    docker.io docker-compose-plugin \
    plantuml graphviz
```

## Reference Build Times

Eight-core Intel i3-10100T, warm package cache.

| Component | Time |
|---|---|
| hostap, host build | approximately 1 minute |
| hostap, container image | approximately 3 minutes |
| Cloud Agent startup to ready | approximately 2 minutes |

