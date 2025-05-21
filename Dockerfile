# syntax=docker/dockerfile:1.7-labs
ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-alpine AS base
WORKDIR /app
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache jemalloc gcompat tzdata

FROM base AS development
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache build-base git postgresql-dev yaml-dev nodejs npm
COPY src/Gemfile* ./
RUN bundle install
EXPOSE 3000
ENTRYPOINT ["./bin/docker-entrypoint"]
CMD ["bin/rails", "server"]

FROM base AS builder
ENV RAILS_ENV=production \
    BUNDLE_WITH=assets \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RUBY_VERSION=$RUBY_VERSION
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache build-base git postgresql-dev yaml-dev
COPY src/Gemfile* ./
RUN bundle install
COPY src/ ./
RUN <<BASH
    set -ex
    bundle exec bootsnap precompile app/ lib/
    SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile
    # After assets are compiled, switch Bundler to "runtime only"
    bundle config set --local frozen false
    bundle install --without development test assets
    bundle clean --force
    rm -rf ~/.bundle/ $BUNDLE_PATH/ruby/*/cache $BUNDLE_PATH/ruby/*/bundler/gems/*/.git
    find $BUNDLE_PATH -type f \( -name '*.c' -o -name '*.o' -o -name '*.log' -o -name '*.h' -o -name 'gem_make.out' \) -delete
    find $BUNDLE_PATH -name '*.so' -exec strip --strip-unneeded {} \;
    rm -rf $BUNDLE_PATH/ruby/*/gems/tailwindcss-* $BUNDLE_PATH/ruby/*/specifications/tailwindcss-* $BUNDLE_PATH/ruby/*/bin/tailwindcss
BASH

FROM base AS production
ENV RAILS_ENV=production \
    BOOTSNAP_READONLY=true \
    BUNDLE_DEPLOYMENT=true \
    BUNDLE_WITHOUT=development:test:assets \
    BUNDLE_PATH=/usr/local/bundle
RUN --mount=type=cache,target=/var/cache/apk <<BASH
    apk add --no-cache postgresql-client
    addgroup -g 1000 -S rails && adduser -S rails -u 1000 -g 1000
BASH
COPY --from=builder --chown=rails:rails $BUNDLE_PATH $BUNDLE_PATH
COPY --from=builder --chown=rails:rails --exclude=public/assets /app ./
USER 1000:1000
EXPOSE 3000
ENTRYPOINT ["./bin/docker-entrypoint"]
CMD ["bin/rails", "server"]

FROM caddy:2.10-alpine AS caddy
COPY --from=builder /app/public/assets /app/public/assets
COPY caddy/Caddyfile /etc/caddy/Caddyfile
