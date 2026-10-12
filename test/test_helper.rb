require "minitest/autorun"
require "logger"
require "stringio"
require "tmpdir"
require "gemshard"

P = Gemshard::Protocol

# The hub's side of a handshake, for tests: its key, and the session and
# signed welcome for a shard's hello.
class FakeHub
  attr_reader :key, :session

  def initialize = @key = OpenSSL::PKey.generate_key("ED25519")
  def fingerprint = P.fingerprint(@key)

  def welcome_for(hello_text)
    hello, shard_key = P.verify_signed(hello_text)
    mine, welcome = P.start(@key, "welcome", "to" => hello["nonce"])
    @session = P.session(mine, hello, @key, shard_key, shard: false)
    welcome
  end
end
