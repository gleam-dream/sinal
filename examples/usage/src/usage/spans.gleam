//// A native span around a unit of work.

import gleam/list
import sinal/fields
import sinal/span

pub fn traced_query(sql: String) -> List(String) {
  let query =
    span.define(
      ["db", "query"],
      start_metadata: fields.string("sql"),
      stop_measurements: fields.empty(),
      stop_metadata: fields.int("rows"),
    )
  span.run(query, sql, fn() {
    let rows = ["row for " <> sql]
    span.Completion(
      result: rows,
      measurements: Nil,
      metadata: list.length(rows),
    )
  })
}

/// Run the span and check that the work's result is returned unchanged.
pub fn run() -> Nil {
  assert traced_query("SELECT 1") == ["row for SELECT 1"]
}
