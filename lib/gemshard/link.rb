require "openssl"
require "socket"
require "timeout"

module Gemshard
  # The shard's link to its hub: a session over the TLS link when it can
  # reach it, else over IRC notices to the hub's nick. Either way the hub
  # must prove it is the one pinned (hub_fingerprint) in a signed welcome.
  # Messages from the hub go to on_message; send goes to the hub.
  class Link
    HANDSHAKE_SECONDS = 15
    IRC_HELLO_EVERY = 60         # seconds between hellos over IRC while unlinked
    EXPIRE = { tcp: 70, irc: 330 }.freeze

    attr_reader :transport

    # irc_notice: ->(nick, line) sends a NOTICE over IRC.
    def initialize(config:, identity:, logger:, irc_notice:, &on_message)
      @config = config
      @identity = identity
      @log = logger
      @irc_notice = irc_notice
      @on_message = on_message
      @assembler = Protocol::Assembler.new
      @lock = Mutex.new
      @session = nil
      @transport = nil
      @seen = 0
      @irc_hello_at = 0
      @irc_pending = nil
    end

    def linked? = @lock.synchronize { !@session.nil? }

    def start
      return unless @config["hub_address"]

      @tcp_thread = Thread.new { tcp_loop }
    end

    def stop
      @tcp_thread&.kill
      @socket&.close
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    # Sends a message (a hash) to the hub; false when unlinked.
    def to_hub(message)
      session, transport = @lock.synchronize { [@session, @transport] }
      return false unless session

      sealed = session.seal(message)
      if transport == :tcp
        @socket.write("#{sealed}\n")
      else
        Protocol.irc_lines(session.id, sealed).each { |line| @irc_notice.call(@config["hub_nick"], line) }
      end
      true
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      drop(:tcp, "the TLS link broke")
      false
    end

    # Every second or so: hellos over IRC while unlinked, and an end to a
    # session the hub has gone quiet in.
    def tick(irc_up:)
      now = Time.now.to_f
      transport = @lock.synchronize { @transport }
      drop(transport, "the hub went quiet") if transport && now - @seen > EXPIRE[transport]
      return if linked? || !irc_up || now - @irc_hello_at < IRC_HELLO_EVERY

      @irc_hello_at = now
      mine, hello = Protocol.start(@identity, "hello", "name" => @config["name"], "network" => @config["network"])
      @irc_pending = mine
      Protocol.irc_lines("h", hello).each { |line| @irc_notice.call(@config["hub_nick"], line) }
    end

    # A NOTICE from the hub's nick: part of a welcome or of a message.
    def irc_line(nick, line)
      return unless Roster.fold(nick) == Roster.fold(@config["hub_nick"]) && line.start_with?("#{Protocol::IRC_TAG} ")

      complete = @assembler.feed(nick, line) or return
      tag, payload = complete
      if tag == "h"
        welcome(payload, :irc, @irc_pending) if @irc_pending && !linked?
        return
      end
      session = @lock.synchronize { @transport == :irc ? @session : nil }
      return unless session && session.id == tag

      deliver(session.open(payload))
    rescue Protocol::Error => e
      @log.debug("Dropped a line from the hub: #{e.message}")
    end

    private

    # The hub's welcome: it must be signed by the pinned key and answer our hello.
    def welcome(payload, transport, mine)
      message, key = Protocol.verify_signed(payload)
      unless Protocol.fingerprint(key) == @config["hub_fingerprint"]
        return @log.warn("A welcome from a key that isn't the hub's (#{Protocol.fingerprint(key)}); ignored")
      end
      unless message["t"] == "welcome" && message["to"] == Protocol.b64(mine[:nonce]) && Protocol.fresh?(message)
        return @log.warn("A welcome that doesn't answer our hello; ignored")
      end

      session = Protocol.session(mine, message, @identity, key, shard: true)
      @lock.synchronize do
        return if @transport == :tcp && transport == :irc # the link is better

        @session = session
        @transport = transport
        @seen = Time.now.to_f
      end
      @irc_pending = nil if transport == :irc
      @log.info("Linked to the hub over #{transport == :tcp ? 'TLS' : 'IRC'} (session #{session.id})")
      deliver({ "t" => "linked", "transport" => transport.to_s })
      true
    rescue Protocol::Error => e
      @log.warn("A bad welcome from the hub: #{e.message}")
      false
    end

    def deliver(message)
      @seen = Time.now.to_f
      @on_message.call(message)
    end

    def drop(transport, why)
      dropped = @lock.synchronize do
        next false unless @transport == transport

        @session = nil
        @transport = nil
        true
      end
      @socket&.close if transport == :tcp
      return unless dropped

      @log.warn("Unlinked from the hub (#{why})")
      @irc_hello_at = 0 # say hello over IRC right away
      @on_message.call({ "t" => "unlinked" })
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    # The TLS link: connect, hello, welcome, then the hub's messages, and
    # again after a pause when it breaks.
    def tcp_loop
      delay = 5
      loop do
        if tcp_session
          delay = 5
          tcp_read
        end
        sleep delay
        delay = [delay * 2, 60].min
      end
    end

    def tcp_session
      host, _, port = @config["hub_address"].to_s.rpartition(":")
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_3_VERSION
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE # the signed welcome settles who it is
      tcp = Socket.tcp(host.delete("[]"), port.to_i, connect_timeout: 15)
      socket = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      socket.sync_close = true
      Timeout.timeout(HANDSHAKE_SECONDS) { socket.connect }
      mine, hello = Protocol.start(@identity, "hello", "name" => @config["name"], "network" => @config["network"])
      socket.write("#{hello}\n")
      line = Timeout.timeout(HANDSHAKE_SECONDS) { socket.gets("\n", 4096) }
      return socket.close && false unless line

      @socket = socket
      welcome(line.chomp, :tcp, mine) || (socket.close && false)
    rescue OpenSSL::SSL::SSLError, IOError, SystemCallError, SocketError, Timeout::Error => e
      @log.debug("The TLS link to the hub failed: #{e.class}: #{e.message}")
      false
    end

    def tcp_read
      loop do
        line = @socket.gets("\n", 16 * 1024 * 1024) or break
        session = @lock.synchronize { @transport == :tcp ? @session : nil } or break
        deliver(session.open(line.chomp))
      rescue Protocol::Error => e
        @log.warn("Something from the hub that isn't ours (#{e.message}); unlinking")
        break
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      drop(:tcp, "the TLS link closed")
    end
  end
end
