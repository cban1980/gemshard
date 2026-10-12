require "test_helper"

# The join code is made by Gemdrop's shards plugin (SHARD INFO); this is its format.
class JoinCodeTest < Minitest::Test
  FP = "SHA256:#{'A' * 43}".freeze

  def code(data) = "gemshard1:#{Base64.urlsafe_encode64(JSON.generate(data), padding: false)}"

  def test_the_hubs_details_from_one_line
    details = Gemshard::JoinCode.decode(" #{code('n' => 'EFnet', 'g' => 'Linuks punkt ess ee', 'h' => 'Linuks', 'f' => FP)}\n")
    assert_equal({ "network" => "EFnet", "hub_gecos" => "Linuks punkt ess ee", "hub_nick" => "Linuks", "hub_fingerprint" => FP },
                 details)
  end

  def test_damaged_or_wrong_codes_are_refused
    good = code("n" => "EFnet", "g" => "Hub", "h" => "Linuks", "f" => FP)
    [good[0, 30], "nonsense", code("n" => "EFnet", "g" => "Hub", "h" => "Linuks", "f" => "SHA256:short"),
     code("n" => "EF net;rm", "g" => "Hub", "h" => "Linuks", "f" => FP), code("n" => "EFnet", "g" => " ", "h" => "Linuks", "f" => FP),
     code("n" => "EFnet", "g" => "Hub", "h" => "bad nick", "f" => FP), code(%w[not a hash])].each do |bad|
      assert_raises(Gemshard::ConfigError, bad) { Gemshard::JoinCode.decode(bad) }
    end
  end
end
