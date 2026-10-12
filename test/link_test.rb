require "test_helper"
require "socket"

class LinkTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("gemshard")
    @hub = FakeHub.new
    @identity = OpenSSL::PKey.generate_key("ED25519")
    @notices = []
    @messages = Queue.new
    @log = StringIO.new
  end

  def teardown
    @link&.stop
    @server&.close
    FileUtils.remove_entry(@dir)
  end

  def link(hub_fingerprint: @hub.fingerprint, address: nil)
    config = { "name" => "slay", "network" => "EFnet", "hub_nick" => "Linuks", "hub_fingerprint" => hub_fingerprint,
               "hub_address" => address }
    @link = Gemshard::Link.new(config: config, identity: @identity, logger: Logger.new(@log),
                               irc_notice: ->(nick, line) { @notices << [nick, line] }) { |m| @messages << m }
  end

  # The hub's side over IRC: our hello lines in, its welcome lines out.
  def irc_handshake(hub = @hub)
    @link.tick(irc_up: true)
    assembler = P::Assembler.new
    hello = nil
    @notices.each { |nick, line| hello = assembler.feed("me", line) || hello if nick == "Linuks" }
    P.irc_lines("h", hub.welcome_for(hello[1])).each { |line| @link.irc_line("Linuks", line) }
  end

  def test_links_over_irc_and_takes_the_hubs_messages
    link
    refute @link.linked?
    irc_handshake
    assert @link.linked?
    assert_equal :irc, @link.transport
    assert_equal "linked", @messages.pop["t"]
    P.irc_lines(@hub.session.id, @hub.session.seal("t" => "state", "channels" => [])).each { |l| @link.irc_line("Linuks", l) }
    assert_equal "state", @messages.pop["t"]
    @notices.clear
    assert @link.to_hub("t" => "status", "nick" => "Shard1")
    sealed = @notices.map(&:last).map { |l| l.split(" ", 5).last }.join
    assert_equal "Shard1", @hub.session.open(sealed)["nick"]
  end

  def test_only_the_pinned_hub_answering_our_hello
    link(hub_fingerprint: FakeHub.new.fingerprint)
    irc_handshake
    refute @link.linked?, "a welcome from another key"
    assert_match(/isn't the hub's/, @log.string)
    link
    @link.tick(irc_up: true)
    _mine, other_hello = P.start(OpenSSL::PKey.generate_key("ED25519"), "hello")
    P.irc_lines("h", @hub.welcome_for(other_hello)).each { |line| @link.irc_line("Linuks", line) }
    refute @link.linked?, "a welcome for someone else's hello"
  end

  def test_lines_from_others_are_ignored
    link
    irc_handshake
    @messages.pop
    P.irc_lines(@hub.session.id, @hub.session.seal("t" => "state")).each { |l| @link.irc_line("Mallory", l) }
    assert @messages.empty?
  end

  def test_links_over_tls_first
    @server = TCPServer.new("127.0.0.1", 0)
    port = @server.addr[1]
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.min_version = OpenSSL::SSL::TLS1_3_VERSION
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=hub")
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    ctx.key = key
    ctx.cert = cert
    hub = Thread.new do
      socket = OpenSSL::SSL::SSLSocket.new(@server.accept, ctx)
      socket.accept
      socket.write("#{@hub.welcome_for(socket.gets.chomp)}\n")
      socket.write("#{@hub.session.seal('t' => 'state', 'channels' => [])}\n")
      socket.gets
    end
    link(address: "127.0.0.1:#{port}")
    @link.start
    assert_equal "linked", @messages.pop["t"]
    assert_equal :tcp, @link.transport
    assert_equal "state", @messages.pop["t"]
    @link.to_hub("t" => "pong")
    assert_equal "pong", @hub.session.open(hub.value.chomp)["t"]
    @link.tick(irc_up: true)
    assert_empty @notices, "no hellos over IRC while the TLS link is up"
  end

  def test_a_quiet_hub_ends_the_session
    link
    irc_handshake
    @messages.pop
    @link.instance_variable_set(:@seen, Time.now.to_f - 400)
    @link.tick(irc_up: true)
    assert_equal "unlinked", @messages.pop["t"]
    refute @link.linked?
  end
end
