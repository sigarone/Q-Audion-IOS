# iOS log shipper: restricted SSH key (Aruba side)

`qaudion-shipper-ios-ro.sh` is the forced command of the dedicated key used by the Helsinki cron
(`scripts/ship-ios-logs.py`, restricted-exec mode, env `QAUDION_VPS_IOS_KEY`). It answers only:

    ios-list <minutes> <limit>   recent uuid-named regular files (<= 256 KiB) under data/files
    ios-cat  <uuid>              one W417 telemetry chunk (first line checked), nothing else

Deployed 2026-09-21 on Aruba as `/usr/local/sbin/qaudion-shipper-ios-ro.sh` (root:root 0755), with ONE line in
`/root/.ssh/authorized_keys`:

    command="/usr/local/sbin/qaudion-shipper-ios-ro.sh",restrict,from="<helsinki ipv4>" ssh-ed25519 <pub> qaudion-shipper-ios-ro@fi-1-2026-09-20

Tests (Linux; nothing touches a server): `bash test_wrapper.sh` (83 cases against a fake data dir) and
`python3 ro_integration.py ../ship-ios-logs.py qaudion-shipper-ios-ro.sh` (drives the real shipper through the real wrapper).

Rollback: remove the authorized_keys line by its comment marker and delete the wrapper (see BCrypto-Ops/OPS.md, "Log shipper").

## Helsinki side: the shipper verifies the Aruba host key

The shippers (`ship-ios-logs.py`, `ship-server-logs.py`) and the dev tools (`fetch-ios-live.py`, `correlate-call.py`) no
longer trust the first host key they see. They load the pinned prod key from `scripts/vps_known_hosts` (ED25519 of
195.231.87.110, `SHA256:XDDSqerYgzHIFwo2amn4XQWza0DeU0TDJSZjyZBI/ZY`), then env `QAUDION_VPS_KNOWN_HOSTS` (optional extra file,
a set-but-missing path is an error), then `~/.ssh/known_hosts`; an unknown or changed key aborts with exit 1.

Deploy layout on Helsinki (`/opt/bcrypto/shipper/` is a plain copy of the scripts, not a git checkout): copy
`vps_known_hosts` next to `ship-ios-logs.py` / `ship-server-logs.py` whenever the scripts are copied. root's
`/root/.ssh/known_hosts` already has the same key, so the system file would also satisfy the check, but the pinned file is
the one that is reviewed in git. After copying: keep `.bak` copies of the old scripts, run `python3 ship-ios-logs.py
--selftest` and `python3 ship-server-logs.py --selftest` (they check the pin) before the `*/5` cron picks the new files up.
Tests: `python3 scripts/test_vps_host_key_pin.py` (offline) and `QAUDION_HOSTKEY_LIVE=1 python3 scripts/test_vps_host_key_pin.py`
on a box with a local sshd (live loopback handshake, no credentials sent).
