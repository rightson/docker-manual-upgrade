# Docker server — notes & overrides

## What the upgrade preserves

For a `docker run`‑started container the tool reconstructs the new container
from `docker inspect` of the running one, preserving:

- **Volumes / bind mounts** (`/etc/gitlab`, `/var/opt/gitlab`, `/var/log/gitlab`,
  and any others) — reattached by name/path, so **data survives** the recreate.
- **Published ports** (`-p`), **hostname** (`--hostname`), **restart policy**
  (`--restart`), **shm‑size**, and the `GITLAB_OMNIBUS_CONFIG` / `TZ` env vars.

The exact command it runs is printed and written to
`<work-dir>/last-docker-run.txt` so you can review it.

## Typical GitLab docker layout the tool expects

```bash
docker run --detach \
  --hostname gitlab.example.com \
  --publish 443:443 --publish 80:80 --publish 22:22 \
  --name gitlab \
  --restart always \
  --shm-size 256m \
  --volume /srv/gitlab/config:/etc/gitlab \
  --volume /srv/gitlab/logs:/var/log/gitlab \
  --volume /srv/gitlab/data:/var/opt/gitlab \
  gitlab/gitlab-ce:16.1.8-ce.0
```

Anything not in the list above (custom `--cap-add`, extra networks, sysctls,
etc.) should be set in **`gitlab.rb`** (which lives in the persisted
`/etc/gitlab` volume) rather than as `docker run` flags, so it is preserved
automatically. If you rely on such flags, either add them to `gitlab.rb` first
or use a `docker compose` file (below).

## docker compose users

If your container was created by `docker compose`, the tool detects it via the
`com.docker.compose.*` labels, **backs up your compose file**, updates the
GitLab image tag in it for each stop, and runs `docker compose up -d <service>`.
Your compose file therefore stays the source of truth and won't be reverted by a
later `docker compose up`.

## Manual override

If you want full control, start the target container yourself using the printed
command as a template, then run the tool with `--container <name>` so it manages
the migration waits and background‑migration gating.
