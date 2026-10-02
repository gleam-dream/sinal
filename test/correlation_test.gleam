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
