# Hosting a shard

How a Gemdrop bot's owner hands a shard to someone else to run, and what that
person (the host) does. The host needs no Ruby, no open ports and no IRC
account: only a Linux machine with Docker.

## The owner's part

### Once, on the hub

1. The hub (Gemdrop) needs its `shards` plugin, and its `chanserv` plugin:

   ```
   bin/gemdrop-docker plugin install contrib/plugins/shards.rb
   ```

2. Give the bot a gecos (`realname` in Gemdrop's `config.yml`) that no other
   bot on the network uses. Shards look for the hub by it when its nick changes.
   A shard only ever trusts the hub's key, so a copied gecos is harmless, but a
   unique one makes the hub quick to find.

### For each host

1. **Choose someone you trust with op.** The hub ops its shards, so whoever runs
   one has a bot with op in your channels. They can also read what the shard
   gets: channel keys, access lists, hostmasks, mode locks, and who is logged in
   as which account (never passwords or keys).

2. **Agree on a shard name** for them: 1–32 of `a-z`, `0-9`, `_` and `-`, e.g.
   their nick. Each shard gets its own name.

3. **Send them what `SHARD INFO` shows**, once for each network they will help
   on:

   ```
   /msg <hub> SHARD INFO
   ```

   It shows the network's name, the hub's gecos, its nick and its key
   (`SHA256:...`). Each network has its own hub key, even on one Gemdrop.
   Along with it, send:
   - the link to this repo;
   - which IRC server they should use: one of the network's servers, other than
     the one the hub is on (that's what lets a shard help during a netsplit);
   - a nick for the shard on each network.

4. **When they send back a `SHARD ADD` line, run it**, on each network it is for:

   ```
   /msg <hub> SHARD ADD <name> SHA256:...
   ```

5. **Check that it links:** `/msg <hub> SHARD LIST` shows each shard, whether it
   is linked, its nick and its server.

To stop a shard, run `/msg <hub> SHARD DEL <name>` on each network. It is
unlinked at once and the bots stop opping it. Then ask the host to stop it
(`bin/gemshard-docker remove <name> --yes`).

## The host's part

### What you need

- A Linux machine that is up most of the time (a small VPS is plenty).
- Docker, with the service started at boot, and your user in the `docker`
  group. Don't run anything as root.
- `git` and `bash`.
- Outgoing connections to the IRC server you were given (usually port 6697).
  Nothing comes in, so no ports need opening.
- A correct clock (NTP, as almost every machine has). The link refuses hellos
  more than 5 minutes off.
- About 128 MB of memory per shard.

### Setting up

You'll be given the network, the hub's gecos, nick and key, an IRC server, and
a nick and name for the shard.

```
git clone https://github.com/cban1980/gemshard && cd gemshard
bin/gemshard-docker setup <name>
```

It asks for those details one by one, builds the Docker image, makes the
shard's key, and prints a line like this:

```
/msg Linuks SHARD ADD <name> SHA256:...
```

Send that line back to the hub's owner. Once they have run it, start the shard:

```
bin/gemshard-docker start <name>
bin/gemshard-docker status
```

`status` should show `on IRC as <nick>` and `linked to the hub` within a minute
or two. The shard then runs by itself, and starts again after a reboot.

**More networks:** run `bin/gemshard-docker add-network <name>`. It asks the
same questions for the next network and prints the `SHARD ADD` line for that
network's hub. Then run `bin/gemshard-docker restart <name>`.

### Looking after it

| Command | When |
| --- | --- |
| `bin/gemshard-docker status` | is it on IRC and linked, per network |
| `bin/gemshard-docker logs <name> -f` | what it is doing (Ctrl-C to stop watching) |
| `bin/gemshard-docker update` | now and then, or when the hub's owner asks: gets the latest version and restarts |
| `bin/gemshard-docker backup <name>` | once after setup, and keep the file somewhere private |
| `bin/gemshard-docker edit <name>` | change the server or nick, then `restart <name>` |
| `bin/gemshard-docker stop <name>` | stop it for a while (it quits IRC); `start <name>` again later |

**The key:** `shards/<name>/data/shard.key` is what the hub knows your shard by.
Keep the backup private. If you lose the key, run `setup` again and send the new
`SHARD ADD` line.

**Moving to another machine:** make a backup, then on the new machine clone the
repo, run `bin/gemshard-docker restore <file>` and then
`bin/gemshard-docker start <name>`. Stop the old one first: two copies of one
shard would fight over the link.

### What the shard does on your machine

It connects out to IRC and nothing else. It answers no commands and talks only
to the hub, encrypted with keys that only the two of them have. It saves what
the hub sends it (`shards/<name>/data/`, readable only by you), so it can keep
your channels right while the hub is away. The container runs as your user,
read-only, with no privileges.

## When it doesn't work

| What you see | Usually |
| --- | --- |
| `not on IRC`, and "Can't connect" in the log | the server or port is wrong, or the machine can't reach it; for a server without TLS, set `tls: false` (`edit`) |
| `on IRC` but `not linked to the hub` | `SHARD ADD` hasn't been run on the hub, or was run with another fingerprint (`bin/gemshard-docker fingerprint <name>` shows yours); or the network name, hub gecos or hub key in the config isn't what `SHARD INFO` shows; or the clock is off |
| "A welcome from a key that isn't the hub's" in the log | the `hub_fingerprint` in the config is wrong for that network |
| linked, but no op in the channels | the hub ops shards only where it has op itself, and only when the shard's nick and user@host match; once one bot has op, the others are opped too |
| the nick ends in `_` | the nick was taken; the shard uses its alternative nicks, and the hub follows |
| `health: unhealthy` | not on IRC on one of its networks for a few minutes; see `logs` |
