# Diagrams

Mermaid diagrams for the MST server synchronization plan (`sync.qmd`).

## Files

| File | Description |
|---|---|
| `architecture-simple.mmd` | High-level architecture: laptop, GitHub, dev server, BOEM prod server |
| `architecture-detailed.mmd` | Detailed architecture with all services, data stores, and connections |
| `sync-simple.mmd` | High-level sync flow: prod server pulls from dev server and GitHub |
| `sync-detailed.mmd` | Detailed sync flow with cron jobs, rclone, heartbeat, monitoring |
| `prod-stack.mmd` | Production Podman stack: Caddy, Shiny, /share volumes |

## Rendering to PNG

The `.mmd` source files are referenced by `sync.qmd`. Pre-rendered PNGs are
committed so the document works without mermaid-cli installed.

To re-render after editing a diagram:

```bash
# install mermaid-cli (one-time)
brew install mermaid-cli

# render all diagrams
cd diagrams && ./render.sh

# render a single diagram
cd diagrams && ./render.sh architecture-simple
```

The render script produces high-res PNGs (scale 3x, 2400x1600 base) suitable
for print and PDF output.

## Brand icons

The mermaid CLI (`mmdc`) bundles Font Awesome Solid icons (`fa:fa-*`) but
**not** brand icons like GitHub or Docker. The render script works around this
by substituting placeholders with base64 data-URI `<img>` tags at render time:

| Placeholder | Icon | Source SVG |
|---|---|---|
| `{{ICON_GITHUB}}` | GitHub octocat | `github.svg` (simple-icons) |
| `{{ICON_DOCKER}}` | Docker whale | `docker.svg` (simple-icons) |

Use these in `.mmd` files like:

```
subgraph GITHUB["{{ICON_GITHUB}} GitHub"]
```

The `render.sh` script handles the substitution automatically — no manual
base64 encoding needed.
