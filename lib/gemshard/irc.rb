require "openssl"
require "socket"

module Gemshard
  # One IRC line: prefix (nick, user@host), command and parameters.
  Message = Struct.new(:nick, :userhost, :command, :params) do
    def self.parse(line)
      line = line.to_s.sub(/\A@\S+ /, "").chomp
      prefix = nil
      prefix, line = line[1..].split(" ", 2) if line.start_with?(":")
      command, rest = line.to_s.split(" ", 2)
      params = []
      rest = rest.to_s
      until rest.empty?
        if rest.start_with?(":")
          params << rest[1..]
          break
        end
        word, rest = rest.split(" ", 2)
        params << word
        rest = rest.to_s
      end
      nick, userhost = prefix.to_s.split("!", 2)
      new(nick, userhost, command.to_s.upcase, params)
    end

    def text = params.last.to_s
  end

  # The connection to the IRC server: lines in and out, with flood control
  # the way servers count it (ircd 2: 2 seconds plus 1 per 120 bytes a
  # line, more than 10 seconds ahead and you are cut off). Sending never
  # blocks the caller; urgent lines (PONG) go first.
  class IRC
    LINE_COST = 2.0
    BYTES_PER_SECOND = 120.0
    LEAD = 8.0
    MAX_QUEUE = 500

    def initialize(host:, port:, tls:, tls_verify:, logger:)
      @host = host
      @port = port
      @tls = tls
      @tls_verify = tls_verify
      @log = logger
      @lock = Mutex.new
      @queued = ConditionVariable.new
      @urgent = []
      @normal = []
      @socket = nil
    end

    def connect
      tcp = Socket.tcp(@host, @port, connect_timeout: 30)
      tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
      socket = @tls ? wrap_tls(tcp) : tcp
      @lock.synchronize do
        @socket = socket
        @urgent.clear
        @normal.clear
      end
      @ahead = now
      @writer = Thread.new { write_loop(socket) }
    end

    def connected? = @lock.synchronize { !@socket.nil? }

    # A line from the server, or nil when the connection is gone.
    def gets(timeout = 300)
      socket = @lock.synchronize { @socket } or return nil
      return nil unless socket.wait_readable(timeout)

      line = socket.gets("\r\n", 8704) or return nil
      line.force_encoding(Encoding::UTF_8).scrub.chomp
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    def write(line, urgent: false)
      @lock.synchronize do
        return false unless @socket

        line = line.delete("\r\n")
        if urgent then @urgent << line
        elsif @normal.size < MAX_QUEUE then @normal << line
        else return false
        end
        @queued.signal
        true
      end
    end

    def close
      socket = @lock.synchronize { @socket.tap { @socket = nil; @queued.broadcast } }
      socket&.close
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    private

    def wrap_tls(tcp)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      if @tls_verify
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      else
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      tls = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      tls.hostname = @host
      tls.sync_close = true
      tls.connect
      tls.post_connection_check(@host) if @tls_verify
      tls
    end

    def write_loop(socket)
      loop do
        line = @lock.synchronize do
          @queued.wait(@lock) while @socket.equal?(socket) && @urgent.empty? && @normal.empty?
          break nil unless @socket.equal?(socket)

          @urgent.shift || @normal.shift
        end
        break unless line

        throttle(line)
        socket.write("#{line}\r\n")
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      @log.warn("IRC write failed: #{e.message}")
      close
    end

    def throttle(line)
      cost = LINE_COST + (line.bytesize + 2) / BYTES_PER_SECOND
      @ahead = [@ahead, now].max
      wait = @ahead + cost - now - LEAD
      sleep(wait) if wait.positive?
      @ahead += cost
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # What the shard sees of its channels: members with their user@host and
  # modes, and the channels' modes. Names compare the IRC way (rfc1459).
  class Roster
    attr_reader :isupport

    def initialize
      @channels = {}
      @isupport = { "PREFIX" => "(ov)@+", "CHANMODES" => "beI,k,l,imnpst", "MODES" => "3" }
    end

    def self.fold(name) = name.to_s.downcase.tr("[]\\~", "{}|^")
    def fold(name) = self.class.fold(name)

    def clear = @channels.clear

    def channels = @channels.values.map { |c| c[:name] }
    def channel(name) = @channels[fold(name)]
    def on?(name) = @channels.key?(fold(name))

    def joined(name) = (@channels[fold(name)] ||= { name: name, members: {}, modes: {} })
    def parted(name) = @channels.delete(fold(name))

    def member(channel, nick) = channel(channel)&.dig(:members, fold(nick))

    def add(channel, nick, userhost = nil, modes = "")
      chan = channel(channel) or return
      entry = (chan[:members][fold(nick)] ||= { nick: nick, userhost: nil, modes: +"" })
      entry[:nick] = nick
      entry[:userhost] = userhost if userhost
      modes.each_char { |m| entry[:modes] << m unless entry[:modes].include?(m) }
      entry
    end

    def remove(channel, nick) = channel(channel)&.dig(:members)&.delete(fold(nick))
    def quit(nick) = @channels.each_value { |c| c[:members].delete(fold(nick)) }

    def rename(old, new)
      @channels.each_value do |c|
        entry = c[:members].delete(fold(old)) or next
        entry[:nick] = new
        c[:members][fold(new)] = entry
      end
    end

    # A RPL_ISUPPORT (005) line's tokens.
    def support(tokens)
      tokens.each do |token|
        name, value = token.split("=", 2)
        @isupport[name.upcase] = value.to_s unless name.start_with?("-") || name.include?(" ")
      end
    end

    # "(ov)@+" as { "@" => "o", "+" => "v" }.
    def prefixes
      modes, symbols = @isupport["PREFIX"].to_s.match(/\A\((\w+)\)(\S+)\z/)&.captures || %w[ov @+]
      symbols.chars.zip(modes.chars).to_h
    end

    def status_modes = prefixes.values

    # NAMES (353): "@alice +bob carol" (also with several prefixes).
    def names(channel, list)
      symbols = prefixes
      list.split.each do |item|
        modes = +""
        while symbols.key?(item[0])
          modes << symbols[item[0]]
          item = item[1..]
        end
        nick, userhost = item.split("!", 2)
        add(channel, nick, userhost, modes)
      end
    end

    # WHO (352): user, host, nick and flags ("H@").
    def who(channel, user, host, nick, flags)
      modes = flags.to_s.chars.filter_map { |c| prefixes[c] }.join
      add(channel, nick, "#{user}@#{host}", modes) if on?(channel)
    end

    # A MODE line's changes to the members and the channel's modes.
    def mode(channel, modestring, params)
      chan = channel(channel) or return []
      lists, always, when_set, _flags = (@isupport["CHANMODES"].to_s.split(",", -1) + ["", "", "", ""]).first(4)
      status = status_modes
      params = params.dup
      sign = "+"
      changes = []
      modestring.to_s.each_char do |char|
        next sign = char if "+-".include?(char)

        if status.include?(char)
          nick = params.shift or next
          entry = member(channel, nick) or next
          sign == "+" ? (entry[:modes] << char unless entry[:modes].include?(char)) : entry[:modes].delete!(char)
        elsif lists.include?(char)
          params.shift
        elsif always.include?(char) || (when_set.include?(char) && sign == "+")
          value = params.shift
          sign == "+" ? chan[:modes][char] = value.to_s : chan[:modes].delete(char)
        else
          sign == "+" ? chan[:modes][char] = true : chan[:modes].delete(char)
        end
        changes << [sign, char]
      end
      changes
    end

    # RPL_CHANNELMODEIS (324): the channel's modes now.
    def channel_modes(channel, modestring, params)
      chan = channel(channel) or return
      chan[:modes] = {}
      mode(channel, modestring, params)
    end
  end
end
