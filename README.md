# GunBound World Champion Season 2 v894 AMP template

This template controls the operator-provided native WC2 v894 server in
`D:\Gunbound`. AMP controls a demand-only `Iris-GunBoundWC2` task which starts
the original `BrokerServer.exe` and `GameServer.exe` in the Kallidos session.
The demand-only task launches an independent hidden worker, so AMP's
`NetworkService` console lifecycle cannot inject `Ctrl+C` into the native
processes. The worker publishes a non-secret, private heartbeat while AMP
mirrors its read-only runtime log in the Console.

## Dual-Broker networking

The template starts two isolated native Broker processes against the same
`gunbound` schema and the same single Game Server process. The external Broker
uses the configurable public DDNS hostname (by default
`server.kallidos.com`) and remains on `8400/TCP`. The LAN Broker listens on
`8402/TCP` and advertises the configurable private address (by default
`192.168.15.5`). It is intentionally a LAN-only entry point: do not create a
router forwarding rule for it, and scope any host-firewall allow rule to the
private subnets that need it.

Both Broker paths reach the Game Server on `8401/TCP`; they do not create
separate worlds, accounts, sessions or databases. A local client must be
configured to use the LAN Broker port, while a distributed client must keep
the external DDNS Broker endpoint.

## Database compatibility

The native binaries ship with legacy MySQL client libraries that are not
compatible with the TLS negotiation of Laragon's MySQL 8.4. The template uses a
separate official MySQL 5.7.44 compatibility instance installed under Laragon,
bound only to `127.0.0.1:3303`. It owns only the `gunbound` schema and uses the
same scoped Iris SQL identity as every other game integration. It neither
changes nor exposes the MySQL 8.4 service used by Iris and the other games.

The `GunBoundMySQL57` Windows service starts this loopback-only companion with
Windows, independently of AMP. AMP checks that it is available, waits through
a short readiness window, and then starts only the native Broker/Game pair.
Stopping or restarting the AMP instance never stops the database service. The
companion database is not a public game port.

The scoped credential store contains machine-DPAPI-protected values only. The
launcher projects the required native JSON database block immediately before
the executables start and restores credential-free templates as soon as they
exit. Neither the template repository nor AMP configuration contains database
passwords.

## Configuration

The `Gunbound` gamepad page exposes every non-secret value represented by the
native Broker/Game configuration: public world identity and capacity, client
compatibility, connection limits, rewards, grade/function restrictions, Item2,
item seal/enchant rules, channel/room messages, classic mode, native event
flags, cash-event parameters and packet diagnostics. Values are written to the
runtime settings file and applied on the next AMP start/restart.

AMP lifecycle commands are the supported way to start, stop and restart the
server. The runtime task has no Windows trigger, recovery rule or scheduled
stop: it changes state only when AMP/Iris explicitly controls it. AMP starts
the task on demand and stops the hidden worker through a private stop marker;
the marker and heartbeat never expose a network port or credentials. Native WC2 binaries do not expose a safe console protocol for Iris
in-game chat injection; the template deliberately reports that capability as
unavailable rather than accepting a message it cannot deliver.

`gunbound-banner.jpg` is an operator-provided Season 2 banner adapted to AMP's
instance-card dimensions. This repository contains no game/client binaries,
database dumps or secret material.
