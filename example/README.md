# steady_chat_list example

Everything the package can do, on a simulated server (no network needed).

```sh
flutter run -d chrome     # or macos, or an Android / iOS device
```

The menu on the left lists the demos. Under each title is what the page shows.

| Demo | What it shows |
| --- | --- |
| Simple list | `SteadyChatList.list`: a plain `List` and `setState` |
| Stream of snapshots | `SteadyChatList.stream`: whole query results, diffed |
| AI streaming reply | A message that grows word by word |
| 10,000,000 messages | Paging with 80 built rows; jump to any number or date |
| Group chat, all features | Sending, replies, reactions, mentions, pinned bar, selection, swipe to reply |
| Search navigation | "3 of 250,000" with highlighting and a results list |
| Server chaos & performance | Latency, failures, storms, remote deletes and edits, lost connection; frame times |
| Offline cache | In memory or Drift (SQLite, also in the browser) |
| Reload restores position | Reload the tab: same page, same message, same pixel |
| Split view & shared hub | One controller switched between chats; two views of one chat |
| Events & debug overlay | `controller.events` live, the anchor line, `debugDescribe()` |
| Theming, RTL, custom builders | `SteadyChatList.source`, `MessageListTheme`, right-to-left |

Where to look in the code:

- `lib/data/models.dart`: the message class and its `MessageAdapter`.
- `lib/data/fake_chat_server.dart`: a `MessageSource` and `MessageSearchSource` (your backend goes here).
- `lib/widgets/chat_pane.dart`: a complete chat screen on `MessageListController` and `MessageListView`.
- `lib/pages/simple_pages.dart`: the one-widget API.
- `lib/demo.dart`: the hub, the saved positions and the caches.

The web build keeps scroll positions in local storage (`SharedPreferencesViewportStore`) and the Drift cache in IndexedDB; `web/sqlite3.wasm` and `web/drift_worker.js` come from the [drift web setup](https://drift.simonbinder.eu/platforms/web/).
