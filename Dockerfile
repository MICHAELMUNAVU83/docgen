# Release image for Docgen with LibreOffice (PDF export), poppler (PDF
# import) and fonts. Build: docker build -t docgen .
#
# The builder tag must exist on Docker Hub — pick one matching these
# versions from https://hub.docker.com/r/hexpm/elixir/tags
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.0.6
ARG DEBIAN_VERSION=trixie-20260921-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:trixie-slim"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config first so config changes don't recompile deps needlessly
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

# Verdana (the GS1 body font) ships in Microsoft's core fonts, which need
# Debian's contrib component and an EULA. Set to false to skip them; PDFs
# then fall back to DejaVu/Liberation.
ARG INSTALL_MS_FONTS=true

RUN if [ "$INSTALL_MS_FONTS" = "true" ]; then \
      sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources; \
      echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections; \
    fi \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates \
       libreoffice-writer-nogui poppler-utils \
       fonts-dejavu-core fonts-liberation2 fontconfig \
  && if [ "$INSTALL_MS_FONTS" = "true" ]; then \
       apt-get install -y --no-install-recommends ttf-mscorefonts-installer; \
     fi \
  && fc-cache -f \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV="prod" \
    # LibreOffice and fontconfig need a writable home.
    HOME=/tmp

WORKDIR "/app"
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/docgen ./

USER nobody

# Run migrations first with: docker run ... /app/bin/migrate
CMD ["/app/bin/server"]
