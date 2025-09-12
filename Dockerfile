FROM ubuntu:rolling

# Change if necessary
ENV USR=1000
ENV GRP=100

RUN apt-get update && apt-get --no-install-recommends -y install \
    git-core \
    gnupg \ 
    flex \ 
    bison \ 
    zip \ 
    curl \
    zlib1g-dev \ 
    gcc-multilib \ 
    g++-multilib \ 
    libc6-dev-i386 \
    x11proto-core-dev \ 
    libx11-dev \ 
    lib32z1-dev \ 
    libgl1-mesa-dev \ 
    libxml2-utils \ 
    xsltproc \ 
    unzip \ 
    fontconfig \ 
    python3 \
    libgcc-12-dev \
    binutils \
    diffutils \
    libfreetype6 \
    python3-lz4 \
    python3-protobuf \
    nodejs \
    build-essential \
    openssl \
    libssl-dev \
    ca-certificates \
    sudo \
    locales \
    python-is-python3 \
    openssh-client \
    signify-openbsd \
    wget \
    jq \
    rsync \
    apprise \
    nano \
    npm
    
RUN cp /usr/bin/signify-openbsd /usr/bin/signify

#RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
#RUN echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
#RUN apt update && apt install --no-install-recommends yarn
RUN npm install -g corepack && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 && corepack enable
RUN corepack prepare yarn@stable --activate

RUN curl https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && chmod a+x /usr/local/bin/repo

ENV PATH /opt/sdk/tools:/opt/sdk/tools/bin:${PATH}

# Set the locale
RUN dpkg-reconfigure --frontend=noninteractive locales
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER $USR

ENTRYPOINT ["/build.sh"]
