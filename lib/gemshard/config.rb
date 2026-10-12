require "fileutils"
require "yaml"

module Gemshard
  class ConfigError < StandardError; end

  # config.yml (see config.example.yml).
  module Config
    NAME = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
    FINGERPRINT = %r{\ASHA256:[A-Za-z0-9+/]{43}\z}
    IRC_DEFAULTS = { "port" => 6697, "tls" => true, "tls_verify" => true, "nick" => "Gemshard", "alt_nicks" => [],
                     "user" => "gemshard", "realname" => "Gemshard" }.freeze

    module_function

    def load(path)
      data = YAML.safe_load(File.read(path)) || {}
      raise ConfigError, "#{path}: not a mapping" unless data.is_a?(Hash)

      config = { "data_dir" => "data" }.merge(data)
      config["irc"] = IRC_DEFAULTS.merge(config["irc"] || {})
      check!(config)
      config["data_dir"] = File.expand_path(config["data_dir"], File.dirname(File.expand_path(path)))
      config
    rescue Errno::ENOENT
      raise ConfigError, "no config at #{path} (gemshard init makes one)"
    rescue Psych::Exception => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    def check!(config)
      raise ConfigError, "name: 1-32 of a-z, 0-9, _ and - (as added on the hub)" unless config["name"].to_s.match?(NAME)
      raise ConfigError, "network: the hub's name for the network (e.g. EFnet)" if config["network"].to_s.empty?
      raise ConfigError, "hub_nick: the hub bot's nick" if config["hub_nick"].to_s.empty?
      unless config["hub_fingerprint"].to_s.match?(FINGERPRINT)
        raise ConfigError, "hub_fingerprint: SHA256:... (SHARD INFO on the hub)"
      end
      raise ConfigError, "irc: server is needed" if config.dig("irc", "server").to_s.empty?
    end
  end

  # The shard's Ed25519 key, made on first use (data_dir/shard.key, 0600).
  module Identity
    module_function

    def load(data_dir)
      FileUtils.mkdir_p(data_dir, mode: 0o700)
      path = File.join(data_dir, "shard.key")
      return OpenSSL::PKey.read(File.read(path)) if File.file?(path)

      key = OpenSSL::PKey.generate_key("ED25519")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(key.private_to_pem) }
      key
    end
  end
end
