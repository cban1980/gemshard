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

Ruby 3.2+ and its standard library only.

## Setting one up

1. On the machine for the shard:

   ```
   git clone https://github.com/cban1980/gemshard && cd gemshard
   bin/gemshard init myshard        # makes myshard/config.yml and the shard's key
   ```

   It prints the shard's key fingerprint.

2. On IRC, as a Gemdrop bot admin (Gemdrop needs its `shards` plugin):

   ```
   /msg Linuks SHARD INFO                          the hub's nick and key
   /msg Linuks SHARD ADD myshard SHA256:...        the fingerprint from step 1
   ```

3. Fill in `myshard/config.yml`:
   - `name` and `network` (as on the hub);
   - `hub_nick` and `hub_fingerprint` from `SHARD INFO`;
   - `irc`: another server of the same network, and the shard's nick.

4. Run it: `bin/gemshard myshard/config.yml` (in screen/tmux, or with systemd:
   see below).

`SHARD LIST` on the hub shows the shards, whether each is linked, and on which server.

## How it works

**Linking to the hub.** A shard talks to the hub only over IRC, with encrypted
NOTICEs to the hub's nick; nothing listens on a port on either side. The hub only
sends the state when it changed, at most every 10 seconds, to stay within flood
limits.

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
- **On disk:** the shard's key (`data/shard.key`) and saved state
  (`data/state.json`) are mode 600.

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
