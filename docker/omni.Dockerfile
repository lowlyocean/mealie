FROM node:16 as builder

WORKDIR /app

COPY ./frontend .

RUN yarn install \
    --prefer-offline \
    --frozen-lockfile \
    --non-interactive \
    --production=false \
    # https://github.com/docker/build-push-action/issues/471
    --network-timeout 1000000

RUN yarn build

RUN rm -rf node_modules && \
    NODE_ENV=production yarn install \
    --prefer-offline \
    --pure-lockfile \
    --non-interactive \
    --production=true

###############################################
# Base Image - Python
###############################################
FROM python:3.10-slim as python-base

ENV MEALIE_HOME="/app"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=100 \
    # POETRY_HOME="/opt/poetry" \
    POETRY_HOME="/opt/pysetup" \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    POETRY_NO_INTERACTION=1 \
    PYSETUP_PATH="/opt/pysetup" \
    VENV_PATH="/opt/pysetup/.venv"

# prepend poetry and venv to path
ENV PATH="$POETRY_HOME/bin:$VENV_PATH/bin:$PATH"

# create user account
RUN useradd -u 911 -U -d $MEALIE_HOME -s /bin/bash abc \
    && usermod -G users abc \
    && mkdir $MEALIE_HOME

###############################################
# Builder Image
###############################################
FROM python-base as builder-base

# to get bcrypt to build  https://github.com/rust-lang/cargo/issues/8719
# RUN --security=insecure mkdir -p /root/.cargo && chmod 777 /root/.cargo && mount -t tmpfs none /root/.cargo

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    curl \
    build-essential \
    libpq-dev \
    libwebp-dev \
    tesseract-ocr-all \
    # LDAP Dependencies
    libsasl2-dev libldap2-dev libssl-dev \
    gnupg gnupg2 gnupg1 \
    # lxml dependencies
    libxml2-dev libxslt-dev python3-dev \
    # not strictly sure these runtime ones are needed at this stage or only later
    libxml2 libxslt1.1 \
    # need this for cryptography, bcrypt, and maybe Pillow
    cargo rustc \
    # needt his for Pillow apparently
    libjpeg-dev zlib1g-dev \
    # get bcrypt this way instead of via pip
    python3-bcrypt \
    # for pip install
    python3-virtualenv \
    # && pip install -U --no-cache-dir pip
    && pip install --upgrade --no-cache-dir pip setuptools wheel

# install poetry - respects $POETRY_VERSION & $POETRY_HOME
# ENV POETRY_VERSION=1.3.1
# RUN curl -sSL https://install.python-poetry.org | python3 -

# copy project requirement files here to ensure they will be cached.
WORKDIR $PYSETUP_PATH
COPY ./poetry.lock ./pyproject.toml ./requirements.txt ./

# install runtime deps - uses $POETRY_VIRTUALENVS_IN_PROJECT internally
# RUN poetry install -E pgsql --only main
# RUN pip install -r requirements.txt --only-binary=cryptography
RUN python3 -m venv .venv
RUN . $VENV_PATH/bin/activate && pip install -r requirements.txt --only-binary=cryptography

###############################################
# CRFPP Image
###############################################
# FROM --platform=linux/arm/v7 hkotel/crfpp as crfpp
FROM hkotel/crfpp as crfpp

RUN echo "crfpp-container"

###############################################
# Production Image
###############################################
FROM python-base as production
ENV PRODUCTION=true
ENV TESTING=false

ARG COMMIT
ENV GIT_COMMIT_HASH=$COMMIT

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    gosu \
    iproute2 \
    tesseract-ocr-all \
    curl \
    gnupg \
    python3-bcrypt \
    libldap-common \
    # for webp / Pillow image upload to work
    libwebpdemux2 \
    # for libxml to work as shared lib
    libxml2 libxslt1.1 \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sL https://deb.nodesource.com/setup_16.x | bash - \
    && apt-get install -y nodejs

# Add Yarn
RUN curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list \
    && apt-get update && apt-get install yarn

# Clean apt
RUN apt-get autoremove && rm -rf /var/lib/apt/lists/*

# copying poetry and venv into image
COPY --from=builder-base $POETRY_HOME $POETRY_HOME
COPY --from=builder-base $PYSETUP_PATH $PYSETUP_PATH

ENV LD_LIBRARY_PATH=/usr/local/lib
COPY --from=crfpp /usr/local/lib/ /usr/local/lib
COPY --from=crfpp /usr/local/bin/crf_learn /usr/local/bin/crf_learn
COPY --from=crfpp /usr/local/bin/crf_test /usr/local/bin/crf_test

# copy backend
COPY ./mealie $MEALIE_HOME/mealie
COPY ./poetry.lock ./pyproject.toml ./requirements.txt $MEALIE_HOME/
COPY ./gunicorn_conf.py $MEALIE_HOME

# Alembic
COPY ./alembic $MEALIE_HOME/alembic
COPY ./alembic.ini $MEALIE_HOME/

# venv already has runtime deps installed we get a quicker install
WORKDIR $MEALIE_HOME
RUN . $VENV_PATH/bin/activate && pip install -r requirements.txt --only-binary=cryptography && pip install -e .
WORKDIR /

# Grab CRF++ Model Release
# RUN python $MEALIE_HOME/mealie/scripts/install_model.py
RUN . $VENV_PATH/bin/activate && python3 $MEALIE_HOME/mealie/scripts/install_model.py

VOLUME [ "$MEALIE_HOME/data/" ]
ENV APP_PORT=9000

EXPOSE ${APP_PORT}

HEALTHCHECK CMD . $VENV_PATH/bin/activate && python3 $MEALIE_HOME/mealie/scripts/healthcheck.py || exit 1
# HEALTHCHECK CMD python $MEALIE_HOME/mealie/scripts/healthcheck.py || exit 1

# ----------------------------------
# Copy Frontend

# copying caddy into image
COPY --from=builder /app  $MEALIE_HOME/frontend/

ENV HOST 0.0.0.0

EXPOSE ${APP_PORT}
COPY ./docker/omni.entry.sh $MEALIE_HOME/run.sh

RUN chmod +x $MEALIE_HOME/run.sh
ENTRYPOINT $MEALIE_HOME/run.sh
