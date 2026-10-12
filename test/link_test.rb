require "test_helper"

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
    FileUtils.remove_entry(@dir)
  end

  def link(hub_fingerprint: @hub.fingerprint)
    config = { "name" => "slay", "network" => "EFnet", "hub_gecos" => "Gemdrop", "hub_fingerprint" => hub_fingerprint }
    @hub_nick = "Linuks"
    @found = []
    @link = Gemshard::Link.new(config: config, identity: @identity, logger: Logger.new(@log),
                               hub_nick: -> { @hub_nick }, found_hub: ->(nick) { @found << nick },
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

  def test_forged_lines_are_ignored_whoever_sends_them
    link
    irc_handshake
    @messages.pop
    forged = FakeHub.new
    forged.welcome_for(P.start(OpenSSL::PKey.generate_key("ED25519"), "hello").last)
    P.irc_lines(@hub.session.id, forged.session.seal("t" => "state")).each { |l| @link.irc_line("Linuks", l) }
    assert @messages.empty?
    assert_equal ["Linuks"], @found
  end

  def test_the_hub_is_followed_to_a_new_nick
    link
    irc_handshake
    @messages.pop
    P.irc_lines(@hub.session.id, @hub.session.seal("t" => "ping")).each { |l| @link.irc_line("Linux2", l) }
    assert_equal "ping", @messages.pop["t"], "sealed by the hub: taken from its new nick"
    assert_equal %w[Linuks Linux2], @found
  end

  def test_no_hello_while_the_hub_is_nowhere
    link
    @hub_nick = nil
    @link.tick(irc_up: true)
    assert_empty @notices
  end

  def test_the_hub_quitting_ends_the_session_and_we_say_hello_again
    link
    irc_handshake
    @messages.pop
    @notices.clear
    @link.hub_quit
    assert_equal "unlinked", @messages.pop["t"]
    refute @link.linked?
    @link.tick(irc_up: true)
    refute_empty @notices, "a new hello right away"
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
