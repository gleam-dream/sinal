import gleeunit
import usage/correlation_ids
import usage/forwarding
import usage/handlers
import usage/observe
import usage/records
import usage/scopes
import usage/spans

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn observe_test() {
  observe.run()
}

pub fn records_test() {
  records.run()
}

pub fn handlers_test() {
  handlers.run()
}

pub fn scopes_test() {
  scopes.run()
}

pub fn spans_test() {
  spans.run()
}

pub fn forwarding_test() {
  forwarding.run()
}

pub fn correlation_ids_test() {
  correlation_ids.run()
}
