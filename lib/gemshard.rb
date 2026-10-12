# Gemshard: a small companion bot for the Gemdrop IRC bot (see README.md).
module Gemshard
  VERSION = "0.1.0"
end

require_relative "gemshard/protocol"
require_relative "gemshard/config"
require_relative "gemshard/irc"
require_relative "gemshard/enforcer"
require_relative "gemshard/link"
require_relative "gemshard/shard"
