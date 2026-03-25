#!/usr/bin/env bash
set -e

if bin/rails runner "ActiveRecord::Base.connection.table_exists?('schema_migrations')" &>/dev/null; then
  echo "Database already initialized — running migrations..."
  bin/rails db:migrate
else
  echo "Preparing database from scratch..."
  bin/rails db:prepare
fi

exec "$@"
