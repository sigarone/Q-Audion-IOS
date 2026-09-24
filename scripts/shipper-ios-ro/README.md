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
