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

    # The shard's settings: its name, data_dir (the key), and "networks":
    # one flat config per network, each with its own hub, IRC server and
    # data_dir (data/<network>/ for its state). A config without
    # "networks:" is one network, at the top level, with its state in data/.
    def load(path)
      data = YAML.safe_load(File.read(path)) || {}
      raise ConfigError, "#{path}: not a mapping" unless data.is_a?(Hash)

      base = File.dirname(File.expand_path(path))
      data_dir = File.expand_path((data["data_dir"] || "data").to_s, base)
      raise ConfigError, "name: 1-32 of a-z, 0-9, _ and - (as added on the hub)" unless data["name"].to_s.match?(NAME)

      { "name" => data["name"], "data_dir" => data_dir, "networks" => networks(data, data_dir) }
    rescue Errno::ENOENT
      raise ConfigError, "no config at #{path} (gemshard init makes one)"
    rescue Psych::Exception => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    def networks(data, data_dir)
      unless data.key?("networks")
        return [network_config(data["name"], data["network"], data.reject { |k, _| k == "data_dir" }, data_dir)]
      end
      list = data["networks"]
      raise ConfigError, "networks: one entry per network (EFnet: {hub_gecos: ..., irc: ...})" unless list.is_a?(Hash) && list.any?

      seen = {}
      list.map do |network, settings|
        raise ConfigError, "networks: #{network}: not a mapping" unless settings.is_a?(Hash)
        raise ConfigError, "networks: #{network} is there twice" if seen[network.to_s.downcase]

        seen[network.to_s.downcase] = true
        folder = network.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
        network_config(data["name"], network.to_s, settings, File.join(data_dir, folder))
      end
    end

    def network_config(name, network, settings, data_dir)
      config = settings.merge("name" => name, "network" => network, "data_dir" => data_dir)
      config["irc"] = IRC_DEFAULTS.merge(settings["irc"] || {})
      check!(config)
      config
    end

    def check!(config)
      where = config["network"].to_s.empty? ? "" : "#{config['network']}: "
      raise ConfigError, "network: the hub's name for the network (e.g. EFnet)" if config["network"].to_s.empty?
      raise ConfigError, "#{where}hub_gecos: the hub bot's gecos (realname; SHARD INFO on the hub)" if config["hub_gecos"].to_s.strip.empty?
      unless config["hub_fingerprint"].to_s.match?(FINGERPRINT)
        raise ConfigError, "#{where}hub_fingerprint: SHA256:... (SHARD INFO on the hub)"
      end
      raise ConfigError, "#{where}irc: server is needed" if config.dig("irc", "server").to_s.empty?
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
