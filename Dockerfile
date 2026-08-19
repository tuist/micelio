# syntax=docker/dockerfile:1

# Micelio ships as an OTP release: the builder produces a self-contained tree
# with its own ERTS, so the runtime image needs no Erlang or Elixir installed.
ARG ELIXIR_VERSION=1.20.3
ARG OTP_VERSION=29.0.5
ARG DEBIAN_VERSION=bookworm-20260803-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# build-essential is for MuonTrap's port binary, which is C.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, so editing application code does not invalidate them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ----------------------------------------------------------------------------

FROM ${RUNNER_IMAGE}

# git is the actual workhorse: Micelio does not reimplement it.
# curl is used by the pre-receive hook to call back into the node.
# libncurses and locales are what the ERTS expects to find.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       git \
       curl \
       ca-certificates \
       libstdc++6 \
       openssl \
       libncurses6 \
       locales \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Git needs a writable HOME even though every invocation disables user config.
ENV HOME=/app

WORKDIR /app

RUN groupadd --system --gid 1000 micelio \
  && useradd --system --uid 1000 --gid micelio --home /app micelio \
  && mkdir -p /var/lib/micelio/repositories \
  && chown -R micelio:micelio /app /var/lib/micelio

COPY --from=builder --chown=micelio:micelio /app/_build/prod/rel/micelio ./

USER micelio

# Also set here so `docker run` of this image behaves the same as the release
# script; see rel/env.sh.eex for why this is not left to the runtime's default.
ENV ERL_MAX_PORTS=65536 \
    MICELIO_DATA_DIR=/var/lib/micelio/repositories \
    MICELIO_GIT_PORT=4000 \
    MICELIO_HOOK_PORT=4001 \
    MICELIO_ADMIN_PORT=4002

# 4000 git + mcp (public), 4002 admin + metrics (internal).
# 4001 is the hook callback and binds to loopback, so it is deliberately absent.
EXPOSE 4000 4002

# The release's own health check, so the image is useful without an orchestrator.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${MICELIO_ADMIN_PORT}/health" || exit 1

CMD ["/app/bin/micelio", "start"]
