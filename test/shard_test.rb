require "test_helper"

# The shard with a stand-in for its IRC connection.
class ShardTest < Minitest::Test
  class FakeIRC
    attr_reader :lines

    def initialize = @lines = []
    def write(line, urgent: false) = @lines << line
    def close = nil
  end

  def setup
    @dir = Dir.mktmpdir("gemshard")
    @config = { "name" => "one", "network" => "EFnet", "hub_nick" => "Linuks",
                "hub_fingerprint" => "SHA256:#{'A' * 43}", "data_dir" => @dir,
                "irc" => { "server" => "irc.example", "port" => 6697, "tls" => true, "tls_verify" => true,
                           "nick" => "Shard1", "alt_nicks" => [], "user" => "shard", "realname" => "Shard" } }
    start
  end

  def teardown = FileUtils.remove_entry(@dir)

  def start
    @shard = Gemshard::Shard.new(@config, logger: Logger.new(@log = StringIO.new))
    @irc = FakeIRC.new
    @shard.instance_variable_set(:@irc, @irc)
    line(":irc.example 001 Shard1 :Welcome")
  end

  def line(text) = @shard.handle(Gemshard::Message.parse(text))

  STATE = {
    "t" => "state", "network" => "EFnet", "hub" => { "nick" => "Linuks", "userhost" => "bot@hub.example" },
    "bots" => [{ "name" => "one", "nick" => "Shard1", "userhost" => "shard@one.example" }],
    "admins" => [], "sessions" => [{ "nick" => "alice", "userhost" => "alice@alice.example", "account" => "alice" }],
    "channels" => [{ "name" => "#chan", "key" => "sesame", "access" => { "alice" => "op" }, "masks" => [], "mlock" => nil },
                   { "name" => "#other", "key" => nil, "access" => {}, "masks" => [], "mlock" => nil }]
  }.freeze

  def enforce_now
    @shard.instance_variable_get(:@due).each_value { |entry| entry[0] = 0 }
    @shard.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
  end

  def in_chan
    line(":Shard1!shard@one.example JOIN #chan")
    line(":irc.example 353 Shard1 = #chan :@Shard1")
    @irc.lines.clear
  end

  def test_joins_and_parts_with_the_hub
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    assert_equal ["JOIN #chan sesame", "JOIN #other"], @irc.lines
    line(":Shard1!shard@one.example JOIN #chan")
    line(":Shard1!shard@one.example JOIN #stray")
    @irc.lines.clear
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    assert_includes @irc.lines, "PART #stray :Not one of the hub's channels"
    refute(@irc.lines.any? { |l| l.start_with?("PART #chan") })
  end

  def test_ops_who_should_have_op
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    in_chan
    line(":alice!alice@alice.example JOIN #chan")
    enforce_now
    assert_includes @irc.lines, "MODE #chan +o alice"
  end

  def test_the_state_is_kept_for_when_the_hub_is_away
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    assert_equal 0o600, File.stat(File.join(@dir, "state.json")).mode & 0o777
    start # a restart, with no hub
    assert_equal ["JOIN #chan sesame", "JOIN #other"], @irc.lines.grep(/JOIN/)
    in_chan
    line(":alice!alice@alice.example JOIN #chan")
    enforce_now
    assert_includes @irc.lines, "MODE #chan +o alice"
  end

  def test_a_quit_ends_a_login
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    in_chan
    line(":alice!alice@alice.example QUIT :bye")
    line(":alice!alice@alice.example JOIN #chan")
    enforce_now
    refute_includes @irc.lines, "MODE #chan +o alice", "she has to log in to the hub again"
  end

  def test_kicked_it_rejoins
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    in_chan
    line(":op!o@h KICK #chan Shard1 :out")
    refute @shard.roster.on?("#chan")
    @shard.instance_variable_get(:@rejoin).transform_values! { 0 }
    @shard.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
    assert_includes @irc.lines, "JOIN #chan sesame"
  end

  def test_shards_say_nothing_to_anyone
    @shard.hub_message(JSON.parse(JSON.generate(STATE)))
    @irc.lines.clear
    line(":alice!alice@alice.example PRIVMSG Shard1 :HELP")
    line(":alice!alice@alice.example NOTICE Shard1 :GS1 h x 1/1 junk")
    assert_empty @irc.lines
  end
end
