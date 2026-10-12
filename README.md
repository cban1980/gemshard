# Gemshard

Small companion bots ("shards") for the [Gemdrop](https://github.com/cban1980/gemdrop)
IRC bot. A shard runs on another machine, connected to another server on the same
IRC network. It keeps Gemdrop's channels the way they should be (the same channels,
the right people opped and voiced, mode locks kept, the bots opping each other),
also while Gemdrop is away or the network is split.

Gemdrop is the only source of truth: a shard gets everything from it, over
encrypted and signed IRC notices (and a direct TLS link where available), and
talks to nobody else.

Work in progress.
