FROM ubuntu:22.04 AS build-stage

ENV NODE_OPTIONS=--openssl-legacy-provider
ENV NODE_VERSION=18.x
ENV ZEROTIER_ONE_VERSION=1.10.2
ENV LIBPQXX_VERSION=7.6.1
ENV NLOHMANN_JSON_VERSION=3.11.2

RUN apt update && \    
    apt -y install \
        gnupg \
        build-essential \
        pkg-config \
        bash \
        clang \
        libjemalloc2 \
        libjemalloc-dev \
        libpq5 \
        libpq-dev \
        openssl \
        libssl-dev \
        postgresql-client \
        postgresql-client-common \
        curl \
        google-perftools \
        libgoogle-perftools-dev \
        python3 \
        wget \
        jq \
        postgresql-server-dev-14 && \
    curl -sL https://deb.nodesource.com/setup_${NODE_VERSION} | bash - && \
    curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg >/dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt update && apt install -y nodejs yarn && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    mkdir /usr/include/nlohmann/ && cd /usr/include/nlohmann/ && wget https://github.com/nlohmann/json/releases/download/v${NLOHMANN_JSON_VERSION}/json.hpp

# Prepaire Environment

WORKDIR /src

COPY ./patch /src/patch
COPY ./config /src/config

# Downloading and build latest libpqxx
RUN curl https://codeload.github.com/jtv/libpqxx/tar.gz/refs/tags/${LIBPQXX_VERSION} --output /tmp/libpqxx.tar.gz && \
    mkdir -p /src && \
    cd /src && \
    tar fxz /tmp/libpqxx.tar.gz && \
    mv /src/libpqxx-* /src/libpqxx && \
    rm -rf /tmp/libpqxx.tar.gz && \
    cd /src/libpqxx && \
    /src/libpqxx/configure --disable-documentation --with-pic && \
    make && \
    make install

# Downloading and build latest version ZeroTierOne
RUN curl https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/refs/tags/${ZEROTIER_ONE_VERSION} --output /tmp/ZeroTierOne.tar.gz && \
    mkdir -p /src && \
    cd /src && \
    tar fxz /tmp/ZeroTierOne.tar.gz && \
    mv /src/ZeroTierOne-* /src/ZeroTierOne && \
    rm -rf /tmp/ZeroTierOne.tar.gz

RUN python3 /src/patch/patch.py

RUN cd /src/ZeroTierOne && \
    make central-controller CPPFLAGS+=-w && \
    cd /src/ZeroTierOne/attic/world && \
    bash build.sh

# Downloading and build latest tagged zero-ui
RUN ZERO_UI_VERSION=`curl --silent "https://api.github.com/repos/dec0dOS/zero-ui/tags" | jq -r '.[0].name'` && \
    curl https://codeload.github.com/dec0dOS/zero-ui/tar.gz/refs/tags/${ZERO_UI_VERSION} --output /tmp/zero-ui.tar.gz && \
    mkdir -p /src/ && \
    cd /src && \
    tar fxz /tmp/zero-ui.tar.gz && \
    mv /src/zero-ui-* /src/zero-ui && \
    rm -rf /tmp/zero-ui.tar.gz && \
    cd /src/zero-ui && \
    yarn install && \
    yarn build

FROM ubuntu:22.04 AS dist

ENV NODE_VERSION=18.x

WORKDIR /app/ZeroTierOne

# libpqxx
COPY --from=build-stage /usr/local/lib/libpqxx.la /usr/local/lib/libpqxx.la
COPY --from=build-stage /usr/local/lib/libpqxx.a /usr/local/lib/libpqxx.a

# ZeroTierOne
COPY --from=build-stage /src/ZeroTierOne/zerotier-one /app/ZeroTierOne/zerotier-one
RUN cd /app/ZeroTierOne && \
    ln -s zerotier-one zerotier-cli && \
    ln -s zerotier-one zerotier-idtool

# mkworld @ ZeroTierOne
COPY --from=build-stage /src/ZeroTierOne/attic/world/mkworld /app/ZeroTierOne/mkworld
COPY --from=build-stage /src/ZeroTierOne/attic/world/world.bin /app/config/world.bin
COPY --from=build-stage /src/config/world.c /app/config/world.c

RUN apt update && \
    apt -y install curl gnupg && \
    curl -sL https://deb.nodesource.com/setup_${NODE_VERSION} | bash - && \
    curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg >/dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt update && apt -y install nodejs yarn postgresql-client postgresql-client-common libjemalloc2 libpq5 curl binutils linux-tools-gke perf-tools-unstable google-perftools wget jq && \
    mkdir -p /var/lib/zerotier-one/ && \
    ln -s /app/config/authtoken.secret /var/lib/zerotier-one/authtoken.secret

# Installing s6-overlay
RUN S6_OVERLAY_VERSION=`curl --silent "https://api.github.com/repos/just-containers/s6-overlay/releases/latest" | jq -r .tag_name | sed 's/^v//'` && \
    cd /tmp && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz --output s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz --output s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    rm -f /tmp/*.xz

# Frontend @ zero-ui
COPY --from=build-stage /src/zero-ui/frontend/build /app/frontend/build/

# Backend @ zero-ui
WORKDIR /app/backend
COPY --from=build-stage /src/zero-ui/backend/package*.json /app/backend
RUN yarn install && \
    ln -s /app/config/world.bin /app/frontend/build/static/planet
COPY --from=build-stage /src/zero-ui/backend /app/backend

# s6-overlay
COPY ./s6-files/etc /etc/
RUN chmod +x /etc/services.d/*/run

# schema
COPY ./schema /app/schema/

EXPOSE 3000 4000 9993 9993/UDP
ENV S6_KEEP_ENV=1

ENTRYPOINT ["/init"]
CMD []
