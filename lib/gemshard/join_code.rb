require "base64"
require "json"

module Gemshard
  # The hub's details as one line, from SHARD INFO on the hub:
  # "gemshard1:" and base64url (no padding) of {"n": network, "g": gecos,
  # "h": nick, "f": fingerprint}. Nothing in it is secret; it only saves
  # typing (and typos in the fingerprint).
  module JoinCode
    PREFIX = "gemshard1:"
    NICK = /\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,29}\z/

    module_function

    # { "network", "hub_gecos", "hub_nick", "hub_fingerprint" }, or ConfigError.
    def decode(code)
      text = code.to_s.strip
      raise ConfigError, "a join code starts with #{PREFIX} (SHARD INFO on the hub shows it)" unless text.start_with?(PREFIX)

      data = JSON.parse(Base64.urlsafe_decode64(text.delete_prefix(PREFIX)))
      raise ConfigError, "that join code is damaged" unless data.is_a?(Hash)

      details = { "network" => data["n"].to_s, "hub_gecos" => data["g"].to_s, "hub_nick" => data["h"].to_s,
                  "hub_fingerprint" => data["f"].to_s }
      unless details["network"].match?(/\A[\w.-]{1,40}\z/) && !details["hub_gecos"].strip.empty? &&
             details["hub_gecos"].size <= 200 && details["hub_nick"].match?(NICK) &&
             details["hub_fingerprint"].match?(Config::FINGERPRINT)
        raise ConfigError, "that join code is damaged"
      end

      details
    rescue ArgumentError, JSON::ParserError
      raise ConfigError, "that join code is damaged (copy all of it, from gemshard1: to the end)"
    end
  end
end
