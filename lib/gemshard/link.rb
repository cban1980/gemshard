module Gemshard
  # The shard's link to its hub: a session over IRC notices to the hub's
  # nick. The hub must prove it is the one pinned (hub_fingerprint) in a
  # signed welcome. Messages from the hub go to on_message; to_hub goes to
  # the hub.
  class Link
    HELLO_EVERY = 60             # seconds between hellos while unlinked
    EXPIRE = 330                 # a session the hub is silent this long in is over

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
      @seen = 0
      @hello_at = 0
      @pending = nil
    end

    def linked? = @lock.synchronize { !@session.nil? }

    # Sends a message (a hash) to the hub; false when unlinked.
    def to_hub(message)
      session = @lock.synchronize { @session } or return false

      Protocol.irc_lines(session.id, session.seal(message)).each { |line| @irc_notice.call(@config["hub_nick"], line) }
      true
    end

    # Every second or so: hellos while unlinked, and an end to a session
    # the hub has gone quiet in.
    def tick(irc_up:)
      now = Time.now.to_f
      drop("the hub went quiet") if linked? && now - @seen > EXPIRE
      return if linked? || !irc_up || now - @hello_at < HELLO_EVERY

      @hello_at = now
      mine, hello = Protocol.start(@identity, "hello", "name" => @config["name"], "network" => @config["network"])
      @pending = mine
      Protocol.irc_lines("h", hello).each { |line| @irc_notice.call(@config["hub_nick"], line) }
    end

    # The hub quit IRC: its session went with it (a restarted hub knows
    # none), so hello again rather than wait out EXPIRE.
    def hub_quit
      drop("the hub quit IRC") if linked?
    end

    # A NOTICE from the hub's nick: part of a welcome or of a message.
    def irc_line(nick, line)
      return unless Roster.fold(nick) == Roster.fold(@config["hub_nick"]) && line.start_with?("#{Protocol::IRC_TAG} ")

      complete = @assembler.feed(nick, line) or return
      tag, payload = complete
      if tag == "h"
        welcome(payload, @pending) if @pending && !linked?
        return
      end
      session = @lock.synchronize { @session }
      return unless session && session.id == tag

      deliver(session.open(payload))
    rescue Protocol::Error => e
      @log.debug("Dropped a line from the hub: #{e.message}")
    end

    private

    # The hub's welcome: it must be signed by the pinned key and answer our hello.
    def welcome(payload, mine)
      message, key = Protocol.verify_signed(payload)
      unless Protocol.fingerprint(key) == @config["hub_fingerprint"]
        return @log.warn("A welcome from a key that isn't the hub's (#{Protocol.fingerprint(key)}); ignored")
      end
      unless message["t"] == "welcome" && message["to"] == Protocol.b64(mine[:nonce]) && Protocol.fresh?(message)
        return @log.warn("A welcome that doesn't answer our hello; ignored")
      end

      session = Protocol.session(mine, message, @identity, key, shard: true)
      @lock.synchronize do
        @session = session
        @seen = Time.now.to_f
      end
      @pending = nil
      @log.info("Linked to the hub (session #{session.id})")
      deliver({ "t" => "linked" })
    rescue Protocol::Error => e
      @log.warn("A bad welcome from the hub: #{e.message}")
    end

    def deliver(message)
      @seen = Time.now.to_f
      @on_message.call(message)
    end

    def drop(why)
      @lock.synchronize { @session = nil }
      @log.warn("Unlinked from the hub (#{why})")
      @hello_at = 0 # say hello again right away
      @on_message.call({ "t" => "unlinked" })
    end
  end
end
