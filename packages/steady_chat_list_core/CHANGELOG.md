## 0.1.3

- **Fixed:** messages read from the cache that were deleted or edited on the server meanwhile are corrected by the next page that covers them. `MessageListHub.isUnverified`.
- **Fixed:** a reconciled `around` page also removes its anchor when the server no longer has it; an empty page that reached both ends empties the list.

## 0.1.2

- A runnable `example/example.dart`.
- **Fixed:** the README sample used `const PageRequest`, which does not compile.
- Doc comments on the `CancellationToken` and `InMemoryViewportStore` constructors.

## 0.1.1

Documentation only: a screen recording and a screenshot, updated links.

## 0.1.0

First release. `MessageKey`, `MessageAdapter`, `MessageSource` and its page and event types, `ListStore` with segments and tombstones, `MessageStore`, `MessageListHub`, the policies, the jump model, `ListMessageSource`, `StreamMessageSource`, `MessageCache` and `InMemoryMessageCache`.

The development history before this release is in the [repository changelog](https://github.com/vfiruz97/steady_chat_list/blob/main/CHANGELOG.md).
