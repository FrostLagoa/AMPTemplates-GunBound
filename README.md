# GunBound Thor's Hammer AMP template

This package supervises the pinned public GunBound Java server in `D:\Gunbound\Server` without copying the game tree into AMP. The self-contained `gunbound-launcher.py` reads a host-local Vault containing only `IRIS_MYSQL_USER` and `IRIS_MYSQL_PASSWORD`, decrypts those values through machine-scoped Windows DPAPI, and injects them only into the Java child-process environment. The AMP identity never receives access to the full Iris checkout or its main Vault.

The foreground supervisor keeps Java output in the AMP Console, verifies Broker `8372/TCP`, Game `8360/TCP`, Buddy `8352/TCP`, and Buddy datagrams `8381/UDP`, accepts only `status`, the validated Base64 `iris-chat` envelope and AMP lifecycle commands, performs at most three bounded crash-recovery attempts, and requests the server's graceful `ampstop` shutdown before any force termination. The runtime remains under AMP's `NETWORK SERVICE` identity, which receives read/execute access only to the GunBound runtime, Python runtime, and scoped SQL Vault.

GunBound lobby and room chat lines are consumed from the existing AMP Console stream; no extra listener is opened. The single complete case-insensitive `~Iris` token may appear anywhere in the player message. Replies return through the supervised Java STDIN channel, are restricted to a 60-character client-safe envelope, and always begin with `Iris: `. The supervisor and Java process both validate the envelope before broadcasting it.

The server hardening patch is pinned to upstream commit `421930cf69be564727269bb8126f251df04bdce4`. It separates bind/public addresses, removes packet-payload and credential logging, bounds the SQL pool, fails fast on database access, replaces the incompatible MariaDB driver with the official MySQL Connector/J, activates the otherwise dormant Buddy UDP endpoint with one I/O thread, builds a runnable shaded JAR, and adds the AMP STDIN shutdown contract. Login preserves the exact client-supplied account spelling for the case-sensitive dynamic protocol key, reports invalid credentials separately from a real ban, and accepts the bundled modern Thor's Hammer client's declared protocol version `5`. Room-directory replies follow the reference packet layout exactly, including a two-byte empty-room response and no undocumented per-room or trailing padding bytes. The client endpoint patch is pinned to `jglim/ThorsHammer` commit `15ffad87d58f38c3bd8333c5892906017a654a21`.

The `gunbound` schema is created from the reviewed upstream SQL after its MySQL 8 reserved-word correction. GunBound's legacy authentication protocol requires the player password itself to remain available to the game server and therefore cannot use a one-way password hash. Iris-generated GunBound passwords must be unique to this game, 6-12 characters, and never reused elsewhere.

`gunbound-banner.jpg` is a 468 x 219 adaptation of the operator-provided Thor's Hammer artwork that keeps the complete logo visible. The public template repository contains only the AMP specification, launcher, supervisor, banner, non-secret configuration, and reproducible patches; it contains no client, server binaries, database contents, or credentials. The scoped Vault is generated locally by Iris provisioning and is never copied into this repository.

AMP config version 6 uses the `Gunbound:gamepad` page and exposes all 30
non-secret properties supported by the pinned server build, including the SSL
toggle, LAN endpoint and editable player-slot capacity. The same capacity is
used in the broker's world-list packet instead of a compiled constant. Save writes through the
verified `runtime-config` junction into
`D:\Gunbound\Server\config\config.properties`; no duplicate configuration is
created under AMP. The client-version fields are labeled explicitly; the default
accepted range is `5-900`, with changes applied after a server restart. The JDBC URL remains integration-managed, while SQL
credentials remain exclusively in the scoped DPAPI Vault and are never
rendered in the page or public template.
