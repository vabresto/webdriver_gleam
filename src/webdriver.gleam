//// This entire module is based on https://github.com/dom96/webdriver/blob/master/src/webdriver.nim

import gleam/bool
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import snag

pub type ExecCmd =
  fn(Request(String)) -> Result(Response(String), snag.Snag)

pub opaque type Webdriver {
  Webdriver(url: String, exec_cmd: ExecCmd)
}

pub opaque type Session {
  Session(id: String, webdriver: Webdriver)
}

pub opaque type Element {
  Element(id: String, session: Session)
}

pub type Cookie {
  Cookie(
    name: String,
    value: String,
    path: Option(String),
    domain: Option(String),
    secure: Option(Bool),
    http_only: Option(Bool),
    expiry: Option(Int),
  )
}

pub type LocationStrategy {
  CssSelector
  LinkTextSelector
  PartialLinkTextSelector
  TagNameSelector
  XPathSelector
}

type WebdriverResponse {
  WebdriverResponse(status: Int, value: dynamic.Dynamic)
}

// Special id defined by the webdriver spec to reference an element
const element_webdriver_id = "element-6066-11e4-a52e-4f735466cecf"

pub fn get_default_session_capabilities() {
  json.object([
    #("capabilities", json.object([#("browserName", json.string("firefox"))])),
  ])
}

pub fn element_to_json(element: Element) -> json.Json {
  json.object([
    #("ELEMENT", json.string(element.id)),
    #(element_webdriver_id, json.string(element.id)),
  ])
}

pub fn cookie_to_json(cookie: Cookie) -> json.Json {
  let inner = [
    #("name", json.string(cookie.name)),
    #("value", json.string(cookie.value)),
  ]

  let inner = case cookie.path {
    Some(path) -> [#("path", json.string(path)), ..inner]
    None -> inner
  }

  let inner = case cookie.domain {
    Some(domain) -> [#("domain", json.string(domain)), ..inner]
    None -> inner
  }

  let inner = case cookie.secure {
    Some(secure) -> [#("secure", json.bool(secure)), ..inner]
    None -> inner
  }

  let inner = case cookie.http_only {
    Some(http_only) -> [#("httpOnly", json.bool(http_only)), ..inner]
    None -> inner
  }

  let inner = case cookie.expiry {
    Some(expiry) -> [#("expiry", json.int(expiry)), ..inner]
    None -> inner
  }

  json.object([#("cookie", json.object(inner))])
}

pub fn cookie_decoder() -> decode.Decoder(Cookie) {
  use name <- decode.field("name", decode.string)
  use value <- decode.field("value", decode.string)
  use path <- decode.optional_field(
    "path",
    None,
    decode.optional(decode.string),
  )
  use domain <- decode.optional_field(
    "domain",
    None,
    decode.optional(decode.string),
  )
  use secure <- decode.optional_field(
    "secure",
    None,
    decode.optional(decode.bool),
  )
  use http_only <- decode.optional_field(
    "httpOnly",
    None,
    decode.optional(decode.bool),
  )
  use expiry <- decode.optional_field(
    "expiry",
    None,
    decode.optional(decode.int),
  )
  decode.success(Cookie(
    name:,
    value:,
    path:,
    domain:,
    secure:,
    http_only:,
    expiry:,
  ))
}

fn strategy_to_keyword(strategy: LocationStrategy) -> String {
  case strategy {
    CssSelector -> "css selector"
    LinkTextSelector -> "link text"
    PartialLinkTextSelector -> "partial link text"
    TagNameSelector -> "tag name"
    XPathSelector -> "xpath"
  }
}

/// Defaults to http://localhost:4444
pub fn get_default_command_url() -> String {
  "http://localhost:4444"
}

pub fn make_webdriver(url: String, exec_cmd: ExecCmd) {
  Webdriver(url:, exec_cmd:)
}

fn parse_json_wrapper() {
  use value <- decode.field("value", decode.dynamic)
  decode.success(value)
}

fn json_error_to_snag(json_err: json.DecodeError) {
  case json_err {
    json.UnexpectedEndOfInput -> snag.new("Unexpected end of input")
    json.UnexpectedByte(msg) -> snag.new("Unexpected byte: " <> msg)
    json.UnexpectedSequence(msg) -> snag.new("Unexpected sequence: " <> msg)
    json.UnexpectedFormat(_data) -> snag.new("Unexpected format")
    json.UnableToDecode(_data) -> snag.new("Unable to decode")
  }
}

fn extract_json_from_resp(
  resp: Response(String),
) -> Result(dynamic.Dynamic, snag.Snag) {
  resp.body
  |> json.parse(parse_json_wrapper())
  |> result.map_error(json_error_to_snag)
}

fn extract_json_reply(
  resp: Result(Response(String), snag.Snag),
) -> Result(dynamic.Dynamic, snag.Snag) {
  case resp {
    Ok(resp) -> extract_json_from_resp(resp)
    Error(_) -> {
      resp
      |> result.map(dynamic.from)
      |> result.map_error(fn(err) {
        snag.layer(err, "Failed to get webdriver status")
      })
    }
  }
}

fn extract_response(
  resp: Result(Response(String), snag.Snag),
) -> Result(WebdriverResponse, snag.Snag) {
  case resp {
    Ok(resp) -> {
      resp.body
      |> json.parse(parse_json_wrapper())
      |> result.map_error(json_error_to_snag)
      |> result.map(fn(dyn_data) {
        Ok(WebdriverResponse(status: resp.status, value: dyn_data))
      })
      |> result.flatten
    }
    Error(err) -> {
      Error(
        err
        |> snag.layer("Failed to extract webdriver response"),
      )
    }
  }
}

fn post_json(
  webdriver: Webdriver,
  url: String,
  data: json.Json,
) -> Result(dynamic.Dynamic, snag.Snag) {
  let assert Ok(req) = request.to(url)
  req
  |> request.set_method(http.Post)
  |> request.set_body(json.to_string(data))
  |> io.debug
  |> webdriver.exec_cmd
  |> extract_json_reply
  |> io.debug
}

fn get_content_json(
  webdriver: Webdriver,
  url: String,
) -> Result(WebdriverResponse, snag.Snag) {
  let assert Ok(req) = request.to(url)
  req
  |> request.set_method(http.Get)
  |> webdriver.exec_cmd
  // |> extract_json_reply
  |> extract_response
}

fn response_as_string(resp: WebdriverResponse) {
  dynamic.string(resp.value)
  |> result.map_error(fn(_err) {
    io.print("TOOD: handle all decode errors")
    snag.new("Failed to reinterpret response as string")
  })
}

fn extract_string_field(
  data: Result(dynamic.Dynamic, snag.Snag),
  key: String,
) -> Result(String, snag.Snag) {
  data
  |> result.map(fn(data) {
    data
    |> dynamic.field(key, dynamic.string)
    |> result.map_error(fn(_err) { snag.new("Failed to parse key" <> key) })
  })
  |> result.flatten
}

// fn reinterpret_as_string(
//   data: Result(dynamic.Dynamic, snag.Snag),
// ) -> Result(String, snag.Snag) {
//   data
//   |> result.map(fn(data) {
//     dynamic.string(data)
//     |> io.debug
//     |> result.map_error(fn(_err) { snag.new("Failed to reinterpret_as_string") })
//   })
//   |> result.flatten
// }

fn reinterpret_as_null(
  data: Result(dynamic.Dynamic, snag.Snag),
) -> Result(Nil, snag.Snag) {
  data
  |> result.map(fn(data) {
    dynamic.optional(dynamic.string)(data)
    |> result.map_error(fn(_err) { snag.new("Failed to reinterpret_as_null") })
    |> result.map(fn(data) {
      case data {
        Some(str) ->
          Error(snag.new(
            "Reinterpret as null resulted in unexpected string: " <> str,
          ))
        None -> Ok(Nil)
      }
    })
    |> result.flatten
  })
  |> result.flatten
}

pub fn make_session(
  webdriver: Webdriver,
  capabilities: json.Json,
) -> Result(Session, snag.Snag) {
  let assert Ok(req) = request.to(webdriver.url <> "/status")
  let is_ready =
    req
    |> request.set_method(http.Get)
    |> webdriver.exec_cmd
    |> extract_json_reply
    |> result.map(fn(data) {
      data
      |> dynamic.field("ready", dynamic.bool)
      |> result.map_error(fn(_err) { snag.new("Failed to parse ready status") })
    })
    |> result.flatten
    |> result.unwrap(False)

  use <- bool.guard(
    when: !is_ready,
    return: Error(snag.new("Webdriver not ready")),
  )

  io.println("Webdriver ready")

  // Webdriver is ready, now create our session
  post_json(webdriver, webdriver.url <> "/session", capabilities)
  |> io.debug
  |> extract_string_field("sessionId")
  |> result.map(fn(session_id) { Session(id: session_id, webdriver: webdriver) })
}

pub fn close(session: Session) -> Result(Nil, snag.Snag) {
  let assert Ok(req) =
    request.to(session.webdriver.url <> "/session/" <> session.id)
  req
  |> request.set_method(http.Delete)
  |> session.webdriver.exec_cmd
  |> result.map(fn(_) { Nil })
}

pub fn navigate(session: Session, url: String) -> Result(Session, snag.Snag) {
  io.println("Navigating to: " <> url)

  post_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/url",
    json.object([#("url", json.string(url))]),
  )
  |> result.map(fn(_) { session })
}

pub fn get_page_source(session: Session) -> Result(String, snag.Snag) {
  get_content_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/source",
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map_error(fn(res) {
    snag.layer(res, "Failed to extract page source")
  })
}

pub fn get_current_url(session: Session) -> Result(String, snag.Snag) {
  get_content_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/url",
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map_error(fn(res) { snag.layer(res, "Failed to parse current url") })
}

pub fn find_element(session: Session, selector: String) {
  find_element_by_strategy(session, selector, CssSelector)
}

pub fn find_element_by_strategy(
  session: Session,
  selector: String,
  strategy: LocationStrategy,
) -> Result(Option(Element), snag.Snag) {
  let assert Ok(req) =
    request.to(session.webdriver.url <> "/session/" <> session.id <> "/element")
  let data =
    json.object([
      #("value", json.string(selector)),
      #("using", json.string(strategy_to_keyword(strategy))),
    ])

  req
  |> request.set_method(http.Post)
  |> request.set_body(json.to_string(data))
  |> session.webdriver.exec_cmd
  |> result.map(fn(resp) {
    let response.Response(status, _, _) = resp
    case status {
      404 -> Ok(None)
      200 -> {
        resp
        |> extract_json_from_resp
        // https://github.com/jlipps/simple-wd-spec?tab=readme-ov-file#find-element
        |> extract_string_field(element_webdriver_id)
        |> result.map(fn(id) { Some(Element(id:, session:)) })
      }
      _ -> Error(snag.new("Got non-200 response in find_element_by_strategy"))
    }
  })
  |> result.flatten
}

pub fn find_elements(session: Session, selector: String) {
  find_elements_by_strategy(session, selector, CssSelector)
}

pub fn find_elements_by_strategy(
  session: Session,
  selector: String,
  strategy: LocationStrategy,
) -> Result(List(Element), snag.Snag) {
  let assert Ok(req) =
    request.to(
      session.webdriver.url <> "/session/" <> session.id <> "/elements",
    )
  let data =
    json.object([
      #("value", json.string(selector)),
      #("using", json.string(strategy_to_keyword(strategy))),
    ])

  req
  |> request.set_method(http.Post)
  |> request.set_body(json.to_string(data))
  |> session.webdriver.exec_cmd
  |> result.map(fn(resp) {
    let response.Response(status, _, _) = resp
    case status {
      404 -> Ok([])
      200 -> {
        // Resp looks something like:
        // {
        //   "value": [
        //       {"element-6066-11e4-a52e-4f735466cecf": "1234-5789-0abc-defg"},
        //       {"element-6066-11e4-a52e-4f735466cecf": "5678-1234-defg-0abc"}
        //   ]
        // }
        resp
        |> extract_json_from_resp
        |> result.map(fn(resp_json) {
          dynamic.list(fn(inner_json) {
            dynamic.field(element_webdriver_id, dynamic.string)(inner_json)
            |> result.map(fn(id) { Element(id:, session:) })
          })(resp_json)
          |> result.map_error(fn(_err) {
            snag.new("Failed to get list of elements")
          })
        })
        |> result.flatten
      }
      _ -> Error(snag.new("Got non-200 response in find_element_by_strategy"))
    }
  })
  |> result.flatten
}

pub fn get_text(element: Element) -> Result(String, snag.Snag) {
  get_content_json(
    element.session.webdriver,
    element.session.webdriver.url
      <> "/session/"
      <> element.session.id
      <> "/element/"
      <> element.id
      <> "/text",
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map_error(fn(res) {
    snag.layer(res, "Failed to get text from element")
  })
}

pub fn get_attribute(
  element: Element,
  name: String,
) -> Result(String, snag.Snag) {
  get_content_json(
    element.session.webdriver,
    element.session.webdriver.url
      <> "/session/"
      <> element.session.id
      <> "/element/"
      <> element.id
      <> "/attribute/"
      <> name,
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map_error(fn(res) {
    snag.layer(res, "Failed to get attribute from element")
  })
}

pub fn get_property(element: Element, name: String) -> Result(String, snag.Snag) {
  get_content_json(
    element.session.webdriver,
    element.session.webdriver.url
      <> "/session/"
      <> element.session.id
      <> "/element/"
      <> element.id
      <> "/property/"
      <> name,
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map_error(fn(res) {
    snag.layer(res, "Failed to get property from element")
  })
}

// Returns base64 encoded screenshot
pub fn take_screenshot(session: Session) -> Result(String, snag.Snag) {
  get_content_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/screenshot",
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map_error(fn(res) { snag.layer(res, "Failed to take a screenshot") })
}

pub fn clear(element: Element) -> Result(Nil, snag.Snag) {
  post_json(
    element.session.webdriver,
    element.session.webdriver.url
      <> "/session/"
      <> element.session.id
      <> "/element/"
      <> element.id
      <> "/clear",
    // Intentionally empty object
    json.object([]),
  )
  |> reinterpret_as_null
}

pub fn click(element: Element) -> Result(Nil, snag.Snag) {
  post_json(
    element.session.webdriver,
    element.session.webdriver.url
      <> "/session/"
      <> element.session.id
      <> "/element/"
      <> element.id
      <> "/click",
    // Intentionally empty object
    json.object([]),
  )
  |> reinterpret_as_null
}

pub fn send_keys(element: Element, text: String) -> Result(Nil, snag.Snag) {
  post_json(
    element.session.webdriver,
    element.session.webdriver.url
      <> "/session/"
      <> element.session.id
      <> "/element/"
      <> element.id
      <> "/value",
    json.object([#("text", json.string(text))]),
  )
  |> reinterpret_as_null
}

fn extract_js_error(
  raw_val: Result(dynamic.Dynamic, snag.Snag),
) -> Result(dynamic.Dynamic, snag.Snag) {
  case raw_val {
    Ok(val) -> {
      // note: in the error case, we can also get a stack trace
      case val |> dynamic.field(named: "error", of: dynamic.string) {
        Ok(err) -> Error(snag.new("Javascript error: " <> err))
        _ -> raw_val
      }
    }
    Error(_) -> raw_val
  }
}

type JavascriptSynchronicity {
  Sync
  Async
}

fn synchronicity_to_string(synchronicity: JavascriptSynchronicity) -> String {
  case synchronicity {
    Sync -> "sync"
    Async -> "async"
  }
}

fn execute_js_internal(
  session: Session,
  code: String,
  args: List(json.Json),
  synchronicity: JavascriptSynchronicity,
) -> Result(dynamic.Dynamic, snag.Snag) {
  let payload =
    json.object([
      #("script", json.string(code)),
      #("args", json.array(args, fn(x) { x })),
    ])
  post_json(
    session.webdriver,
    session.webdriver.url
      <> "/session/"
      <> session.id
      <> "/execute/"
      <> synchronicity_to_string(synchronicity),
    payload,
  )
  |> extract_js_error
}

pub fn execute_js(
  session: Session,
  code: String,
  args: List(json.Json),
) -> Result(dynamic.Dynamic, snag.Snag) {
  execute_js_internal(session, code, args, Sync)
}

pub fn execute_js_async(
  session: Session,
  code: String,
  args: List(json.Json),
) -> Result(dynamic.Dynamic, snag.Snag) {
  execute_js_internal(session, code, args, Async)
}

pub fn cookie_set(session: Session, cookie: Cookie) -> Result(Nil, snag.Snag) {
  post_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/cookie",
    cookie_to_json(cookie),
  )
  |> reinterpret_as_null
}

pub fn cookie_delete(session: Session, name: String) -> Result(Nil, snag.Snag) {
  let assert Ok(req) =
    request.to(
      session.webdriver.url <> "/session/" <> session.id <> "/cookie/" <> name,
    )
  req
  |> request.set_method(http.Delete)
  |> session.webdriver.exec_cmd
  |> result.map(fn(_) { Nil })
}

pub fn cookie_delete_all(session: Session) -> Result(Nil, snag.Snag) {
  let assert Ok(req) =
    request.to(session.webdriver.url <> "/session/" <> session.id <> "/cookie")
  req
  |> request.set_method(http.Delete)
  |> session.webdriver.exec_cmd
  |> result.map(fn(_) { Nil })
}

pub fn cookie_get(session: Session, name: String) -> Result(Cookie, snag.Snag) {
  get_content_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/cookie/" <> name,
  )
  |> result.map(fn(data) {
    decode.run(data.value, cookie_decoder())
    |> result.map_error(fn(_err) {
      snag.new("Failed to decode cookie response json")
    })
  })
  |> result.flatten
}

pub fn cookie_get_all(session: Session) -> Result(List(Cookie), snag.Snag) {
  get_content_json(
    session.webdriver,
    session.webdriver.url <> "/session/" <> session.id <> "/cookie",
  )
  |> result.map(response_as_string)
  |> result.flatten
  |> result.map(fn(data) {
    json.parse(data, decode.list(of: cookie_decoder()))
    |> result.map_error(fn(_err) {
      snag.new("Failed to decode cookie response json")
    })
  })
  |> result.flatten
}

pub fn main() {
  io.println("Hello from webdriver!")

  let exec_cmd = fn(req: Request(String)) {
    req
    |> httpc.send
    |> result.map_error(fn(err) {
      case err {
        httpc.FailedToConnect(_ip4, _ip6) ->
          snag.new("GET request failed to connect")
        httpc.InvalidUtf8Response ->
          snag.new("GET request got invalid response")
      }
    })
  }

  let webdriver = make_webdriver(get_default_command_url(), exec_cmd)
  use session <- result.try(fn() {
    make_session(webdriver, get_default_session_capabilities())
  }())

  // let _ =
  //   session
  //   |> navigate("https://google.com")
  //   |> result.map(get_current_url)

  let _ =
    navigate(
      session,
      "https://www.amazon.co.uk/Nintendo-Classic-Mini-Entertainment-System/dp/B073BVHY3F",
    )
  // let element_text =
  //   find_element(session, "#productTitle")
  //   |> result.map(fn(ele) {
  //     case ele {
  //       Some(ele) -> get_text(ele)
  //       None -> Ok("")
  //     }
  //   })
  //   |> result.flatten

  // case element_text {
  //   Ok(element_text) -> io.println("Element text: " <> element_text)
  //   Error(err) -> io.println("Error: " <> snag.pretty_print(err))
  // }

  let _ =
    find_elements(session, "#productTitle")
    |> result.map(fn(eles) {
      eles
      |> list.map(fn(ele) {
        ele
        |> get_text
        |> io.debug
      })
    })

  process.sleep(5000)

  session
  |> close
  |> io.debug
}
