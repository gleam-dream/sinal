import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/list
import gleam/string
import gleeunit/should
import sinal
import sinal/fields
import sinal/span

// --- Snippet 1: Defining Fields and Events ---

pub type HttpMeasurements {
  HttpMeasurements(duration_ms: Int, bytes_sent: Int)
}

pub type HttpMetadata {
  HttpMetadata(method: String, route: String, status: Int)
}

pub fn http_request_event() -> Result(
  sinal.Event(HttpMeasurements, HttpMetadata),
  sinal.EventError,
) {
  let dur_field =
    fields.field(
      atom.create("duration_ms"),
      fn(i: Int) { Ok(dynamic.int(i)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(i) -> Ok(i)
          Error(_) -> Error(fields.FieldDecodeError("expected int duration_ms"))
        }
      },
    )

  let bytes_field =
    fields.field(
      atom.create("bytes_sent"),
      fn(b: Int) { Ok(dynamic.int(b)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(i) -> Ok(i)
          Error(_) -> Error(fields.FieldDecodeError("expected int bytes_sent"))
        }
      },
    )

  let assert Ok(meas_pair) = fields.pair(dur_field, bytes_field)
  let meas_fields =
    fields.imap(
      meas_pair,
      fn(p) { HttpMeasurements(p.0, p.1) },
      fn(m: HttpMeasurements) { #(m.duration_ms, m.bytes_sent) },
    )

  let route_field =
    fields.field(
      atom.create("route"),
      fn(r: String) { Ok(dynamic.string(r)) },
      fn(dyn) {
        case decode.run(dyn, decode.string) {
          Ok(s) -> Ok(s)
          Error(_) -> Error(fields.FieldDecodeError("expected string route"))
        }
      },
    )

  let status_field =
    fields.field(
      atom.create("status"),
      fn(s: Int) { Ok(dynamic.int(s)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(s) -> Ok(s)
          Error(_) -> Error(fields.FieldDecodeError("expected int status"))
        }
      },
    )

  let assert Ok(meta_pair) = fields.pair(route_field, status_field)
  let meta_fields =
    fields.imap(
      meta_pair,
      fn(p) { HttpMetadata(method: "GET", route: p.0, status: p.1) },
      fn(m: HttpMetadata) { #(m.route, m.status) },
    )

  sinal.event(
    [atom.create("http"), atom.create("server"), atom.create("request")],
    meas_fields,
    meta_fields,
  )
}

// --- Snippet 2: Emitting Events ---

pub fn log_request(ev: sinal.Event(HttpMeasurements, HttpMetadata)) {
  let meas = HttpMeasurements(duration_ms: 42, bytes_sent: 2048)
  let meta = HttpMetadata(method: "GET", route: "/api/users", status: 200)

  case sinal.emit(ev, meas, meta) {
    Ok(Nil) -> Nil
    Error(sinal.EncodingFailed(fields.FieldEncodeError(msg))) -> panic as msg
    Error(sinal.BackendFailed(msg)) -> panic as msg
  }
}

// --- Snippet 3: Attaching and Detaching Handlers ---

pub fn setup_metrics(ev: sinal.Event(HttpMeasurements, HttpMetadata)) {
  let assert Ok(hid) = sinal.handler_id("prometheus-http-metrics")

  let handler =
    sinal.handler(
      fn(_event, _measurements: HttpMeasurements, _metadata: HttpMetadata) {
        // Record metrics synchronously
        Ok(Nil)
      },
    )

  let on_failure = fn(_event, _failure) {
    // Called if measurements/metadata cannot be decoded or handler returned Error
    Nil
  }

  let assert Ok(attachment) = sinal.attach(hid, ev, handler, on_failure)

  // Later, cleanly detach handler:
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}

// --- Snippet 4: Scoped Attachments (with_attachments) ---

pub fn scoped_metrics_example(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
) -> Result(sinal.ScopedCompletion(Int), sinal.AttachError) {
  let handler =
    sinal.handler(
      fn(_event, _measurements: HttpMeasurements, _metadata: HttpMetadata) {
        Ok(Nil)
      },
    )

  let on_attach_failure = fn(_event, _err) { Nil }
  let on_cleanup_failure = fn(_err) { Nil }

  sinal.with_attachments(
    event,
    [],
    handler,
    on_attach_failure,
    on_cleanup_failure,
    fn() {
      // Work runs with attachments active.
      // Detach runs on normal return or catchable error, exit, or throw.
      // Original error/exit/throw is re-raised with exact origin stacktrace.
      42
    },
  )
}

// --- Snippet 5: Native Telemetry Spans (sinal/span) ---

pub type QueryMeta {
  QueryMeta(sql: String)
}

pub fn query_meta_fields() -> fields.Fields(QueryMeta) {
  let query_key = atom.create("sql")
  fields.field(
    query_key,
    fn(q: QueryMeta) { Ok(dynamic.string(q.sql)) },
    fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(QueryMeta(s))
        Error(_) -> Error(fields.FieldDecodeError("expected string sql"))
      }
    },
  )
}

pub fn run_database_query(query_str: String) -> String {
  // Simulated database execution
  "result for: " <> query_str
}

pub fn execute_traced_query(query_str: String) -> String {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("db"), atom.create("query")])
  let assert Ok(sp) =
    span.define_span(
      prefix,
      query_meta_fields(),
      fields.empty(),
      query_meta_fields(),
    )

  span.run_span(sp, QueryMeta(sql: query_str), fn() {
    let result = run_database_query(query_str)
    span.Completion(
      result: result,
      measurements: Nil,
      metadata: QueryMeta(sql: query_str),
    )
  })
}

// --- Runnable Tests ---

pub fn readme_example_flow_test() {
  let assert Ok(ev) = http_request_event()
  setup_metrics(ev)
  log_request(ev)

  let assert Ok(scoped_completion) = scoped_metrics_example(ev)
  scoped_completion.work_result |> should.equal(42)
}

pub fn readme_span_example_test() {
  let res = execute_traced_query("SELECT 1;")
  res |> should.equal("result for: SELECT 1;")
}

pub fn readme_snippets_match_source_test() {
  let assert Ok(readme_bytes) = read_file("README.md")
  let assert Ok(readme_str) = bit_array.to_string(readme_bytes)
  let snippets = extract_gleam_snippets(readme_str)
  list.length(snippets) |> should.equal(5)

  let assert Ok(source_bytes) = read_file("test/readme_example_test.gleam")
  let assert Ok(source_str) = bit_array.to_string(source_bytes)

  let normalized_source = string.replace(source_str, "\r\n", "\n")

  list.each(snippets, fn(snippet) {
    let normalized_snippet = string.replace(snippet, "\r\n", "\n")
    case string.contains(normalized_source, normalized_snippet) {
      True -> Nil
      False ->
        panic as {
          "README snippet not found verbatim in test/readme_example_test.gleam:\n"
          <> normalized_snippet
        }
    }
  })
}

fn extract_gleam_snippets(markdown: String) -> List(String) {
  let normalized = string.replace(markdown, "\r\n", "\n")
  extract_snippets_loop(normalized, [])
}

fn extract_snippets_loop(remaining: String, acc: List(String)) -> List(String) {
  case string.split_once(remaining, "```gleam\n") {
    Error(Nil) -> list.reverse(acc)
    Ok(#(_before, rest)) -> {
      case string.split_once(rest, "\n```") {
        Error(Nil) -> list.reverse(acc)
        Ok(#(snippet, after)) ->
          extract_snippets_loop(after, [string.trim(snippet), ..acc])
      }
    }
  }
}

@external(erlang, "scope_test_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, String)
