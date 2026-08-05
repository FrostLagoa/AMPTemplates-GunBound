# GunBound Thor's Hammer AMP template

This package supervises the reviewed GunBound .NET runtime in
`D:\Gunbound\Server\dotnet-runtime` without copying the game tree into AMP.
The self-contained `gunbound-launcher.py` reads a host-local Vault containing
only `IRIS_MYSQL_USER` and `IRIS_MYSQL_PASSWORD`, decrypts those values through
machine-scoped Windows DPAPI, and injects them only into the child process. The
AMP identity never receives access to the full Iris checkout or its main Vault.

The foreground supervisor keeps runtime output in the AMP Console and verifies
Broker `8372/TCP`, Game `8360/TCP`, Buddy `8352/TCP`, and Buddy relay
`8381/UDP`. It accepts only `status`, the validated Base64 `iris-chat` envelope,
and lifecycle commands, performs at most three bounded crash-recovery attempts,
and terminates every supervised descendant on shutdown. The runtime remains
under AMP's `NETWORK SERVICE` identity.

The .NET server is based on the public `Cephas02/Gunbound-Net-public` protocol
implementation and supports the bundled Thor's Hammer client room workflow.
Its Iris deployment adds scoped Vault credentials, public-DDNS plus LAN-aware
endpoint advertisement, configurable ports/capacity, bounded diagnostics, and
the Iris chat injection contract. The previous Java runtime remains installed
only as an offline rollback path because it accepts login/lobby traffic from
the client but does not recognize that client's room-create request.

GunBound lobby and room chat lines are consumed from the AMP Console; no extra
listener is opened. The single complete case-insensitive `~Iris` token may
appear anywhere in a player message. Replies are restricted to a 60-character
client-safe envelope and always begin with `Iris: `.

The existing `gunbound` Laragon schema is retained. The deployment adds only
the compatibility columns and auxiliary tables required by the .NET runtime.
GunBound's legacy authentication protocol requires the player password itself
to remain available to the game server and therefore cannot use a one-way hash.
Passwords must be unique to this game, 6-12 characters, and never reused.

`gunbound-banner.jpg` is a 468 x 219 adaptation of the operator-provided Thor's
Hammer artwork that keeps the complete logo visible. The public template
repository contains no client/server binaries, database contents, or secrets.

AMP config version 7 exposes every non-secret setting supported by this runtime:
public/LAN/bind endpoints, the four service ports, world name/description,
player slots, P2P mode, packet diagnostics, per-IP session cap, spawn and shop
compatibility controls, tunnel duplicate suppression, anti-cheat reward caps,
and event controls. Saves write through the verified `runtime-config` junction
to `D:\Gunbound\Server\config\db.properties`.
