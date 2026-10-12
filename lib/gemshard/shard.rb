require "json"
require "logger"
require "monitor"

module Gemshard
  # A shard: on IRC with its own nick, in the hub's channels, setting what
  # should be set when it is the bot to do it. Everything it knows comes
  # from the hub's state (kept on disk, so it works on while the hub is
  # away); everything it says goes to the hub.
  class Shard
    ENFORCE_DELAY = (1.5..4.0)   # seconds after a change, so bots don't all jump at once
    RECHECK_EVERY = 60
    MAX_MODE_LINES = 12          # per channel in 30 seconds, so two bots can't fight forever
    STATUS_EVERY = 60
    STATUS_FILE_EVERY = 30       # data/status.json, for the container's health check

    def initialize(config, logger: Logger.new($stdout))
      @config = config
      @log = logger
      @identity = Identity.load(config["data_dir"])
      @roster = Roster.new
      @enforcer = Enforcer.new(name: config["name"], roster: @roster)
      @lock = Monitor.new
      @state = load_state
      @due = {}
      @mode_lines = Hash.new { |h, k| h[k] = [] }
      @rejoin = {}
      @nick = config.dig("irc", "nick")
      @userhost = nil
      @server = nil
      @registered = false
      @status_sent = nil
      @status_at = 0
      @status_file_at = nil
      @link = Link.new(config: config, identity: @identity, logger: logger,
                       irc_notice: ->(nick, line) { @irc&.write("NOTICE #{nick} :#{line}") }) { |m| @lock.synchronize { hub_message(m) } }
    end

    attr_reader :state, :roster, :nick

    def fingerprint = Protocol.fingerprint(@identity)

    def run
      @log.info("Gemshard #{@config['name']} for #{@config['network']}; key #{fingerprint}")
      @log.info("Using the saved state (#{@state['channels'].size} channels) until the hub is linked") if @state["channels"]&.any?
      @timer = Thread.new { timer_loop }
      delay = 5
      loop do
        if connect_irc
          delay = 5
          while (line = @irc.gets(330))
            @lock.synchronize { handle(Message.parse(line)) }
          end
          @lock.synchronize { irc_lost }
        end
        sleep delay
        delay = [delay * 2, 120].min
      end
    end

    def stop(reason = "Gemshard")
      @irc&.write("QUIT :#{reason}", urgent: true)
      sleep 1
      @irc&.close
    end

    # --- IRC ------------------------------------------------------------------------------------

    def connect_irc
      irc = @config["irc"]
      @irc = IRC.new(host: irc["server"], port: irc["port"].to_i, tls: irc["tls"], tls_verify: irc["tls_verify"],
                     logger: @log)
      @irc.connect
      @nicks = [irc["nick"], *irc["alt_nicks"]]
      @irc.write("NICK #{@nicks.first}", urgent: true)
      @irc.write("USER #{irc['user']} 0 * :#{irc['realname']}", urgent: true)
      @log.info("Connected to #{irc['server']}:#{irc['port']}")
      true
    rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      @log.warn("Can't connect to #{irc['server']}: #{e.message}")
      false
    end

    def irc_lost
      @log.warn("Disconnected from IRC")
      @registered = false
      @roster.clear
      @irc&.close
    end

    # One line from the server.
    def handle(msg)
      case msg.command
      when "PING" then @irc.write("PONG :#{msg.text}", urgent: true)
      when "001"
        @registered = true
        @nick = msg.params[0]
        @server = msg.nick
        @log.info("On IRC as #{@nick} (#{@server})")
        sync_channels
      when "005" then @roster.support(msg.params[1..-2])
      when "433" then next_nick unless @registered
      when "JOIN" then joined(msg)
      when "PART" then left(msg.params[0], msg.nick)
      when "KICK" then left(msg.params[0], msg.params[1], kicked: true)
      when "QUIT" then quit(msg.nick)
      when "NICK" then renamed(msg.nick, msg.text)
      when "MODE"
        return unless channel?(msg.params[0])

        @roster.mode(msg.params[0], msg.params[1], msg.params[2..])
        schedule(msg.params[0])
      when "353" then @roster.names(msg.params[2], msg.text)
      when "352" then @roster.who(msg.params[1], msg.params[2], msg.params[3], msg.params[5], msg.params[6])
      when "324"
        @roster.channel_modes(msg.params[1], msg.params[2], msg.params[3..])
        schedule(msg.params[1])
      when "315", "366" then schedule(msg.params[1])
      when "NOTICE" # only the hub's protocol lines are listened to
        @link.irc_line(msg.nick.to_s, msg.text) if same?(msg.params[0], @nick)
      end
    end

    def next_nick
      @nicks.rotate!
      nick = @nicks.first == @config.dig("irc", "nick") ? "#{@config.dig('irc', 'nick')}_" : @nicks.first
      @irc.write("NICK #{nick}", urgent: true)
    end

    def joined(msg)
      channel = msg.params[0]
      if same?(msg.nick, @nick)
        @roster.joined(channel)
        @userhost = msg.userhost if msg.userhost
        @irc.write("MODE #{channel}")
        @irc.write("WHO #{channel}")
      else
        @roster.add(channel, msg.nick, msg.userhost)
      end
      schedule(channel)
    end

    def left(channel, nick, kicked: false)
      if same?(nick, @nick)
        @roster.parted(channel)
        @rejoin[Roster.fold(channel)] = now + 10 if kicked && wanted(channel)
      else
        @roster.remove(channel, nick)
      end
    end

    def quit(nick)
      @roster.quit(nick)
      # A quit ends a login: until the hub says otherwise, they are logged out.
      @state["sessions"]&.reject! { |s| same?(s["nick"], nick) }
      @link.hub_quit if same?(nick, @config["hub_nick"])
    end

    def renamed(old, new)
      @roster.rename(old, new)
      @nick = new if same?(old, @nick)
      @state["sessions"]&.each { |s| s["nick"] = new if same?(s["nick"], old) }
      @roster.channels.each { |channel| schedule(channel) }
    end

    # --- the hub ---------------------------------------------------------------------------------

    def hub_message(message)
      case message["t"]
      when "state"
        @state = message
        save_state
        @log.info("The hub's state: #{@state['channels'].size} channels, #{Array(@state['bots']).size} shards")
        sync_channels
        @roster.channels.each { |channel| schedule(channel) }
      when "ping" then @link.to_hub("t" => "pong")
      when "linked" then @status_sent = nil
      end
    end

    def status
      { "t" => "status", "nick" => @nick, "userhost" => @userhost, "server" => @server }
    end

    def send_status
      return unless @link.linked? && @registered

      now_status = status
      return if now_status == @status_sent
      return if now - @status_at < STATUS_EVERY && @status_sent

      @status_sent = now_status if @link.to_hub(now_status)
      @status_at = now
    end

    # --- channels and enforcing --------------------------------------------------------------------

    def wanted(channel) = Array(@state["channels"]).find { |c| same?(c["name"], channel) }

    # In the hub's channels, and only those (once the hub has said which).
    def sync_channels
      return unless @registered && @state["channels"]

      @state["channels"].each do |c|
        next if @roster.on?(c["name"])

        @irc.write(["JOIN", c["name"], c["key"]].compact.join(" "))
      end
      @roster.channels.each { |channel| @irc.write("PART #{channel} :Not one of the hub's channels") unless wanted(channel) }
    end

    def schedule(channel)
      at = now + rand(ENFORCE_DELAY)
      key = Roster.fold(channel)
      @due[key] = [at, channel] unless @due[key] && @due[key][0] <= at
    end

    def enforce(channel)
      channel_state = wanted(channel) or return
      return unless @roster.on?(channel)

      lines = @enforcer.plan(@state, channel_state, channel, @nick)
      return if lines.empty?

      recent = @mode_lines[Roster.fold(channel)]
      recent.reject! { |at| at < now - 30 }
      if recent.size + lines.size > MAX_MODE_LINES
        @log.warn("Not setting modes in #{channel} for now: they keep being changed back")
        return
      end
      lines.each do |line|
        recent << now
        @irc.write(line)
      end
      @log.info("#{channel}: #{lines.join(' / ')}")
    end

    def timer_loop
      last_recheck = now
      loop do
        sleep 1
        @lock.synchronize { tick(last_recheck) }
        last_recheck = now if now - last_recheck >= RECHECK_EVERY
      rescue StandardError => e
        @log.error("#{e.class}: #{e.message}")
      end
    end

    def tick(last_recheck)
      @link.tick(irc_up: @registered)
      send_status
      write_status_file if @status_file_at.nil? || now - @status_file_at >= STATUS_FILE_EVERY
      @due.select { |_, (at, _)| at <= now }.each do |key, (_, channel)|
        @due.delete(key)
        enforce(channel)
      end
      @rejoin.select { |_, at| at <= now }.each_key do |key|
        @rejoin.delete(key)
        sync_channels
      end
      @roster.channels.each { |channel| schedule(channel) } if now - last_recheck >= RECHECK_EVERY
    end

    # --- helpers ------------------------------------------------------------------------------------

    def state_path = File.join(@config["data_dir"], "state.json")

    def load_state
      state = JSON.parse(File.read(state_path))
      state.is_a?(Hash) && state["network"].to_s.casecmp?(@config["network"]) ? state : {}
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    def save_state
      tmp = "#{state_path}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(@state)) }
      File.rename(tmp, state_path)
    end

    # What gemshard-docker status and the health check read.
    def write_status_file
      @status_file_at = now
      status = { "name" => @config["name"], "network" => @config["network"],
                 "irc" => @registered ? "connected" : "disconnected", "nick" => @nick, "server" => @server,
                 "linked" => @link.linked?, "channels" => @roster.channels.size,
                 "hub_channels" => Array(@state["channels"]).size, "updated_at_unix" => Time.now.to_i }
      path = File.join(@config["data_dir"], "status.json")
      File.open("#{path}.tmp", File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(status)) }
      File.rename("#{path}.tmp", path)
    rescue SystemCallError => e
      @log.warn("Can't write #{path}: #{e.message}")
    end

    def channel?(name) = name.to_s.start_with?("#", "&", "!", "+")
    def same?(a, b) = !a.nil? && !b.nil? && Roster.fold(a) == Roster.fold(b)
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
