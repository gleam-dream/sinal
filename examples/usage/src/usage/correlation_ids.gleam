//// Correlation values: optional on an event that may carry one, required on an
//// event that always does.

import gleam/erlang/process
import gleam/option.{type Option, Some}
import gleam/string
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields

pub type CheckoutMetadata {
  CheckoutMetadata(cart: String, correlation: Option(Correlation))
}

pub fn checkout_event() -> sinal.Event(Nil, CheckoutMetadata) {
  let metadata = {
    use cart <- fields.include(fields.string("cart"), get: fn(m) { m.cart })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    fields.success(CheckoutMetadata(cart:, correlation:))
  }
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

pub type TicketMetadata {
  TicketMetadata(ticket: Correlation, queue: String)
}

pub fn ticket_metadata() -> fields.Fields(TicketMetadata) {
  use ticket <- fields.include(correlation.required_field(), get: fn(m) {
    m.ticket
  })
  use queue <- fields.include(fields.string("queue"), get: fn(m) { m.queue })
  fields.success(TicketMetadata(ticket:, queue:))
}

/// Emit with a supplied id and with a missing one, then with a required id.
pub fn run() -> Nil {
  let event = checkout_event()
  let seen = process.new_subject()
  let attachment =
    sinal.observe(event, fn(_, metadata) { process.send(seen, metadata) })
  checkout("cart-1", "req-77")
  let assert Ok(CheckoutMetadata("cart-1", Some(id))) =
    process.receive(seen, 100)
  assert correlation.to_string(id) == "req-77"
  checkout("cart-2", "")
  let assert Ok(CheckoutMetadata("cart-2", Some(fresh))) =
    process.receive(seen, 100)
  assert string.length(correlation.to_string(fresh)) == 32
  let assert Ok(Nil) = sinal.detach(attachment)

  let ticket =
    sinal.event(["usage", "ticket"], fields.empty(), ticket_metadata())
  let ticket_seen = process.new_subject()
  let ticket_attachment =
    sinal.observe(ticket, fn(_, metadata) {
      process.send(ticket_seen, metadata)
    })
  let id = correlation.unique()
  sinal.emit(ticket, Nil, TicketMetadata(ticket: id, queue: "support"))
  assert process.receive(ticket_seen, 100)
    == Ok(TicketMetadata(ticket: id, queue: "support"))
  let assert Ok(Nil) = sinal.detach(ticket_attachment)
  Nil
}
