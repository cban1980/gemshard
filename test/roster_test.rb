require "test_helper"

class RosterTest < Minitest::Test
  def setup
    @roster = Gemshard::Roster.new
    @roster.joined("#Chan")
  end

  def test_names_who_and_modes
    @roster.names("#chan", "@alice +bob carol")
    assert_equal "o", @roster.member("#CHAN", "alice")[:modes]
    @roster.who("#chan", "~bob", "bob.example", "bob", "H+")
    assert_equal "~bob@bob.example", @roster.member("#chan", "bob")[:userhost]
    @roster.mode("#chan", "+o-v+nk", %w[carol bob sesame])
    assert_equal "o", @roster.member("#chan", "carol")[:modes]
    assert_equal "", @roster.member("#chan", "bob")[:modes]
    assert_equal({ "n" => true, "k" => "sesame" }, @roster.channel("#chan")[:modes])
    @roster.mode("#chan", "-k+b", ["sesame", "*!*@bad"])
    assert_equal({ "n" => true }, @roster.channel("#chan")[:modes])
  end

  def test_nicks_quits_and_rfc1459_names
    @roster.add("#chan", "Nick[a]", "u@h")
    assert @roster.member("#chan", "nick{A}")
    @roster.rename("nick{a}", "new")
    assert_equal "new", @roster.member("#chan", "NEW")[:nick]
    @roster.quit("new")
    assert_nil @roster.member("#chan", "new")
  end

  def test_isupport_prefixes
    @roster.support(["PREFIX=(qaohv)~&@%+", "MODES=4"])
    @roster.names("#chan", "~&@dave")
    assert_equal "qao", @roster.member("#chan", "dave")[:modes]
  end
end
