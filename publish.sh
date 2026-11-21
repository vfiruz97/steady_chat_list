#!/bin/sh
# Publishes steady_chat_list_core and steady_chat_list to pub.dev in dependency order.
# The first command opens a Google sign-in for pub.dev.
set -e
cd "$(dirname "$0")/packages"

(cd steady_chat_list_core && dart pub publish --force)

echo "Waiting for pub.dev to list steady_chat_list_core..."
until curl -sf https://pub.dev/api/packages/steady_chat_list_core >/dev/null; do sleep 5; done

(cd steady_chat_list && flutter pub publish --force)
# steady_chat_list_drift is not published yet. To publish it later:
# (cd steady_chat_list_drift && dart pub publish --force)
