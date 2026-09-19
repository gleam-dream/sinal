import gleeunit
import gleeunit/should
import sinal

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn version_test() {
  sinal.version()
  |> should.equal("0.1.0")
}
