require "test_helper"
require "socket"

# The IRC connection against a real local server, with and without TLS.
class IRCTest < Minitest::Test
  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
  end

  def teardown
    @irc&.close
    @server.close
  end

  def tls_server(socket)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=irc.test")
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.key = key
    ctx.cert = cert
    OpenSSL::SSL::SSLSocket.new(socket, ctx).tap { |tls| tls.sync_close = true }
  end

  def connect(tls:, verify: false)
    @irc = Gemshard::IRC.new(host: "127.0.0.1", port: @port, tls: tls, tls_verify: verify, logger: Logger.new(nil))
    @irc.connect
  end

  # Lines in one write, a line split over two writes, then silence.
  def serve(tls:)
    Thread.new do
      socket = @server.accept
      socket = tls_server(socket).tap(&:accept) if tls
      socket.write(":irc.test 001 Shard :Welcome\r\n:irc.test 005 Shard NETWORK=Test :are supported\r\nPING :x")
      sleep 0.2
      socket.write("yz\r\n")
      sleep 1
      socket.close
    end
  end

  def assert_reads_lines(tls:)
    server = serve(tls: tls)
    connect(tls: tls)
    assert_equal ":irc.test 001 Shard :Welcome", @irc.gets(5)
    assert_equal ":irc.test 005 Shard NETWORK=Test :are supported", @irc.gets(5), "the second line of one read"
    assert_equal "PING :xyz", @irc.gets(5), "a line split over two reads"
    assert_nil @irc.gets(0.3), "silence: nil after the timeout"
    server.join
    assert_nil @irc.gets(5), "closed"
  end

  def test_reads_lines_over_tls = assert_reads_lines(tls: true)
  def test_reads_lines_over_plain_tcp = assert_reads_lines(tls: false)

  def test_tls_checks_the_certificate_when_asked
    Thread.new { tls_server(@server.accept).accept rescue nil } # rubocop:disable Style/RescueModifier
    assert_raises(OpenSSL::SSL::SSLError) { connect(tls: true, verify: true) }
  end
end
