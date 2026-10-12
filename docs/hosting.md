# Hosting a shard

How a Gemdrop bot's owner hands a shard to someone else to run, and what that
person (the host) does. The host needs a Linux machine and one script. They
don't need Ruby, open ports or an IRC account.

## The owner's part

### Once, on the hub

1. The hub (Gemdrop) needs its `shards` plugin, next to its `chanserv` plugin:

   ```sh
   bin/gemdrop-docker plugin install contrib/plugins/shards.rb
   ```

2. Give the bot a gecos (`realname` in Gemdrop's `config.yml`) that no other
   bot on the network uses. Shards look for the hub by it when its nick
   changes. A shard only ever trusts the hub's key, so a copied gecos is
   harmless, but a unique one makes the hub quick to find.

### For each host

1. **Choose someone you trust with op.** The hub ops its shards, so whoever runs
   one has a bot with op in your channels. They can also read what the shard
   gets: channel keys, access lists, hostmasks, mode locks, and who is logged in
   as which account. They never get passwords or keys.

2. **Agree on a name for their shard**, for example their nick: 1–32 of
   `a-z`, `0-9`, `_` and `-`.

3. **Send them a join code** for each network they will help on. On that
   network:

   ```text
   /msg <hub> SHARD INFO
   ```

   The second line is the join code: `gemshard1:...`. It holds the network's
   name and the hub's gecos, nick and key, so the host doesn't have to type
   them. It isn't secret. Each network has its own code, even on one Gemdrop.
   With it, send:
   - the setup command, below;
   - which IRC server they should use on each network: one of the network's
     servers, other than the one the hub is on (that's what lets a shard help
     during a netsplit);
   - a nick for the shard on each network.

4. **Their setup prints a `SHARD ADD` line for each network; they send it back.**
   Run it on that network:

   ```text
   /msg <hub> SHARD ADD <name> SHA256:...
   ```

5. **Check that it links:** `/msg <hub> SHARD LIST` shows each shard, whether it
   is linked, its nick and its server.

To stop a shard, run `/msg <hub> SHARD DEL <name>` on each network. It is
unlinked at once and the bots stop opping it. Then ask the host to remove it
(`remove` in their setup menu).

## The host's part

### What you need

- A Linux machine that is up most of the time (a small VPS is plenty), and a
  normal user account with sudo for the first setup.
- From the hub's owner: a join code for each network, an IRC server to use, and
  a nick for the shard.

The script checks for everything else: Docker (on Debian or Ubuntu it can
install it for you), your user being allowed to use it, Docker starting at boot,
git, and a correct clock. The shard only connects out, to IRC, so no ports need
opening. It uses about 128 MB of memory.

### Setting up

One command:

```sh
curl -fsSL https://raw.githubusercontent.com/cban1980/gemshard/main/setup.sh | bash
```

or, if you'd rather look first:

```sh
git clone https://github.com/cban1980/gemshard ~/gemshard
bash ~/gemshard/setup.sh
```

It checks the machine, then asks:

1. a name for the shard (the one agreed with the hub's owner);
2. the join code;
3. the IRC server, port, whether to use TLS, and the shard's nick.

Then it prints a line like this:

```text
/msg Linuks SHARD ADD <name> SHA256:...
```

Send that line to the hub's owner. When they have run it, press Enter: the
script starts the shard and waits until it is on IRC and linked to the hub.
After that it runs by itself, and starts again after a reboot.

If they can't run it straight away, type `later`. The shard keeps trying by
itself once you start it, so start it from the menu whenever suits you.

### Looking after it

Run `bash ~/gemshard/setup.sh` again any time. It shows how the shards are
doing, and offers a menu:

| Choice | Does |
| --- | --- |
| status | each shard, per network: on IRC, linked to the hub, in how many channels |
| start | start or restart a shard, and check it links |
| networks | help on one more network, with its hub (another join code); it prints that network's `SHARD ADD` line |
| log | a shard's latest log lines |
| settings | change a shard's server, port or nick (opens its config) |
| backup | save the shard's key and config to a file in your home folder |
| update | get the newest Gemshard and restart the shards |
| new | set up another shard (for another hub's owner) |
| restore | bring a shard back from a backup |
| stop | stop a shard; it leaves IRC until started again |
| remove | delete a shard and its key |

**The key:** `~/gemshard/shards/<name>/data/shard.key` is what the hubs know
your shard by. Make a backup after setup and keep it private. If the key is
lost, set the shard up again and send the new `SHARD ADD` line.

**Moving to another machine:** make a backup, run the setup on the new machine,
choose `restore` and then `start`. Stop the shard on the old machine first: two
copies of one shard would keep replacing each other's link.

**Restarts and outages:** the shard's link to its hubs survives disconnects,
netsplits, restarts of the hub and of the shard, and reboots. After each one it
links again by itself within about a minute. Only losing the key, or the hub's
owner removing the shard, ends it.

### What the shard does on your machine

It connects out to IRC and nothing else. It answers no commands and talks only
to its hubs, encrypted with keys that only the two sides have. It saves what
the hubs send it (in `~/gemshard/shards/<name>/data/`, readable only by you), so
it can keep the channels right while a hub is away. The container runs as your
user, read-only, with no privileges.

## When it doesn't work

| What you see | Usually |
| --- | --- |
| `not on IRC`, and "Can't connect" in the log | the server or port is wrong, or the machine can't reach it; on port 6667 answer no to TLS (`settings` to change these) |
| `on IRC` but `not linked to the hub` | the hub's owner hasn't run the `SHARD ADD` line yet; or the clock is more than 5 minutes off |
| "that join code is damaged" | only part of it was copied: it runs from `gemshard1:` to the end of the line |
| "A welcome from a key that isn't the hub's" in the log | the join code is from another hub, or the hub's key changed; get a new code |
| linked, but no op in the channels | the hub ops shards only where it has op itself; once one bot has op, the others are opped too |
| the nick ends in `_` | the nick was taken; the shard uses its alternative nicks, and the hub follows |
| `health: unhealthy` | not on IRC on one of its networks for a few minutes; see `log` |

For the command line instead of the menu: `bin/gemshard-docker help`.
