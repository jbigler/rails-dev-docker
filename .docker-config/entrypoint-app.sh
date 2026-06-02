#!/usr/bin/env bash
set -e

# Clear a stale puma pid left by an unclean shutdown — /app is bind-mounted,
# so the pid file survives container restarts and blocks "rails server".
rm -f tmp/pids/server.pid

bundle install
npm install

if bin/rails runner "ActiveRecord::Base.connection.table_exists?('schema_migrations')" &>/dev/null; then
  echo "Database already initialized — running migrations..."
  bin/rails db:migrate
  bin/rails db:test:prepare
else
  echo "Preparing database from scratch..."
  bin/rails db:prepare
fi

exec "$@"
