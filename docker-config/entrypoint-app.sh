#!/usr/bin/env bash
set -e

echo "Preparing database..."
bin/rails db:prepare  

exec "$@"
