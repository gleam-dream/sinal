import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields
import sinal/forwarder
import sinal/span

// --- Snippet 0: The common path ---

pub fn observe_request_example() {
  let finished =
    sinal.event(
      ["request", "finished"],
      fields.int("duration_ms"),
      fields.string("route"),
    )
  let attachment =
    sinal.observe(finished, fn(_duration_ms, _route) {
      // Runs in the emitting process, before `emit` returns.
      Nil
    })
  sinal.emit(finished, 42, "/users")
  let assert Ok(Nil) = sinal.detach(attachment)
}

// --- Snippet 1: Records as measurements and metadata ---

pub type HttpMeasurements {
  HttpMeasurements(duration_ms: Int, bytes_sent: Int)
}

pub type Method {
  Get
  Post
}

pub type HttpMetadata {
  HttpMetadata(method: Method, route: String, status: Int)
}

pub fn http_request_event() -> sinal.Event(HttpMeasurements, HttpMetadata) {
  let measurements =
    fields.record({
      use duration_ms <- fields.parameter
      use bytes_sent <- fields.parameter
      HttpMeasurements(duration_ms:, bytes_sent:)
    })
    |> fields.and(fields.int("duration_ms"), fn(m: HttpMeasurements) {
      m.duration_ms
    })
    |> fields.and(fields.int("bytes_sent"), fn(m) { m.bytes_sent })
    |> fields.build

  let metadata =
    fields.record({
      use method <- fields.parameter
      use route <- fields.parameter
      use status <- fields.parameter
      HttpMetadata(method:, route:, status:)
    })
    |> fields.and(
      fields.enum("method", [Get, Post], method_name),
      fn(m: HttpMetadata) { m.method },
    )
    |> fields.and(fields.string("route"), fn(m) { m.route })
    |> fields.and(fields.int("status"), fn(m) { m.status })
    |> fields.build

  sinal.event(["http", "server", "request"], measurements, metadata)
}

fn method_name(method: Method) -> String {
  case method {
    Get -> "get"
    Post -> "post"
  }
}

// --- Snippet 2: A fallible handler with a typed failure observer ---

pub fn attach_metrics(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
) -> sinal.Attachment {
  let subscription =
    sinal.handler(
      [event],
      fn(_event, measurements: HttpMeasurements, _metadata: HttpMetadata) {
        case measurements.duration_ms >= 0 {
          True -> Ok(Nil)
          False -> Error("negative duration")
        }
      },
      fn(_event, failure) {
        // A malformed native map skips this one event and keeps the
        // handler; after an `Error` from the handler, telemetry removes it.
        let _ = sinal.describe_handler_failure(failure, fn(e) { e })
        Nil
      },
    )
    |> sinal.with_id("http-metrics")
  let assert Ok(attachment) = sinal.attach(subscription)
  attachment
}

// --- Snippet 3: Scoped subscriptions ---

pub fn count_requests(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
  work: fn() -> a,
) -> Result(sinal.SubscriptionCompletion(a), sinal.SubscriptionScopeError) {
  let seen = process.new_subject()
  let observer = sinal.subscription(event, fn(_, _) { process.send(seen, Nil) })
  // Attached before `work` runs and detached when it returns or raises.
  sinal.with_subscriptions(sinal.subscriptions([observer]), work)
}

// --- Snippet 4: Native spans ---

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

// --- Snippet 5: Isolating a library's events ---

pub fn isolate_library(name: process.Name(forwarder.Message)) -> Nil {
  let observations = forwarder.new(name)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(observations))
    |> static_supervisor.start
  // Every `sinal.emit` of an event named `my_library..` now returns as soon
  // as the event is handed to the forwarder.
  forwarder.route(["my_library"], observations)
}

// --- Snippet 6: A package that owns its forwarder ---

pub fn emit_owned(
  observations: forwarder.Forwarder,
  event: sinal.Event(Int, Nil),
) -> Nil {
  case forwarder.emit(observations, event, 1, Nil) {
    Ok(Nil) -> Nil
    // Dropped and counted in the forwarder's `dropped_event`.
    Error(forwarder.CapacityExceeded) -> Nil
    Error(forwarder.ForwarderUnavailable) -> Nil
  }
}

// --- Snippet 7: Correlation ---

pub type CheckoutMetadata {
  CheckoutMetadata(cart: String, correlation: Option(Correlation))
}

pub fn checkout_event() -> sinal.Event(Nil, CheckoutMetadata) {
  let metadata =
    fields.record({
      use cart <- fields.parameter
      use correlation <- fields.parameter
      CheckoutMetadata(cart:, correlation:)
    })
    |> fields.and(fields.string("cart"), fn(m: CheckoutMetadata) { m.cart })
    |> fields.and(correlation.field(), fn(m) { m.correlation })
    |> fields.build
  sinal.event(["shop", "checkout"], fields.empty(), metadata)
}

pub fn checkout(cart: String, request_id: String) -> Nil {
  // An id from an untrusted header: `from_string` bounds it to 128 bytes.
  let correlation = case correlation.from_string(request_id) {
    Ok(id) -> id
    Error(_) -> correlation.unique()
  }
  sinal.emit(
    checkout_event(),
    Nil,
    CheckoutMetadata(cart:, correlation: Some(correlation)),
  )
}

// --- Snippet 8: A correlation an application event always has ---

pub type TicketMetadata {
  TicketMetadata(ticket: Correlation, queue: String)
}

pub fn ticket_metadata() -> fields.Fields(TicketMetadata) {
  fields.record({
    use ticket <- fields.parameter
    use queue <- fields.parameter
    TicketMetadata(ticket:, queue:)
  })
  |> fields.and(correlation.required_field(), fn(m: TicketMetadata) { m.ticket })
  |> fields.and(fields.string("queue"), fn(m) { m.queue })
  |> fields.build
}

// --- Runnable tests ---

pub fn readme_common_path_test() {
  observe_request_example()
}

pub fn readme_records_round_trip_test() {
  let event = http_request_event()
  let subject = process.new_subject()
  let attachment =
    sinal.observe(event, fn(measurements, metadata) {
      process.send(subject, #(measurements, metadata))
    })
  let measurements = HttpMeasurements(duration_ms: 2, bytes_sent: 5)
  let metadata = HttpMetadata(method: Post, route: "/submit", status: 201)
  sinal.emit(event, measurements, metadata)
  process.receive(subject, 100) |> should.equal(Ok(#(measurements, metadata)))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn readme_fallible_handler_test() {
  let event = http_request_event()
  let attachment = attach_metrics(event)
  sinal.emit(
    event,
    HttpMeasurements(duration_ms: 1, bytes_sent: 1),
    HttpMetadata(method: Get, route: "/", status: 200),
  )
  // A second attach under the same id is refused.
  sinal.attach(
    sinal.subscription(event, fn(_, _) { Nil }) |> sinal.with_id("http-metrics"),
  )
  |> should.equal(Error(sinal.AlreadyExists("http-metrics")))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn readme_scope_test() {
  let event = http_request_event()
  let assert Ok(completion) =
    count_requests(event, fn() {
      sinal.emit(
        event,
        HttpMeasurements(duration_ms: 1, bytes_sent: 1),
        HttpMetadata(method: Get, route: "/", status: 200),
      )
      42
    })
  completion.work_result |> should.equal(42)
  completion.cleanup_failures |> should.equal([])
}

pub fn readme_span_test() {
  traced_query("SELECT 1") |> should.equal(["row for SELECT 1"])
}

pub fn readme_isolation_test() {
  let event =
    sinal.event(["my_library", "request"], fields.int("n"), fields.empty())
  let subject = process.new_subject()
  let attachment =
    sinal.observe(event, fn(n, _) {
      process.send(subject, #(n, process.self()))
    })

  sinal.emit(event, 1, Nil)
  process.receive(subject, 0) |> should.equal(Ok(#(1, process.self())))

  isolate_library(process.new_name("readme_library_forwarder"))
  sinal.emit(event, 2, Nil)
  let assert Ok(#(2, pid)) = process.receive(subject, 500)
  { pid == process.self() } |> should.be_false()

  forwarder.unroute(["my_library"])
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn readme_owned_forwarder_test() {
  let event = sinal.event(["readme", "owned"], fields.int("n"), fields.empty())
  let observations =
    forwarder.new(process.new_name("readme_owned_forwarder"))
    |> forwarder.with_capacity(8)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(observations))
    |> static_supervisor.start
  let subject = process.new_subject()
  let attachment = sinal.observe(event, fn(n, _) { process.send(subject, n) })
  emit_owned(observations, event)
  process.receive(subject, 500) |> should.equal(Ok(1))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn readme_snippets_match_source_test() {
  let assert Ok(readme_bytes) = read_file("README.md")
  let assert Ok(readme_str) = bit_array.to_string(readme_bytes)
  let snippets = extract_gleam_snippets(readme_str)
  list.length(snippets) |> should.equal(9)

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

pub fn readme_correlation_test() {
  let event = checkout_event()
  let seen = process.new_subject()
  let attachment =
    sinal.observe(event, fn(_, metadata) { process.send(seen, metadata) })
  checkout("cart-1", "req-77")
  let assert Ok(CheckoutMetadata("cart-1", Some(id))) =
    process.receive(seen, 100)
  correlation.to_string(id) |> should.equal("req-77")
  checkout("cart-2", "")
  let assert Ok(CheckoutMetadata("cart-2", Some(fresh))) =
    process.receive(seen, 100)
  string.length(correlation.to_string(fresh)) |> should.equal(32)
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn readme_required_correlation_test() {
  let event =
    sinal.event(["readme", "ticket"], fields.empty(), ticket_metadata())
  let seen = process.new_subject()
  let attachment =
    sinal.observe(event, fn(_, metadata) { process.send(seen, metadata) })
  let id = correlation.unique()
  sinal.emit(event, Nil, TicketMetadata(ticket: id, queue: "support"))
  process.receive(seen, 100)
  |> should.equal(Ok(TicketMetadata(ticket: id, queue: "support")))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}
