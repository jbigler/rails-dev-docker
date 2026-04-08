#!/usr/bin/env bash
set -e

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
