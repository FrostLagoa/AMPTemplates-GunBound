# GunBound Thor's Hammer AMP template

This package supervises the pinned public GunBound Java server in `D:\Gunbound\Server` without copying the game tree into AMP. It starts through `scripts/run_gunbound_server.py`, which retrieves the existing Iris MySQL account from the Vault and injects it only into the Java process environment.

The foreground supervisor keeps Java output in the AMP Console, verifies Broker `8372/TCP`, Game `8360/TCP`, Buddy `8352/TCP`, and Buddy datagrams `8381/UDP`, accepts only `status` plus AMP lifecycle commands, performs at most three bounded crash-recovery attempts, and requests the server's graceful `ampstop` shutdown before any force termination. The runtime remains under AMP's `NETWORK SERVICE` identity.

The server hardening patch is pinned to upstream commit `421930cf69be564727269bb8126f251df04bdce4`. It separates bind/public addresses, removes packet-payload logging, bounds the SQL pool, fails fast on database access, replaces the incompatible MariaDB driver with the official MySQL Connector/J, activates the otherwise dormant Buddy UDP endpoint with one I/O thread, builds a runnable shaded JAR, and adds the AMP STDIN shutdown contract. The client endpoint patch is pinned to `jglim/ThorsHammer` commit `15ffad87d58f38c3bd8333c5892906017a654a21`.

The `gunbound` schema is created from the reviewed upstream SQL after its MySQL 8 reserved-word correction. GunBound's legacy authentication protocol requires the player password itself to remain available to the game server and therefore cannot use a one-way password hash. Iris-generated GunBound passwords must be unique to this game, 6-12 characters, and never reused elsewhere.

`gunbound-banner.jpg` is a 468 x 219 crop of the upstream server project's gameplay screenshot. The public template repository contains only the AMP specification, supervisor, banner, non-secret configuration, and reproducible patches; it contains no client, server binaries, database contents, or credentials.
