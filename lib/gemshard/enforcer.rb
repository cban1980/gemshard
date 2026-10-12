module Gemshard
  # What should be set in a channel, from the hub's state and what the
  # shard sees: op and voice for who should have them (never taken from
  # anyone), the mode lock, and op for the bots. And which bot does it.
  class Enforcer
    LEVELS = { "voice" => 1, "op" => 2, "owner" => 3 }.freeze
    MODE_FOR = { 1 => "v", 2 => "o", 3 => "o" }.freeze

    def initialize(name:, roster:)
      @name = name
      @roster = roster
    end

    def fold(text) = Roster.fold(text)

    # The bots, best first: the hub, then the shards by name.
    def bots(state)
      hub = state["hub"] || {}
      [{ "name" => "", "nick" => hub["nick"], "userhost" => hub["userhost"] }] +
        Array(state["bots"]).sort_by { |b| b["name"].to_s }
    end

    # A bot that is who it says: the nick, and the user@host if known.
    def bot?(bot, member)
      return false unless bot["nick"] && fold(bot["nick"]) == fold(member[:nick])

      bot["userhost"].nil? || member[:userhost].to_s.casecmp?(bot["userhost"])
    end

    # Am I the one to set things in channel? Only with op, and only if no
    # bot above me in bots(state) is in it with op.
    def mine?(state, channel, me)
      mine = @roster.member(channel, me)
      return false unless mine && mine[:modes].include?("o")

      bots(state).each do |bot|
        return true if bot["name"] == @name
        return false if (@roster.channel(channel)&.dig(:members)&.values || []).any? { |m| m[:modes].include?("o") && bot?(bot, m) }
      end
      true
    end

    # [[mode, nick], ...]: op or voice to give in channel.
    def members_to_set(state, channel_state, channel)
      chan = @roster.channel(channel) or return []
      admins = Array(state["admins"]).map { |a| fold(a) }
      access = (channel_state["access"] || {}).transform_keys { |a| fold(a) }
      sessions = Array(state["sessions"])
      masks = Array(channel_state["masks"])
      bot_list = bots(state)
      chan[:members].values.filter_map do |member|
        want = if bot_list.any? { |bot| bot?(bot, member) } then "o"
               else
                 level = [level_by_login(member, sessions, admins, access), level_by_mask(member, masks)].max
                 MODE_FOR[level]
               end
        next unless want
        next if member[:modes].include?(want) || (want == "v" && member[:modes].include?("o"))

        [want, member[:nick]]
      end
    end

    def level_by_login(member, sessions, admins, access)
      session = sessions.find do |s|
        fold(s["nick"]) == fold(member[:nick]) && member[:userhost] && s["userhost"].to_s.casecmp?(member[:userhost])
      end
      return 0 unless session

      account = fold(session["account"])
      admins.include?(account) ? 3 : LEVELS.fetch(access[account].to_s, 0)
    end

    def level_by_mask(member, masks)
      return 0 unless member[:userhost]

      prefix = "#{member[:nick]}!#{member[:userhost]}"
      masks.map { |mask, level| self.class.mask_match?(mask, prefix) ? LEVELS.fetch(level.to_s, 0) : 0 }.max || 0
    end

    def self.mask_match?(mask, prefix)
      pattern = Regexp.escape(Roster.fold(mask)).gsub("\\*", ".*").gsub("\\?", ".")
      Roster.fold(prefix).match?(/\A#{pattern}\z/)
    end

    # [[sign, mode, value], ...] that make the channel's modes match its
    # lock ("+ntk-i key"), as the hub's chanserv would.
    def lock_corrections(lock, current)
      return [] if lock.to_s.strip.empty?

      plus, minus = parse_lock(lock)
      changes = []
      plus.each do |mode, value|
        next if value == true ? current.key?(mode) : current[mode].to_s == value
        next if mode == "k" && current[mode] == "*"

        changes << ["-", "k", current["k"]] if mode == "k" && current.key?("k")
        changes << ["+", mode, value == true ? nil : value]
      end
      minus.each do |mode|
        changes << ["-", mode, mode == "k" ? current["k"].to_s.then { |k| k.empty? ? "*" : k } : nil] if current.key?(mode)
      end
      changes
    end

    def parse_lock(text)
      modes, *params = text.split
      _lists, always, when_set, = (@roster.isupport["CHANMODES"].to_s.split(",", -1) + ["", "", "", ""]).first(4)
      plus = {}
      minus = []
      sign = "+"
      modes.to_s.each_char do |char|
        next sign = char if "+-".include?(char)

        if sign == "-"
          minus |= [char]
          plus.delete(char)
        else
          plus[char] = always.include?(char) || when_set.include?(char) ? params.shift.to_s : true
        end
      end
      [plus, minus]
    end

    # MODE lines for changes ([[sign, mode, value], ...]), MODES at a time.
    def mode_lines(channel, changes)
      per_line = @roster.isupport["MODES"].to_i.positive? ? @roster.isupport["MODES"].to_i.clamp(1, 6) : 3
      changes.each_slice(per_line).map do |slice|
        modestring = +""
        sign = nil
        slice.each do |change_sign, mode, _value|
          modestring << change_sign if change_sign != sign
          sign = change_sign
          modestring << mode
        end
        ["MODE", channel, modestring, *slice.filter_map { |_, _, value| value }].join(" ")
      end
    end

    # The MODE lines for channel now, if this shard is the one to act.
    def plan(state, channel_state, channel, me)
      return [] unless mine?(state, channel, me)

      members = members_to_set(state, channel_state, channel).map { |mode, nick| ["+", mode, nick] }
      lock = lock_corrections(channel_state["mlock"], @roster.channel(channel)[:modes])
      mode_lines(channel, members + lock)
    end
  end
end
