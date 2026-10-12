# The Gemshard protocol (version 1)

Between a shard and its hub (Gemdrop's `shards` plugin). The code is
`lib/gemshard/protocol.rb`, and an identical copy is in Gemdrop's
`contrib/plugins/shards.rb`. The two must stay the same.

## Keys

- **Identity:** each side has an Ed25519 key.
- **Fingerprint:** `SHA256:` followed by the unpadded base64 of the SHA-256 of
  the public key's SubjectPublicKeyInfo (DER).
- **Pinning:** the hub allows the fingerprints added with `SHARD ADD`, and the
  shard allows only its configured `hub_fingerprint`.

## Handshake

A signed message is the JSON `{"m": "<message as JSON>", "s": "<base64 Ed25519 signature of m>"}`.
The message's `id` is the signer's raw public key in base64, and it is checked
against the signature.

1. **The shard's hello:**

   ```
   {"t":"hello","v":1,"id":…,"eph":<raw X25519 public key>,"nonce":<16 random bytes>,"at":<unix time>,
    "name":"myshard","network":"EFnet"}
   ```

   The hub checks:
   - the signature;
   - that `at` is within 300 seconds;
   - that the fingerprint is on the allowlist;
   - that the network matches;
   - that the nonce hasn't been seen before.

2. **The hub's welcome:**

   ```
   {"t":"welcome","v":1,"id":…,"eph":…,"nonce":…,"at":…,"to":<the hello's nonce>,"network":"EFnet"}
   ```

   The shard checks:
   - the signature;
   - that the fingerprint is the pinned one;
   - that `to` is its own hello's nonce;
   - that `at` is within 300 seconds.

3. **Session keys.** Both sides compute the X25519 shared secret from the two
   ephemeral keys, then:

   ```
   okm = HKDF-SHA256(secret, salt = shard_nonce ‖ hub_nonce,
                     info = "gemshard v1 <shard fingerprint> <hub fingerprint>", 64 bytes)
   ```

   - the first 32 bytes are the shard→hub key, the last 32 the hub→shard key;
   - the session id is the first 12 hex digits of SHA-256(shard_nonce ‖ hub_nonce).

## Messages

- **Encoding:** `base64(counter (8 bytes, big-endian) ‖ ciphertext ‖ tag (16 bytes))`.
- **Encryption:** AES-256-GCM with the direction's key, IV `00000000 ‖ counter`,
  associated data `"gs1"`.
- **Content:** the plaintext is zlib-deflated JSON.
- **Counters** start at 1 for each direction, and a message must carry a higher
  counter than the last one received.

| From | Message |
| --- | --- |
| hub | `{"t":"state", "network", "hub":{nick,userhost,gecos}, "bots":[{name,nick,userhost,server}], "admins":[…], "channels":[{name,key,access:{account:level},masks:[[mask,level]],mlock}], "sessions":[{nick,userhost,account}]}`, sent when it changes |
| hub | `{"t":"ping"}`, every 120 s |
| shard | `{"t":"status","nick","userhost","server"}`, when it changes (the hub takes nick and user@host from the lines themselves) |
| shard | `{"t":"pong"}` |

A session ends when nothing has arrived for 330 seconds; the shard then starts a
new one.

## Transport

The link runs over IRC only: nothing listens on a port.

- **IRC:** NOTICEs to the other side's nick. Each line is
  `GS1 <tag> <message id> <part>/<total> <base64 chunk>`, with chunks of up to
  300 characters and at most 64 parts. The tag is `h` for the handshake (the
  signed JSON, base64-encoded), or the session id for messages. The hub takes a
  shard's messages only from the nick (following its nick changes) and user@host
  it linked from. A shard takes the hub's from any nick, since only the hub can
  seal them, and so follows the hub to a new nick.
