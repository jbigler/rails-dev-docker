# syntax = docker/dockerfile:1.2

ARG RUBY_VERSION
ARG NODE_VERSION

# ------------------------------------------------------------------------------
# Build Neovim
# ------------------------------------------------------------------------------
FROM debian:bookworm-slim AS build-nvim

ARG BUILD_APT_DEPS="ninja-build gettext curl libtool libtool-bin build-essential autoconf automake cmake g++ pkg-config unzip git binutils wget"
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGET=stable

RUN apt-get update -qq \
  && apt-get upgrade -y \
  && apt-get install -y ${BUILD_APT_DEPS} 

RUN git clone --depth 1 --branch ${TARGET} https://github.com/neovim/neovim.git /tmp/neovim

WORKDIR /tmp/neovim

RUN make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=/usr/local/ && \
  make install && \
  strip /usr/local/bin/nvim


# ------------------------------------------------------------------------------
# Node alias 
# ------------------------------------------------------------------------------
FROM node:${NODE_VERSION}-slim AS node

# ------------------------------------------------------------------------------
# Base image
# ------------------------------------------------------------------------------
# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim as base

ENV APP_PATH=/app
ARG APP_USER=appuser
ENV APP_USER=${APP_USER}
ARG APP_GROUP=appgroup
ENV APP_GROUP=${APP_GROUP}
ARG APP_USER_UID=1000
ENV APP_USER_UID=${APP_USER_UID}
ARG APP_GROUP_GID=1000
ENV APP_GROUP_GID=${APP_GROUP_GID}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV KEYFILE=/etc/apt/keyrings/nodesource.gpg

# Install PostgreSQL repository
RUN apt-get update -qq && \
  apt-get install --no-install-recommends -y curl ca-certificates gnupg lsb-release && \
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
  rm -rf /var/lib/apt/lists/*

# Install all remaining packages
RUN apt-get update -qq && \
  apt-get install --no-install-recommends -y \
  libpq-dev \
  postgresql-client-16 \
  libyaml-dev \
  libsqlite3-0 \
  libjemalloc2 \
  kitty-terminfo \
  musl-dev \
  zsh \
  build-essential \
  git \
  libvips \
  openssh-client \
  pkg-config \
  libpng-dev \
  libjpeg-dev \
  libtiff-dev \
  poppler-utils \
  poppler-data \
  imagemagick \
  libmagickwand-dev \
  libmagickcore-dev && \
  rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2


# Install GitHub CLI
RUN (type -p wget >/dev/null || ( apt update && apt-get install wget -y)) \
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt update \
  && apt install gh -y


# 1. Copy Node directly from the official image
COPY --from=node /usr/local/bin /usr/local/bin
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN --mount=type=cache,target=$BUNDLE_APP_CONFIG \
  gem update --system && \
  gem install -N bundler && \
  mkdir -p $APP_PATH

COPY Gemfile* $APP_PATH/

RUN addgroup --gid "$APP_GROUP_GID" "$APP_GROUP" \
  && useradd -g "$APP_GROUP" -s /bin/zsh -p '' --uid "$APP_USER_UID" -m "$APP_USER" \
  && chgrp -R "$APP_GROUP" "$BUNDLE_APP_CONFIG" \
  && chmod -R g+w "$BUNDLE_APP_CONFIG" \
  && chown -R "$APP_USER":"$APP_GROUP" "$APP_PATH"


ENV NPM_CONFIG_PREFIX="/home/${APP_USER}/.npm-global"
ENV PATH="/home/${APP_USER}/.local/bin:/home/${APP_USER}/.npm-global/bin:${PATH}:/app/node_modules/.bin"

WORKDIR $APP_PATH

ENV SHELL=/bin/zsh

USER $APP_USER

# Set up npm global prefix in user home
RUN mkdir -p /home/${APP_USER}/.npm-global && \
  mkdir -p $APP_PATH/node_modules && \
  bundle install

SHELL ["/bin/zsh", "-c"]

# ------------------------------------------------------------------------------
# Rails image
# ------------------------------------------------------------------------------
FROM base as rails

ENV RAILS_LOG_TO_STDOUT="1"
ENV BINDING="0.0.0.0"

EXPOSE 3000

CMD ["bin/dev"]

# ------------------------------------------------------------------------------
# NVim image
# ------------------------------------------------------------------------------
FROM base as nvim
USER root

COPY --from=build-nvim /usr/local /usr/local/

RUN --mount=type=cache,sharing=locked,target=/var/cache/apt apt-get update -qq && \
  apt-get install --no-install-recommends -y tree-sitter-cli xclip netbase fzf luarocks universal-ctags unzip ripgrep fzf fd-find lua5.4 

# Install lazygit
RUN wget -q -O /usr/local/bin/lazygit https://github.com/jesseduffield/lazygit/releases/download/v0.59.0/lazygit_0.59.0_Linux_x86_64.tar.gz && \
  tar -xvf /usr/local/bin/lazygit -C /usr/local/bin

RUN luarocks install dkjson

USER $APP_USER

EXPOSE 7777
CMD ["/usr/local/bin/nvim", "--headless", "--listen", "0.0.0.0:7777"]


# ------------------------------------------------------------------------------
# Claude image
# ------------------------------------------------------------------------------

FROM base as claude

USER root

COPY --from=build-nvim /usr/local /usr/local/

RUN apt-get update -qq && \
  apt-get install -y \
  less \
  procps \
  sudo \
  fzf \
  man-db \
  unzip \
  gnupg2 \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN (type -p wget >/dev/null || ( apt update && apt-get install wget -y)) \
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt update \
  && apt install gh -y

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $APP_USER /commandhistory

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh

WORKDIR /app

# Set the default editor and visual
ENV EDITOR=nvim
ENV VISUAL=nvim

# Install RTK
ENV RTK_INSTALL_DIR=/usr/local/bin
RUN /bin/bash -c "$(wget -qO- https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh)"

# Install Claude Code globally (AUR direct-binary method)
ARG CLAUDE_CODE_VERSION=latest
RUN GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases" && \
  if [ "$CLAUDE_CODE_VERSION" = "latest" ]; then \
  CLAUDE_CODE_VERSION=$(wget -qO- https://registry.npmjs.org/@anthropic-ai/claude-code/latest | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'); \
  fi && \
  mkdir -p /opt/claude-code/bin && \
  wget -q -O /opt/claude-code/bin/claude "${GCS_BUCKET}/${CLAUDE_CODE_VERSION}/linux-x64/claude" && \
  chmod 755 /opt/claude-code/bin/claude && \
  printf '#!/bin/sh\nexport DISABLE_AUTOUPDATER=1\nexec /opt/claude-code/bin/claude "$@"\n' > /usr/bin/claude && \
  chmod 755 /usr/bin/claude

COPY entrypoint-claude.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint-claude.sh && \
  echo "${APP_USER} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/firewall

ENTRYPOINT ["entrypoint-claude.sh"]

USER $APP_USER
