//// Records as measurements and metadata, and enums as field values.

import gleam/erlang/process
import gleam/list
import sinal
import sinal/fields

// snips-start: records-and-enums
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
  let measurements = {
    use duration_ms <- fields.include(fields.int("duration_ms"), get: fn(m) {
      m.duration_ms
    })
    use bytes_sent <- fields.include(fields.int("bytes_sent"), get: fn(m) {
      m.bytes_sent
    })
    fields.success(HttpMeasurements(duration_ms:, bytes_sent:))
  }

  let metadata = {
    use method <- fields.include(
      fields.enum("method", [Get, Post], method_name),
      get: fn(m) { m.method },
    )
    use route <- fields.include(fields.string("route"), get: fn(m) { m.route })
    use status <- fields.include(fields.int("status"), get: fn(m) { m.status })
    fields.success(HttpMetadata(method:, route:, status:))
  }

  sinal.event(["http", "server", "request"], measurements, metadata)
}

fn method_name(method: Method) -> String {
  case method {
    Get -> "get"
    Post -> "post"
  }
}

// snips-end: records-and-enums

/// An exhaustive naming function does not prove that an enum's value list is
/// complete, so list every constructor and round-trip each one.
pub fn every_method_is_listed() -> Nil {
  let metadata = sinal.metadata_fields(http_request_event())
  list.each([Get, Post], fn(method) {
    let sample = HttpMetadata(method:, route: "/", status: 200)
    let assert Ok(Nil) = fields.check(metadata, sample)
    let assert Ok(decoded) =
      fields.decode(metadata, fields.encode(metadata, sample))
    assert decoded == sample
  })
}

/// Emit a record pair and check that the handler receives the same values.
pub fn run() -> Nil {
  every_method_is_listed()

  let event = http_request_event()
  let seen = process.new_subject()
  let attachment =
    sinal.observe(event, fn(measurements, metadata) {
      process.send(seen, #(measurements, metadata))
    })
  let measurements = HttpMeasurements(duration_ms: 2, bytes_sent: 5)
  let metadata = HttpMetadata(method: Post, route: "/submit", status: 201)
  sinal.emit(event, measurements, metadata)
  assert process.receive(seen, 100) == Ok(#(measurements, metadata))
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}
