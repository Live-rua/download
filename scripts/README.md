# Helper scripts

- `install.sh`: installs the verified Kylin V10 SP3 ARM64 Samba 4.11 offline bundle from the bundled local RPM repository, after a transaction test.
- `configure-dfs-root.sh`: configures this host as the Samba MSDFS/DFS root and starts the Kylin `smb.service` after `testparm` validation.
- `add-dfs-target.sh`: adds a backend Samba share as an `msdfs:` junction under `/srv/dfs`.

This file is also covered by the main workflow's `scripts/**` path filter, so changes to installation helpers trigger a complete bundle rebuild and Release verification.

The full build status is recorded under `.build-status/latest.txt` by the companion `workflow_run` workflow so a completed Action can be audited together with its Release assets.
