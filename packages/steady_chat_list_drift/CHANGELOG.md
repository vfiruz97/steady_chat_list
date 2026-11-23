## 0.1.5

- No changes. Released together with `steady_chat_list` 0.1.5.

## 0.1.4

- **Fixed:** a chat that was closed and opened again in the same app run kept showing messages deleted or edited on the server meanwhile. Once the hub stops listening to a closed list (`releaseDelay`), what stays in memory is checked against the server when it comes on screen again, like cached messages.

## 0.1.3

No changes; released with `steady_chat_list_core` 0.1.3.

## 0.1.2

Documentation only, with `steady_chat_list_core` 0.1.2.

## 0.1.1

Documentation only.

## 0.1.0

First release. `DriftMessageCache`, `SteadyCacheDatabase` (plain SQL schema, no code generation), `MessageCodec` and `JsonMessageCodec`.

The development history before this release is in the [repository changelog](https://github.com/vfiruz97/steady_chat_list/blob/main/CHANGELOG.md).
