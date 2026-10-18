import gleam/bit_array
import gleam/list
import gleam/string
import gleeunit/should

/// The compiled usage examples are the source of every README snippet.
const example_sources = [
  "examples/usage/src/usage/observe.gleam",
  "examples/usage/src/usage/records.gleam",
  "examples/usage/src/usage/handlers.gleam",
  "examples/usage/src/usage/scopes.gleam",
  "examples/usage/src/usage/spans.gleam",
  "examples/usage/src/usage/forwarding.gleam",
  "examples/usage/src/usage/correlation_ids.gleam",
]

pub fn readme_snippets_match_examples_test() {
  let readme = read_text("README.md")
  let snippets = extract_gleam_snippets(readme)
  list.length(snippets) |> should.equal(3)

  let normalized_source =
    example_sources
    |> list.map(read_text)
    |> string.join("\n")
    |> string.replace("\r\n", "\n")

  list.each(snippets, fn(snippet) {
    let normalized_snippet = string.replace(snippet, "\r\n", "\n")
    case string.contains(normalized_source, normalized_snippet) {
      True -> Nil
      False ->
        panic as {
          "README snippet not found verbatim in examples/usage/src/usage:\n"
          <> normalized_snippet
        }
    }
  })
}

fn read_text(path: String) -> String {
  let assert Ok(bytes) = read_file(path)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
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
