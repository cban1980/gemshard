require "test_helper"

class ProtocolTest < Minitest::Test
  def setup
    @shard = OpenSSL::PKey.generate_key("ED25519")
    @hub = FakeHub.new
    mine, hello = P.start(@shard, "hello", "name" => "slay", "network" => "EFnet")
    welcome = @hub.welcome_for(hello)
    message, hub_key = P.verify_signed(welcome)
    @session = P.session(mine, message, @shard, hub_key, shard: true)
  end

  def test_both_sides_get_the_same_session
    assert_equal @hub.session.id, @session.id
    assert_equal({ "t" => "state", "n" => 1 }, @session.open(@hub.session.seal("t" => "state", "n" => 1)))
    assert_equal "status", @hub.session.open(@session.seal("t" => "status"))["t"]
  end

  def test_nothing_can_be_played_again_changed_or_turned_around
    sealed = @hub.session.seal("t" => "ping")
    @session.open(sealed)
    assert_raises(P::Error) { @session.open(sealed) }
    bytes = P.unb64(@hub.session.seal("t" => "ping"))
    bytes.setbyte(12, bytes.getbyte(12) ^ 1)
    assert_raises(P::Error) { @session.open(P.b64(bytes)) }
    assert_raises(P::Error) { @session.open(@session.seal("t" => "mine")) }
  end

  def test_a_forged_or_old_hello_is_caught
    _mine, hello = P.start(@shard, "hello", "name" => "slay")
    assert_raises(P::Error) { P.verify_signed(hello.sub("slay", "evil")) }
    message, = P.verify_signed(hello)
    assert P.fresh?(message)
    refute P.fresh?(message, Time.now.to_i + 3600)
  end

  def test_irc_lines_and_reassembly
    sealed = @hub.session.seal("t" => "state", "blob" => "x" * 5000)
    lines = P.irc_lines(@session.id, sealed)
    assert(lines.all? { |l| l.bytesize <= 340 && l.start_with?("GS1 #{@session.id} ") })
    assembler = P::Assembler.new
    got = nil
    lines.reverse_each { |l| got = assembler.feed("Hub", l) || got }
    assert_equal "x" * 5000, @session.open(got[1])["blob"]
  end
end
