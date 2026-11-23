## 0.1.4

- **Fixed:** a chat that was closed and opened again in the same app run kept showing messages deleted or edited on the server meanwhile. Once the hub stops listening to a closed list (`releaseDelay`), what stays in memory is checked against the server when it comes on screen again, like cached messages.
- **Fixed:** a list that opened with few messages at the very start of the history (a new chat, or a chat where every message is unread) did not load newer messages when scrolled down: the older edge, which had nothing left to load, kept the newer one from loading.
- **Fixed:** a chat where reading stopped before its first message now opens at the first unread message with the divider, not at the bottom.
- `MessageListConfig.scrollDownButtonDistance`: show the scroll-down button a number of pixels from the end instead of a share of the viewport height.
- Docs: `MessageListView.keyboardShortcuts` takes the keyboard focus on click; turn it off inside a `SelectionArea`.

## 0.1.3

- **Fixed:** with a cache, messages deleted or edited on the server while the app was closed stayed on screen until the app called `invalidate()`. They are now checked against the server when they come on screen and corrected without moving the viewport.

## 0.1.2

Documentation only, with `steady_chat_list_core` 0.1.2.

## 0.1.1

Documentation only: a screen recording and a screenshot, updated links.

## 0.1.0

First release. The complete feature set: the simple API (`SteadyChatList.list`, `.stream`, `.source`), `MessageListHub`, `MessageListController` and `MessageListView`, paging in both directions with a bounded window, the no-jump scroll position, jumps and search navigation, optimistic sending, animated deletes, selection, visibility and read tracking, default widgets with `MessageListTheme`, saved positions (`SharedPreferencesViewportStore`), cache support, `debugOverlay` and `debugDescribe()`.

The development history before this release is in the [repository changelog](https://github.com/vfiruz97/steady_chat_list/blob/main/CHANGELOG.md).
