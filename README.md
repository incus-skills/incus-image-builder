# incus-image-builder

Builds, validates, signs, and publishes Devuan Incus container images.

## Pipeline

```text
Forgejo CI: build
  distrobuilder build-incus
  → incus.tar.xz + rootfs.squashfs
  → SHA256SUMS
  → GPG detached signatures
  → optional xdelta3 deltas
  → Forgejo artifact

Forgejo CI: validate
  download artifact
  → incus remote add build <LAN_INCUS_HOST>:8443
  → incus image import
  → incus launch
  → apt-cache policy assertions
  → cleanup

Publisher
  download approved artifact
  → incus-simplestreams add
  → incus-simplestreams verify
  → sign index
  → atomic publish to nginx
````

## Why this split?

The CI job container builds portable image artifacts. It does not need an Incus
daemon.

The LAN Incus node is used only as a remote validation target. The runner adds
it with an Incus trust token and uses the HTTPS API rather than mounting the
host Incus Unix socket into Docker.

The simplestreams tree is persistent state. It belongs on the image-publishing
host, not inside an ephemeral CI job container.

## Directory layout

```text
incus-image-builder/
├── .forgejo/workflows/build-images.yml
├── build/
│   ├── build-devuan-image.sh
│   └── publish-simplestreams.sh
├── serve/
│   ├── docker-compose.yml
│   └── nginx-simplestreams.conf
└── README.md
```

## Forgejo secrets

| Secret                        | Purpose                                   |
| ----------------------------- | ----------------------------------------- |
| `INCUS_BUILD_TOKEN`           | One-time Incus trust token for the runner |
| `INCUS_IMAGE_GPG_PRIVATE_KEY` | Long-lived image-signing private key      |
| `GPG_PASSPHRASE`              | Passphrase for the image-signing key      |

## Build locally

```bash
sudo ./build/build-devuan-image.sh \
  devuan freia amd64 default \
  "" "" yes
```

## Validate remotely

```bash
export INCUS_BUILD_TOKEN='...'
incus remote add build 192.168.1.50:8443 --token "$INCUS_BUILD_TOKEN"

incus --remote build image import \
  /path/to/incus.tar.xz \
  /path/to/rootfs.squashfs \
  --alias validation-test
```

## Publish

Run `build/publish-simplestreams.sh` on the host that owns the persistent
simplestreams tree and nginx document root.

## Incus node preparation

On the Incus build/validation node:

```bash
incus config set core.https_address=192.168.1.50:8443
incus config trust add forgejo-runner
incus project create ci
```

Use a dedicated project, network, and resource limits for CI workloads.

## Requirements

- Forgejo runner with Docker job support
- `distrobuilder`
- `yq` (kislyuk/yq)
- `gpg`
- `xdelta3`
- `jq`
- `curl`
- `incus` client, for validation and publishing
- `incus-tools`, for `incus-simplestreams`
- Docker and Docker Compose, for serving the static image tree
