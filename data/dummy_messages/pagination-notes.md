Dummy message pagination layout

- Page size: up to 6 messages per page, ordered as in the source thread.
- Default page file: `thread-{thread_id}.json` (offset 0).
- Additional page files: `thread-{thread_id}-{offset}-{limit}.json`, where `offset` is the zero-based message index and `limit` is the count on that page.
- Multi-page threads:
  - thread 91000002 (booking 51000002): pages at offsets 0/6/12/18 with limits 6/6/6/4.
  - thread 91000005 (booking 51000005): pages at offsets 0/6/12/18 with limits 6/6/6/4.
- All other threads fit on a single page; their `thread-{thread_id}.json` files now carry their full message list with the corresponding `limit` value.
