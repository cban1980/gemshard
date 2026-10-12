# Gemshard

Small companion bots ("shards") for the [Gemdrop](https://github.com/cban1980/gemdrop)
IRC bot. A shard runs on another machine, connected to another server of the same
IRC network. It keeps Gemdrop's channels the way they should be, also while Gemdrop
is away or the network is split:

- **Channels:** the shard is in the same channels as Gemdrop, and joins and parts
  with it.
- **Op and voice:** it ops and voices whoever should have it: by login to Gemdrop,
  by hostmask, and bot admins everywhere. It never takes op or voice from anyone.
- **Mode locks:** it keeps each channel's mode lock (Gemdrop's `MLOCK`).
- **The bots:** it keeps Gemdrop and the other shards opped.

Gemdrop is the only source of truth. A shard gets everything from it (the channels,
access lists, hostmasks, mode locks, who is logged in, the other shards) and talks
to nobody else: it answers no commands and doesn't take orders from users or from
other shards. It saves the last state it got, so it carries on from it while
Gemdrop is gone.

A shard can help on several IRC networks at once, each with its own hub: one
Gemdrop on several networks, or a different hub on each. It has one key; each
network has its own IRC connection, hub link and saved state.

## Hosting a shard (Docker)

All you need is Docker, git and bash, and an IRC server of the network that
the hub isn't on. Nothing listens on a port: the shard only connects out, to
IRC. Ask the hub's owner for what `SHARD INFO` shows them: the **network** name,
the **hub's gecos** (its IRC realname), the **hub's nick**, and the **hub's key**
(`SHA256:...`).

1. Get the code and set up the shard (pick a short name for it, e.g. your nick):

   ```
   git clone https://github.com/cban1980/gemshard && cd gemshard
   bin/gemshard-docker setup myshard
   ```

   It asks for the network, the hub's gecos, nick and key, your IRC server and
   the shard's nick. More networks come later, one at a time:
   `bin/gemshard-docker add-network myshard` asks the same for the next one. Then it prints a line like this:

   ```
   /msg Linuks SHARD ADD myshard SHA256:...
   ```

2. Send that line to the hub's owner (for each network, its hub's owner). They
   run it on IRC, and that lets your shard link there.

3. Start it:

   ```
   bin/gemshard-docker start myshard
   bin/gemshard-docker status            # on IRC? linked to the hub?
   ```

   It keeps running, and starts again after a reboot.

Everyday commands:

| Command | Does |
| --- | --- |
| `bin/gemshard-docker status` | each shard, per network: its IRC server and nick, linked or not, its channels |
| `bin/gemshard-docker add-network myshard` | help on one more network, with its hub; then `restart myshard` |
| `bin/gemshard-docker logs myshard -f` | follow its log |
| `bin/gemshard-docker edit myshard` | change its config, then `restart myshard` |
| `bin/gemshard-docker update` | get the latest version and restart the running shards |
| `bin/gemshard-docker backup myshard` | archive the config and the key (keep it private) |
| `bin/gemshard-docker stop myshard` | stop it (it quits IRC) |

`bin/gemshard-docker help` lists everything. Each shard's files are in
`shards/<name>/` (`config.yml`, and `data/` with the key, and a folder per
network with its saved state),
readable only by you. The container runs as your user, read-only, with no
privileges and 128 MB of memory.

## For the hub's owner

The hub is Gemdrop with its `shards` plugin:

```
/msg Linuks SHARD INFO                          the network, gecos, nick and key to hand out
/msg Linuks SHARD ADD myshard SHA256:...        what the shard's host sends you
/msg Linuks SHARD LIST                          the shards, linked or not, and their servers
/msg Linuks SHARD DEL myshard                   unlink one for good
```

## Without Docker

Ruby 3.2+ with its standard library is all a shard needs:

```
bin/gemshard init myshard           # makes myshard/config.yml and the shard's key
bin/gemshard add-network myshard/config.yml --network IRCnet ...   # more networks, if any
$EDITOR myshard/config.yml          # name, and per network: hub_gecos, hub_nick, hub_fingerprint, irc
bin/gemshard check myshard/config.yml
bin/gemshard myshard/config.yml     # run it (or with systemd: see below)
```

## How it works

**Linking to the hub.** A shard talks to the hub only over IRC, with encrypted
NOTICEs to the hub's nick; nothing listens on a port on either side. The hub only
sends the state when it changed, at most every 10 seconds, to stay within flood
limits.

**Finding the hub.** A shard knows the hub by its gecos (IRC realname), since the
hub's nick may change. It follows the hub through nick changes, takes the hub's
lines from whatever nick they come from (only the hub can make lines that check
out), and when the hub comes back under another nick, finds it by its gecos.
`hub_nick` is only where it looks first. The gecos only says where to send a
hello: a bot counts as the hub only after it proves it has the hub's key, so
copying the gecos gets nobody op.

**Which bot acts.** In each channel, only one bot sets modes: the hub if it is
there with op, else the opped shard first by name. Every bot can see on IRC who is
present and opped, so they agree even while unlinked. A shard waits 1.5–4 seconds
after a change, then checks again, and sends at most 12 MODE lines per channel in
30 seconds. That way bots never fight.

**Bots opping each other.** A bot only counts as one of the bots if its nick and
user@host both match what the hub reported. Someone who takes a bot's nick gets
nothing.

**Logins while the hub is away.** A login is trusted only from the same nick and
user@host the hub saw. A user who quits loses it: they have to log in to the hub
again.

**Flood control.** Lines are paced the way IRC servers count them (2 seconds plus
1 second per 120 bytes), so a shard never gets disconnected for Excess Flood.

## Security

- **Keys:** each side has an Ed25519 key, and each pins the other's: the hub
  allows only keys added with `SHARD ADD`, and the shard only the hub's
  fingerprint.
- **Sessions:** a session starts with signed hellos. Each hello carries a fresh
  X25519 key, and a hello is accepted only once and only within 5 minutes. HKDF
  turns the X25519 secret into an AES-256-GCM key for each direction, so every
  session has new keys.
- **Messages:** each message is compressed, encrypted and numbered. It can't be
  read, changed or replayed. On IRC everyone else sees only base64 noise in
  NOTICEs.
- **What a shard gets:** channel names and keys, access lists, hostmasks, mode
  locks, who is logged in as which account, and the bots. It never gets
  passwords, password hashes, or the hub's other data. Shards can't change
  anything on the hub.
- **On disk:** the shard's key (`data/shard.key`) and each network's saved state
  (`data/<network>/state.json`) are mode 600.
- **Networks apart:** each network's hub signs its own welcome and gets its own
  session keys. A hello names its network, and a hub refuses one for another
  network, so nothing one network's hub says can reach another network.

The protocol is in [docs/protocol.md](docs/protocol.md).

## Running it with systemd

```
[Unit]
Description=Gemshard
After=network-online.target

[Service]
ExecStart=/usr/bin/ruby /opt/gemshard/bin/gemshard /opt/gemshard/myshard/config.yml
Restart=always
User=gemshard

[Install]
WantedBy=multi-user.target
```

## Tests

`rake test`. Gemdrop's repo tests the hub's side, and an end-to-end test runs a
hub, two shards and a fake IRC network together.

## License

The Unlicense (public domain), like Gemdrop.
