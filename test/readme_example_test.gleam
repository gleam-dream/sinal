import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import sinal
import sinal/fields
import sinal/forwarder
import sinal/span

// --- Snippet 0: Ordinary observation ---

pub fn observe_request_example() {
  let assert Ok(ev) =
    sinal.event(
      [atom.create("request"), atom.create("finished")],
      fields.int(atom.create("duration_ms")),
      fields.string(atom.create("route")),
    )
  let assert Ok(id) = sinal.handler_id("request-finished-observer")
  let assert Ok(attachment) =
    sinal.observe(id, ev, fn(_duration_ms, _route) {
      // Handle the event synchronously in the emitting process.
      Nil
    })
  let assert Ok(Nil) = sinal.emit(ev, 42, "/users")
  let assert Ok(Nil) = sinal.detach(attachment)
}

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
  let assert Ok(meas_pair) =
    fields.pair(
      fields.int(atom.create("duration_ms")),
      fields.int(atom.create("bytes_sent")),
    )
  let meas_fields =
    fields.imap(
      meas_pair,
      fn(p) { HttpMeasurements(p.0, p.1) },
      fn(m: HttpMeasurements) { #(m.duration_ms, m.bytes_sent) },
    )

  let assert Ok(method_route) =
    fields.pair(
      fields.string(atom.create("method")),
      fields.string(atom.create("route")),
    )
  let assert Ok(meta_triple) =
    fields.pair(method_route, fields.int(atom.create("status")))
  let meta_fields =
    fields.imap(
      meta_triple,
      fn(p) {
        let #(#(method, route), status) = p
        HttpMetadata(method: method, route: route, status: status)
      },
      fn(m: HttpMetadata) { #(#(m.method, m.route), m.status) },
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
  }
}

// --- Snippet 3: Attaching and Detaching Handlers ---

pub fn setup_metrics(ev: sinal.Event(HttpMeasurements, HttpMetadata)) {
  let assert Ok(hid) = sinal.handler_id("prometheus-http-metrics")

  let handler = fn(
    _event,
    _measurements: HttpMeasurements,
    _metadata: HttpMetadata,
  ) {
    // Record metrics synchronously
    Ok(Nil)
  }

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
) -> Result(sinal.SubscriptionCompletion(Int), sinal.SubscriptionScopeError) {
  let observer = sinal.subscription(event, fn(_measurements, _metadata) { Nil })

  sinal.with_subscriptions(sinal.subscriptions([observer]), fn() {
    // Work runs with attachments active.
    // Detach runs on normal return or catchable error, exit, or throw.
    // Original error/exit/throw is re-raised with exact origin stacktrace.
    42
  })
}

// --- Snippet 5: Native Telemetry Spans (sinal/span) ---

pub type QueryMeta {
  QueryMeta(sql: String)
}

pub fn query_meta_fields() -> fields.Fields(QueryMeta) {
  fields.imap(fields.string(atom.create("sql")), QueryMeta, fn(q: QueryMeta) {
    q.sql
  })
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

// --- Snippet 6: Forwarded Delivery (sinal/forwarder) ---

pub fn build_supervisor(forwarder_name: process.Name(forwarder.Message)) {
  let assert Ok(fwd) = forwarder.new(forwarder_name, 1024)
  let assert Ok(_started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(fwd))
    |> static_supervisor.start
  fwd
}

pub fn emit_via_forwarder(
  fwd: forwarder.Forwarder,
  ev,
  measurements,
  metadata,
) {
  case forwarder.emit(fwd, ev, measurements, metadata) {
    Ok(Nil) -> Nil
    Error(forwarder.ForwardEncodingFailed(_)) -> panic as "bad event shape"
    Error(forwarder.CapacityExceeded) -> Nil
    Error(forwarder.ForwarderUnavailable) -> Nil
  }
}

// --- Runnable Tests ---

// --- Snippet 7: Routing a library's events (sinal/forwarder) ---

pub fn route_library_events(fwd: forwarder.Forwarder) -> Nil {
  // Application start, after the forwarder is supervised.
  forwarder.route([atom.create("my_library")], fwd)
}

pub fn library_observe(ev, measurements, metadata) -> Nil {
  // Library code: forwarded if the application routed this name,
  // synchronous otherwise. Drops are the forwarder's to report.
  let _ = forwarder.emit_routed(ev, measurements, metadata)
  Nil
}

pub fn readme_example_flow_test() {
  let assert Ok(ev) = http_request_event()
  setup_metrics(ev)
  log_request(ev)

  let assert Ok(scoped_completion) = scoped_metrics_example(ev)
  scoped_completion.work_result |> should.equal(42)
}

pub fn readme_http_metadata_preserves_method_test() {
  let assert Ok(event) = http_request_event()
  let assert Ok(id) = sinal.handler_id("readme-method-preserved")
  let subject = process.new_subject()
  let assert Ok(attachment) =
    sinal.observe(id, event, fn(_, metadata) {
      process.send(subject, metadata.method)
    })
  let assert Ok(Nil) =
    sinal.emit(
      event,
      HttpMeasurements(duration_ms: 2, bytes_sent: 5),
      HttpMetadata(method: "POST", route: "/submit", status: 201),
    )
  process.receive(subject, 100) |> should.equal(Ok("POST"))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn readme_span_example_test() {
  let res = execute_traced_query("SELECT 1;")
  res |> should.equal("result for: SELECT 1;")
}

pub fn readme_forwarder_example_test() {
  let forwarder_name = process.new_name("readme-forwarder-example")
  let fwd = build_supervisor(forwarder_name)

  let assert Ok(ev) =
    sinal.event(
      [atom.create("readme"), atom.create("forwarded")],
      fields.int(atom.create("n")),
      fields.empty(),
    )
  let assert Ok(id) = sinal.handler_id("readme-forwarder-observer")
  let subject = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(id, ev, fn(n, _) { process.send(subject, n) })

  emit_via_forwarder(fwd, ev, 7, Nil)
  process.receive(subject, 200) |> should.equal(Ok(7))
}

pub fn readme_routing_example_test() {
  let fwd = build_supervisor(process.new_name("readme-routing-example"))
  let assert Ok(ev) =
    sinal.event(
      [atom.create("my_library"), atom.create("request")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(id) = sinal.handler_id("readme-routing-observer")
  let subject = process.new_subject()
  let assert Ok(attachment) =
    sinal.observe(id, ev, fn(_, _) { process.send(subject, process.self()) })

  library_observe(ev, Nil, Nil)
  let assert Ok(synchronous) = process.receive(subject, 0)
  synchronous |> should.equal(process.self())

  route_library_events(fwd)
  library_observe(ev, Nil, Nil)
  let assert Ok(forwarded) = process.receive(subject, 200)
  { forwarded == process.self() } |> should.equal(False)

  forwarder.unroute([atom.create("my_library")])
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn readme_snippets_match_source_test() {
  let assert Ok(readme_bytes) = read_file("README.md")
  let assert Ok(readme_str) = bit_array.to_string(readme_bytes)
  let snippets = extract_gleam_snippets(readme_str)
  list.length(snippets) |> should.equal(8)

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
