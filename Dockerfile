# Image for a shard on Debian trixie (Ruby 3.3, standard library only).
#
# Config, key and state are never baked in: they live in a host folder
# mounted at /shard (config.yml, data/). Use bin/gemshard-docker to build
# and run it.

FROM debian:trixie-slim AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 \
    HOME=/tmp \
    GEMSHARD_LOG_LEVEL=info
WORKDIR /app
COPY lib/ lib/
COPY bin/gemshard bin/
COPY config.example.yml ./
# The shard runs as an unprivileged --user, so the (root-owned) code must be
# world-readable whatever the permissions were on the build host.
RUN chmod -R u=rwX,go=rX /app

# Test stage: "bin/gemshard-docker test" runs the suite on trixie's Ruby.
FROM base AS test
RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby-minitest rake \
 && rm -rf /var/lib/apt/lists/*
COPY Rakefile ./
COPY test/ test/
RUN chmod -R u=rwX,go=rX /app
CMD ["rake", "test"]

# Runtime stage (default).
FROM base AS runtime
VOLUME /shard
# Healthy = on IRC on every network, by the status files the shard writes
# every 30 seconds (data/status.json, or data/<network>/status.json).
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
  CMD ["ruby", "-rjson", "-e", "f = Dir['/shard/data/**/status.json']; exit(f.any? && f.all? { |p| s = JSON.parse(File.read(p)); s['irc'] == 'connected' && Time.now.to_i - s['updated_at_unix'] < 120 } ? 0 : 1)"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["ruby", "/app/bin/gemshard"]
CMD ["/shard/config.yml"]
