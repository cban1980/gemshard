require "test_helper"

class EnforcerTest < Minitest::Test
  def setup
    @roster = Gemshard::Roster.new
    @roster.joined("#chan")
    @roster.add("#chan", "Shard1", "shard@one.example", "o")
    @enforcer = Gemshard::Enforcer.new(name: "one", roster: @roster)
    @state = {
      "hub" => { "nick" => "Linuks", "userhost" => "~Linuks@hub.example" },
      "bots" => [{ "name" => "one", "nick" => "Shard1", "userhost" => "shard@one.example" },
                 { "name" => "two", "nick" => "Shard2", "userhost" => "shard@two.example" }],
      "admins" => ["root"],
      "sessions" => [{ "nick" => "alice", "userhost" => "alice@alice.example", "account" => "alice" },
                     { "nick" => "boss", "userhost" => "root@root.example", "account" => "root" }],
      "channels" => []
    }
    @chan = { "name" => "#chan", "access" => { "alice" => "op", "carol" => "voice" },
              "masks" => [["*!*bob@bob.example", "voice"]], "mlock" => "+nt-s" }
  end

  def plan = @enforcer.plan(@state, @chan, "#chan", "Shard1")

  def test_op_and_voice_for_who_should_have_them
    @roster.add("#chan", "alice", "alice@alice.example")
    @roster.add("#chan", "bob", "bob@bob.example")
    @roster.add("#chan", "boss", "root@root.example")
    @roster.add("#chan", "mallory", "alice@evil.example")
    @roster.channel("#chan")[:modes].merge!("n" => true, "t" => true)
    assert_equal ["MODE #chan +ovo alice bob boss"], plan, "login, mask and admin; never mallory"
  end

  def test_a_login_needs_the_same_user_at_host
    @roster.add("#chan", "alice", "alice@elsewhere.example")
    @roster.channel("#chan")[:modes].merge!("n" => true, "t" => true)
    assert_empty plan
  end

  def test_nothing_for_who_has_it_and_never_taking
    @roster.add("#chan", "alice", "alice@alice.example", "o")
    @roster.add("#chan", "bob", "bob@bob.example", "o") # more than his voice: left alone
    @roster.add("#chan", "eve", "eve@eve.example", "o") # no access at all: left alone too
    @roster.channel("#chan")[:modes].merge!("n" => true, "t" => true)
    assert_empty plan
  end

  def test_the_mode_lock
    @roster.channel("#chan")[:modes].merge!("s" => true, "t" => true)
    assert_equal ["MODE #chan +n-s"], plan
  end

  def test_bots_are_opped_where_nick_and_host_match
    @roster.channel("#chan")[:modes].merge!("n" => true, "t" => true)
    @roster.add("#chan", "Shard2", "shard@two.example")
    @roster.add("#chan", "Linuks", "~Linuks@thief.example")
    assert_equal ["MODE #chan +o Shard2"], plan, "not the hub's nick on another host"
  end

  def test_only_the_best_bot_present_acts
    @roster.add("#chan", "alice", "alice@alice.example")
    @roster.channel("#chan")[:modes].merge!("n" => true, "t" => true)
    @roster.add("#chan", "Linuks", "~Linuks@hub.example", "o")
    assert_empty plan, "the hub is here with op: it does it"
    @roster.member("#chan", "Linuks")[:modes].delete!("o")
    refute_empty plan, "the hub without op: the shard does it (and ops the hub)"
    assert_includes plan.first, "Linuks"
    two = Gemshard::Enforcer.new(name: "two", roster: @roster)
    @roster.add("#chan", "Shard2", "shard@two.example", "o")
    assert_empty two.plan(@state, @chan, "#chan", "Shard2"), "shard one is above shard two"
    @roster.member("#chan", "Shard1")[:modes].delete!("o")
    assert_empty plan, "without op, nothing"
  end

  def test_masks_and_keys
    assert Gemshard::Enforcer.mask_match?("*!*bob@bob.example", "Bob!~bob@BOB.example")
    refute Gemshard::Enforcer.mask_match?("*!*bob@bob.example", "bob!bob@evil.example")
    @roster.channel("#chan")[:modes].merge!("n" => true, "t" => true, "k" => "old")
    assert_equal ["MODE #chan -k+k old new"], @enforcer.plan(@state, @chan.merge("mlock" => "+ntk new"), "#chan", "Shard1")
  end
end
