# Phase 4 — Containers

Goal: xinit is the health check and diagnostics tool for XWiki in Docker or Kubernetes, without
fighting the orchestrator.

## Modes

| Mode | Where xinit runs | Checks | Diagnostics | Restart |
|---|---|---|---|---|
| in-container | inside the official `xwiki` image (added layer or mounted) | process, http, rest, jvm, oom, disk, db (if a client is present) | full (`jcmd` from the image's JDK) | **never**: `xinit check --health` exit code; orchestrator restarts |
| sidecar, shared PID namespace | own small image (`container/Dockerfile.sidecar`); compose `pid: "service:xwiki"`, k8s `shareProcessNamespace: true` | all of the above | full, if the sidecar has a `jcmd` of the same major version, or uses `jattach` | never |
| sidecar, network only | own image, nothing shared | http, rest, db | HTTP-side only | never |

## Tasks
- Container profile:
  - detect the official image layout and read the DB settings from its env vars
    (`DB_HOST`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD`) or from `hibernate.cfg.xml`;
  - use `BASE_URL=http://localhost:8080` (root context).
- `xinit check --health`:
  - a short timeout and no side effects;
  - a grace period based on JVM uptime, so a starting wiki is not killed by its liveness probe.
- `xinit serve` (optional): a tiny HTTP endpoint (via `socat` or `busybox httpd` CGI) exposing
  `/healthz` and `/metrics` for k8s probes and Prometheus scraping, for clusters that prefer
  HTTP probes.
- Sidecar image: Debian slim with bash, curl, the DB clients and `jattach`. Its size is a target to
  track.
- Examples:
  - `container/examples/compose.yaml` (xwiki + postgres + xinit sidecar, `HEALTHCHECK`);
  - `container/examples/k8s.yaml` (probes and sidecar).
- Integration test against the **official** `xwiki:<lts>-postgres-tomcat` image: in-container,
  sidecar with a shared PID namespace, and network-only sidecar.

## To verify before implementing
- Whether the official image already defines a `HEALTHCHECK`, and what it checks.
- The `jcmd` attach constraints across PID namespaces: same UID, `/tmp/.java_pid<pid>` visibility,
  and `/proc/<pid>/root/tmp` being reachable. `jattach` handles this but needs `SYS_PTRACE`.

## Acceptance
- `docker compose up` with the example gives `healthy`.
- `docker kill -s STOP` on the JVM gives `unhealthy` within the configured retries, and the
  sidecar's report holds a thread dump taken through the shared PID namespace.
- None of the container modes tries `systemctl`, writes outside its volume, or needs root, apart
  from `SYS_PTRACE` for `jattach` when that is used.
