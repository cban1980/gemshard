require "test_helper"

class ConfigTest < Minitest::Test
  FP = "SHA256:#{'A' * 43}".freeze

  def setup = @dir = Dir.mktmpdir("gemshard")
  def teardown = FileUtils.remove_entry(@dir)

  def load(yaml)
    path = File.join(@dir, "config.yml")
    File.write(path, yaml)
    Gemshard::Config.load(path)
  end

  def hub(server, extra = "") = "hub_gecos: Gemdrop\nhub_fingerprint: \"#{FP}\"\nirc: { server: #{server}#{extra} }"

  def test_one_network_at_the_top_level
    config = load("name: one\nnetwork: EFnet\n#{hub('irc.efnet.org')}\n")
    assert_equal File.join(@dir, "data"), config["data_dir"]
    net = config["networks"].first
    assert_equal ["EFnet", "one", File.join(@dir, "data")], [net["network"], net["name"], net["data_dir"]],
                 "its state stays where it was"
    assert_equal 6697, net.dig("irc", "port")
  end

  def test_several_networks_each_with_its_hub_and_folder
    config = load(<<~YAML)
      name: one
      networks:
        EFnet:
          #{hub('irc.efnet.org').gsub("\n", "\n    ")}
        "IRC net":
          #{hub('open.ircnet.net', ', port: 6667').gsub("\n", "\n    ")}
    YAML
    assert_equal ["EFnet", "IRC net"], config["networks"].map { |n| n["network"] }
    assert_equal [File.join(@dir, "data", "EFnet"), File.join(@dir, "data", "IRC_net")], config["networks"].map { |n| n["data_dir"] }
    assert_equal 6667, config["networks"].last.dig("irc", "port")
    assert(config["networks"].all? { |n| n["name"] == "one" })
  end

  def test_whats_missing_is_named_with_its_network
    error = assert_raises(Gemshard::ConfigError) do
      load("name: one\nnetworks:\n  EFnet:\n    hub_fingerprint: \"#{FP}\"\n    irc: { server: x }\n")
    end
    assert_match(/EFnet: hub_gecos/, error.message)
    assert_raises(Gemshard::ConfigError) { load("name: one\nnetworks:\n  EFnet: {}\n  efnet: {}\n") }
    assert_raises(Gemshard::ConfigError) { load("name: One Two\nnetwork: EFnet\n#{hub('x')}\n") }
  end

  def test_the_example_is_a_valid_shape
    error = assert_raises(Gemshard::ConfigError) { load(File.read(File.expand_path("../config.example.yml", __dir__))) }
    assert_match(/hub_fingerprint/, error.message, "only the placeholder key is left to fill in")
  end
end
