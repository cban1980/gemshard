require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"
require "zlib"

module Gemshard
  # The secure layer between a shard and its hub, the same over IRC notices
  # and over the TLS link (docs/protocol.md). This file is also in Gemdrop's
  # shards plugin; keep the two the same.
  #
  # Each side has an Ed25519 identity key; the other side pins its
  # fingerprint. A session starts with signed hellos carrying fresh X25519
  # keys; HKDF turns their shared secret into one AES-256-GCM key per
  # direction. Every message is then compressed, encrypted and numbered:
  # nothing can be read, changed or played again, and a new session has
  # new keys (forward secrecy).
  module Protocol
    VERSION = 1
    CLOCK_SKEW = 300         # seconds a hello's time may be off
    ED25519_SPKI = ["302a300506032b6570032100"].pack("H*").freeze
    X25519_SPKI = ["302a300506032b656e032100"].pack("H*").freeze
    IRC_TAG = "GS1"          # starts every IRC line of the protocol
    IRC_CHUNK = 300          # base64 characters per IRC line
    MAX_CHUNKS = 64
    MAX_MESSAGE = 256 * 1024 # bytes of a message, uncompressed

    class Error < StandardError; end

    module_function

    def b64(bytes) = Base64.strict_encode64(bytes)

    def unb64(text)
      Base64.strict_decode64(text.to_s)
    rescue ArgumentError
      raise Error, "bad base64"
    end

    def raw_public(key) = key.public_to_der[-32..]

    def ed25519_public(raw)
      raise Error, "a key is 32 bytes" unless raw.bytesize == 32

      OpenSSL::PKey.read(ED25519_SPKI + raw)
    end

    def x25519_public(raw)
      raise Error, "a key is 32 bytes" unless raw.bytesize == 32

      OpenSSL::PKey.read(X25519_SPKI + raw)
    end

    # "SHA256:..." of an Ed25519 public key (its SubjectPublicKeyInfo).
    def fingerprint(key) = "SHA256:#{b64(Digest::SHA256.digest(key.public_to_der)).delete('=')}"

    # --- the handshake: signed hellos -----------------------------------------------------------

    # A signed message: {"m" => json, "s" => signature}, as one string.
    def signed(identity, message)
      json = JSON.generate(message)
      JSON.generate("m" => json, "s" => b64(identity.sign(nil, json)))
    end

    # The message of a signed string, if the key in it ("id") signed it.
    # Returns [message, the signer's public key].
    def verify_signed(text)
      outer = JSON.parse(text)
      raise Error, "not a signed message" unless outer.is_a?(Hash) && outer["m"].is_a?(String)

      message = JSON.parse(outer["m"])
      raise Error, "not a signed message" unless message.is_a?(Hash)

      key = ed25519_public(unb64(message["id"]))
      raise Error, "bad signature" unless key.verify(nil, unb64(outer["s"]), outer["m"])

      [message, key]
    rescue JSON::ParserError, OpenSSL::PKey::PKeyError
      raise Error, "not a signed message"
    end

    def fresh?(message, now = Time.now.to_i) = (message["at"].to_i - now).abs <= CLOCK_SKEW

    # Half of a handshake: what this side keeps, and the hello to send.
    # type: "hello" (the shard) or "welcome" (the hub); fields: more to say.
    def start(identity, type, fields = {})
      ephemeral = OpenSSL::PKey.generate_key("X25519")
      nonce = SecureRandom.random_bytes(16)
      message = { "t" => type, "v" => VERSION, "id" => b64(raw_public(identity)), "eph" => b64(raw_public(ephemeral)),
                  "nonce" => b64(nonce), "at" => Time.now.to_i }.merge(fields)
      [{ ephemeral: ephemeral, nonce: nonce }, signed(identity, message)]
    end

    # The session from both hellos. mine: what start kept; theirs: the other
    # side's verified hello; shard: true on the shard's side.
    def session(mine, theirs, my_key, their_key, shard:)
      shared = mine[:ephemeral].derive(x25519_public(unb64(theirs["eph"])))
      shard_nonce, hub_nonce = shard ? [mine[:nonce], unb64(theirs["nonce"])] : [unb64(theirs["nonce"]), mine[:nonce]]
      shard_fp, hub_fp = shard ? [fingerprint(my_key), fingerprint(their_key)] : [fingerprint(their_key), fingerprint(my_key)]
      keys = OpenSSL::KDF.hkdf(shared, salt: shard_nonce + hub_nonce, info: "gemshard v1 #{shard_fp} #{hub_fp}",
                                       length: 64, hash: "SHA256")
      to_hub = keys.byteslice(0, 32)
      to_shard = keys.byteslice(32, 32)
      Session.new(shard ? to_hub : to_shard, shard ? to_shard : to_hub,
                  Digest::SHA256.hexdigest(shard_nonce + hub_nonce)[0, 12])
    end

    # One direction's key and counter each way. seal and open are the
    # messages' only way in and out once the handshake is done.
    class Session
      attr_reader :id

      def initialize(send_key, receive_key, id)
        @send_key = send_key
        @receive_key = receive_key
        @id = id
        @sent = 0
        @received = 0
        @lock = Mutex.new
      end

      # A message (a hash) as base64: counter, then AES-256-GCM of the
      # compressed JSON, then the tag.
      def seal(message)
        counter = @lock.synchronize { @sent += 1 }
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @send_key
        cipher.iv = iv(counter)
        cipher.auth_data = "gs1"
        data = cipher.update(Zlib::Deflate.deflate(JSON.generate(message))) + cipher.final
        Protocol.b64([counter].pack("Q>") + data + cipher.auth_tag)
      end

      # The message in a sealed string; raises Error if it was changed,
      # isn't for this session, or was seen before.
      def open(text)
        bytes = Protocol.unb64(text)
        raise Error, "too short" if bytes.bytesize < 8 + 16

        counter = bytes.byteslice(0, 8).unpack1("Q>")
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = @receive_key
        cipher.iv = iv(counter)
        cipher.auth_tag = bytes.byteslice(-16, 16)
        cipher.auth_data = "gs1"
        plain = cipher.update(bytes.byteslice(8, bytes.bytesize - 24)) + cipher.final
        @lock.synchronize do
          raise Error, "played again" if counter <= @received

          @received = counter
        end
        json = Zlib::Inflate.new.then { |z| z.inflate(plain).tap { z.close } }
        raise Error, "too big" if json.bytesize > MAX_MESSAGE

        message = JSON.parse(json)
        raise Error, "not a message" unless message.is_a?(Hash)

        message
      rescue OpenSSL::Cipher::CipherError
        raise Error, "not ours (changed, or another session's)"
      rescue Zlib::Error, JSON::ParserError
        raise Error, "not a message"
      end

      private

      def iv(counter) = "\0\0\0\0#{[counter].pack('Q>')}".b
    end

    # --- IRC: lines of at most IRC_CHUNK characters ---------------------------------------------------

    # "GS1 <tag> <i>/<n> <part>" lines for a payload (a hello, or a sealed
    # message); tag says what it is ("h" for handshakes, else the session id).
    def irc_lines(tag, payload)
      text = tag == "h" ? b64(payload) : payload
      parts = text.scan(/.{1,#{IRC_CHUNK}}/)
      raise Error, "too big for IRC" if parts.size > MAX_CHUNKS

      message_id = SecureRandom.hex(3)
      parts.each_with_index.map { |part, i| "#{IRC_TAG} #{tag} #{message_id} #{i + 1}/#{parts.size} #{part}" }
    end

    # Puts IRC lines back together, per sender. feed returns [tag, payload]
    # once a message is complete, else nil.
    class Assembler
      TIMEOUT = 120

      def initialize = @pending = {}

      def feed(sender, line)
        _proto, tag, message_id, position, part = line.split(" ", 5)
        index, total = position.to_s.split("/").map(&:to_i)
        return nil unless tag && part && total.to_i.between?(1, MAX_CHUNKS) && index.between?(1, total)

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @pending.delete_if { |_, entry| entry[:at] < now - TIMEOUT }
        entry = (@pending[[sender.downcase, message_id]] ||= { parts: {}, total: total, at: now, tag: tag })
        return nil unless entry[:total] == total && entry[:tag] == tag

        entry[:parts][index] = part
        return nil unless entry[:parts].size == total

        @pending.delete([sender.downcase, message_id])
        text = (1..total).map { |i| entry[:parts][i] }.join
        [tag, tag == "h" ? Protocol.unb64(text) : text]
      end
    end
  end
end
