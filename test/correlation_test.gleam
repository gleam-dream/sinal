import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields
import sinal/internal/ffi

@external(erlang, "scope_test_ffi", "native_map")
fn native_map(pairs: List(#(String, Dynamic))) -> Dynamic

pub fn from_string_accepts_one_to_128_bytes_test() {
  correlation.from_string("")
  |> should.equal(Error(correlation.EmptyCorrelation))
  let assert Ok(order) = correlation.from_string("order-42")
  correlation.to_string(order) |> should.equal("order-42")

  let longest = string.repeat("a", 128)
  let assert Ok(value) = correlation.from_string(longest)
  correlation.to_string(value) |> should.equal(longest)
  correlation.from_string(string.repeat("a", 129))
  |> should.equal(
    Error(correlation.CorrelationTooLong(bytes: 129, max_bytes: 128)),
  )

  // The bound is in bytes: 43 three-byte characters are 129 bytes.
  correlation.from_string(string.repeat("€", 43))
  |> should.equal(
    Error(correlation.CorrelationTooLong(bytes: 129, max_bytes: 128)),
  )
  correlation.max_bytes |> should.equal(128)
}

pub fn a_w3c_trace_id_is_a_valid_correlation_test() {
  let trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
  let assert Ok(value) = correlation.from_string(trace_id)
  correlation.to_string(value) |> should.equal(trace_id)
}

pub fn unique_has_the_shape_of_a_trace_id_test() {
  let values = list.map(list.repeat(Nil, 50), fn(_) { correlation.unique() })
  list.each(values, fn(value) {
    let text = correlation.to_string(value)
    string.length(text) |> should.equal(32)
    string.to_graphemes(text)
    |> list.all(fn(c) { string.contains("0123456789abcdef", c) })
    |> should.be_true()
    { text == string.repeat("0", 32) } |> should.be_false()
  })
  list.unique(values) |> list.length |> should.equal(50)
}

pub fn describe_error_names_the_limit_test() {
  correlation.describe_error(correlation.EmptyCorrelation)
  |> should.equal("the correlation is empty")
  correlation.describe_error(correlation.CorrelationTooLong(130, 128))
  |> should.equal("the correlation has 130 bytes, more than 128")
}

pub fn field_writes_a_binary_and_omits_none_test() {
  let field = correlation.field()
  fields.keys(field) |> should.equal(["correlation"])
  let assert Ok(value) = correlation.from_string("job-7")
  fields.encode(field, Some(value))
  |> should.equal(native_map([#("correlation", dynamic.string("job-7"))]))
  fields.encode(field, None) |> should.equal(native_map([]))

  fields.decode(field, native_map([#("correlation", dynamic.string("job-7"))]))
  |> should.equal(Ok(Some(value)))
  fields.decode(field, native_map([])) |> should.equal(Ok(None))
  fields.decode(
    field,
    native_map([#("correlation", ffi.to_dynamic(atom.create("nil")))]),
  )
  |> should.equal(Ok(None))
  fields.decode(
    field,
    native_map([#("correlation", ffi.to_dynamic(atom.create("undefined")))]),
  )
  |> should.equal(Ok(None))
}

pub fn field_rejects_an_invalid_foreign_value_test() {
  let field = correlation.field()
  let assert Error(fields.InvalidField("correlation", [error])) =
    fields.decode(
      field,
      native_map([#("correlation", dynamic.string(string.repeat("x", 129)))]),
    )
  error.expected |> should.equal("a correlation of 1 to 128 bytes")
  let assert Error(fields.InvalidField("correlation", _)) =
    fields.decode(field, native_map([#("correlation", dynamic.string(""))]))
  let assert Error(fields.InvalidField("correlation", _)) =
    fields.decode(field, native_map([#("correlation", dynamic.int(7))]))
}

pub type Job {
  Job(queue: String, correlation: Option(Correlation))
}

pub fn correlation_travels_in_event_metadata_test() {
  let metadata =
    fields.record({
      use queue <- fields.parameter
      use correlation <- fields.parameter
      Job(queue:, correlation:)
    })
    |> fields.and(fields.string("queue"), fn(job: Job) { job.queue })
    |> fields.and(correlation.field(), fn(job) { job.correlation })
    |> fields.build
  let event = sinal.event(["correlation_test", "job"], fields.empty(), metadata)
  let seen = process.new_subject()
  let attachment = sinal.observe(event, fn(_, job) { process.send(seen, job) })

  let id = correlation.unique()
  sinal.emit(event, Nil, Job("mail", Some(id)))
  sinal.emit(event, Nil, Job("mail", None))
  process.receive(seen, 100) |> should.equal(Ok(Job("mail", Some(id))))
  process.receive(seen, 100) |> should.equal(Ok(Job("mail", None)))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn required_field_writes_and_reads_the_same_wire_form_test() {
  let required = correlation.required_field()
  fields.keys(required) |> should.equal(["correlation"])
  let assert Ok(value) = correlation.from_string("job-7")
  fields.encode(required, value)
  |> should.equal(native_map([#("correlation", dynamic.string("job-7"))]))
  fields.decode(
    required,
    native_map([#("correlation", dynamic.string("job-7"))]),
  )
  |> should.equal(Ok(value))
}

pub fn the_two_fields_round_trip_in_both_directions_test() {
  let optional = correlation.field()
  let required = correlation.required_field()
  let value = correlation.unique()

  // required_field() writes, field() reads.
  fields.decode(optional, fields.encode(required, value))
  |> should.equal(Ok(Some(value)))
  // field() writes, required_field() reads.
  fields.decode(required, fields.encode(optional, Some(value)))
  |> should.equal(Ok(value))
  // Both write byte-identical maps.
  fields.encode(required, value)
  |> should.equal(fields.encode(optional, Some(value)))
}

pub fn required_field_fails_on_a_missing_or_invalid_value_test() {
  let required = correlation.required_field()
  fields.decode(required, native_map([]))
  |> should.equal(Error(fields.MissingField("correlation")))
  let assert Error(fields.InvalidField("correlation", [error])) =
    fields.decode(
      required,
      native_map([#("correlation", dynamic.string(string.repeat("x", 129)))]),
    )
  error.expected |> should.equal("a correlation of 1 to 128 bytes")
  let assert Error(fields.InvalidField("correlation", _)) =
    fields.decode(required, native_map([#("correlation", dynamic.string(""))]))
  let assert Error(fields.InvalidField("correlation", _)) =
    fields.decode(required, native_map([#("correlation", dynamic.int(7))]))
  // The atom `nil` means "none" only to `field()`; here it is not a value.
  let assert Error(fields.InvalidField("correlation", _)) =
    fields.decode(
      required,
      native_map([#("correlation", ffi.to_dynamic(atom.create("nil")))]),
    )
}

pub type Ticket {
  Ticket(queue: String, ticket: Correlation)
}

fn ticket_metadata() -> fields.Fields(Ticket) {
  fields.record({
    use queue <- fields.parameter
    use ticket <- fields.parameter
    Ticket(queue:, ticket:)
  })
  |> fields.and(fields.string("queue"), fn(t: Ticket) { t.queue })
  |> fields.and(correlation.required_field(), fn(t) { t.ticket })
  |> fields.build
}

fn library_metadata() -> fields.Fields(Job) {
  fields.record({
    use queue <- fields.parameter
    use correlation <- fields.parameter
    Job(queue:, correlation:)
  })
  |> fields.and(fields.string("queue"), fn(job: Job) { job.queue })
  |> fields.and(correlation.field(), fn(job) { job.correlation })
  |> fields.build
}

pub fn a_field_handler_reads_events_emitted_with_required_field_test() {
  let app_event =
    sinal.event(
      ["correlation_test", "ticket"],
      fields.empty(),
      ticket_metadata(),
    )
  // A library's handler is written against `field()` and the same name.
  let library_event =
    sinal.event(
      ["correlation_test", "ticket"],
      fields.empty(),
      library_metadata(),
    )
  let seen = process.new_subject()
  let attachment =
    sinal.observe(library_event, fn(_, job) { process.send(seen, job) })

  let id = correlation.unique()
  sinal.emit(app_event, Nil, Ticket("support", id))
  process.receive(seen, 100) |> should.equal(Ok(Job("support", Some(id))))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn a_required_handler_reads_events_emitted_with_field_test() {
  let app_event =
    sinal.event(
      ["correlation_test", "inbound"],
      fields.empty(),
      ticket_metadata(),
    )
  let library_event =
    sinal.event(
      ["correlation_test", "inbound"],
      fields.empty(),
      library_metadata(),
    )
  let seen = process.new_subject()
  let failures = process.new_subject()
  let assert Ok(attachment) =
    sinal.attach(
      sinal.handler(
        [app_event],
        fn(_, _, ticket) {
          process.send(seen, ticket)
          Ok(Nil)
        },
        fn(_, failure) { process.send(failures, failure) },
      ),
    )

  let id = correlation.unique()
  sinal.emit(library_event, Nil, Job("mail", Some(id)))
  process.receive(seen, 100) |> should.equal(Ok(Ticket("mail", id)))

  // An event without a correlation is one failed decode: the call is
  // skipped and reported, and the handler stays attached.
  sinal.emit(library_event, Nil, Job("mail", None))
  let assert Ok(sinal.MalformedMetadata(fields.MissingField("correlation"))) =
    process.receive(failures, 100)
  process.receive(seen, 20) |> should.be_error()
  sinal.emit(library_event, Nil, Job("mail", Some(id)))
  process.receive(seen, 100) |> should.equal(Ok(Ticket("mail", id)))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}
