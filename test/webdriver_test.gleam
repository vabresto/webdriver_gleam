import gleam/dynamic
import gleam/http/request.{type Request}
import gleam/httpc
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import snag
import webdriver

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn httpc_send(req: Request(String)) {
  req
  |> httpc.send
  |> result.map_error(fn(err) {
    case err {
      httpc.FailedToConnect(_ip4, _ip6) ->
        snag.new("GET request failed to connect")
      httpc.InvalidUtf8Response -> snag.new("GET request got invalid response")
    }
  })
}

fn make_test_session() -> Result(webdriver.Session, snag.Snag) {
  let remote_driver_url = webdriver.get_default_command_url()
  let wd = webdriver.make_webdriver(remote_driver_url, httpc_send)

  use session <- result.try(fn() {
    webdriver.make_session(wd, webdriver.get_default_session_capabilities())
  }())

  Ok(session)
}

// ---------------------------------------------------------------------------
// Example existing tests
// ---------------------------------------------------------------------------

pub fn get_element_text_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")
  let assert Ok(Some(element)) =
    webdriver.find_element_by_strategy(session, "h1", webdriver.TagNameSelector)
  let assert Ok(text) = webdriver.get_text(element)

  text |> should.equal("Example Domain")

  webdriver.close(session)
}

pub fn cookies_round_trip_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  let cookie_name = "gleam-test-cookie"
  let cookie =
    webdriver.Cookie(
      name: cookie_name,
      value: "shiny",
      path: None,
      domain: None,
      secure: None,
      http_only: None,
      expiry: None,
    )

  io.println("Setting cookie ...")
  let assert Ok(_) = webdriver.cookie_set(session, cookie)
  io.println("Done setting cookie")

  io.println("Getting cookie ...")
  let assert Ok(got_cookie) = webdriver.cookie_get(session, cookie_name)
  io.println("Got cookie")

  cookie.name |> should.equal(got_cookie.name)
  cookie.value |> should.equal(got_cookie.value)

  webdriver.close(session)
}

// ---------------------------------------------------------------------------
// Additional Tests (ChatGPT)
// ---------------------------------------------------------------------------

/// 1. Verify what happens if an element is not found.
///
///    This tests the `None` path in `find_element_by_strategy`.
///    We attempt to find a likely-nonexistent ID on example.com, expecting `None`.
pub fn no_element_found_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  let assert Ok(maybe_element) =
    webdriver.find_element_by_strategy(
      session,
      "#not-a-real-id",
      webdriver.CssSelector,
    )

  case maybe_element {
    Some(_element) -> {
      io.println("Expected to find no element, but got Some(element)!")
      should.fail()
    }
    None ->
      // This is the success path
      1 |> should.equal(1)
  }

  webdriver.close(session)
}

/// 2. Find multiple elements (e.g. all <p> tags) and verify the count.
///
///    This tests `find_elements_by_strategy`.
///    example.com typically has two <p> tags, so we can check for at least 1.
pub fn multiple_elements_found_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  let assert Ok(elements) =
    webdriver.find_elements_by_strategy(session, "p", webdriver.TagNameSelector)
  // Expect at least 1 <p> tag on example.com
  elements
  |> list.length
  |> should.equal(2)

  webdriver.close(session)
}

/// 3. Test retrieving page source.
///
///    Ensures `get_page_source` call works and returns non-empty HTML.
pub fn page_source_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")
  let assert Ok(source) = webdriver.get_page_source(session)

  source |> string.contains("<html") |> should.be_true
  source |> string.contains("Example Domain") |> should.be_true

  webdriver.close(session)
}

/// 4. Test retrieving the current URL.
///
///    Ensures `get_current_url` matches the URL we navigated to.
pub fn current_url_test() {
  let assert Ok(session) = make_test_session()
  let target_url = "https://example.com/"
  let _ = webdriver.navigate(session, target_url)
  let assert Ok(current_url) = webdriver.get_current_url(session)

  current_url |> should.equal(target_url)

  webdriver.close(session)
}

/// 5. Test taking a screenshot.
///
///    This checks the base64 string is returned and is non-empty.
///    (We can't verify the actual PNG, but we can at least check it's not empty.)
pub fn screenshot_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  let assert Ok(image_b64) = webdriver.take_screenshot(session)
  image_b64 |> should.not_equal("")
  image_b64
  // PNGs often start with "iVBORw0KGgo..."
  |> string.starts_with("iVBOR")
  |> should.be_true()

  webdriver.close(session)
}

/// 6. Test JavaScript execution (synchronous).
///
///    We'll query the text from the first <h1> via JS and compare.
pub fn execute_js_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  // A small snippet that gets the text from the <h1> on the page
  // and returns it to WebDriver. The snippet is a normal JS function body.
  // For example.com, the <h1> says "Example Domain".
  let code = "return document.querySelector('h1').innerText;"

  let args = []
  // no arguments needed
  let assert Ok(result_val) = webdriver.execute_js(session, code, args)

  // Attempt to decode it as a string from the dynamic result
  let assert Ok(inner_str) =
    result_val
    |> dynamic.string
    |> result.map_error(fn(_err) {
      snag.new("Failed to decode JS result as string")
    })

  inner_str |> should.equal("Example Domain")

  webdriver.close(session)
}

/// 7. Test JavaScript execution (async).
///
///    We'll wait 1 second in JS and then return a known value.
///    This ensures `execute_js_async` handles the promise-based flow.
pub fn execute_js_async_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  // Schedules a 1-second timer and then returns "done"
  // Note: WebDriver's async script execution expects the user to call a callback,
  // so we typically do something like `arguments[arguments.length - 1]("...")`
  let code =
    "
    var done = arguments[arguments.length - 1];
    setTimeout(function() {
      done('async success');
    }, 1000);
  "

  let args = []
  let assert Ok(result_val) = webdriver.execute_js_async(session, code, args)

  let assert Ok(inner_str) =
    result_val
    |> dynamic.string
    |> result.map_error(fn(_err) {
      snag.new("Failed to decode JS async result as string")
    })

  inner_str |> should.equal("async success")

  webdriver.close(session)
}

/// 8. Test deleting a cookie (and verifying it’s gone).
///
///    We set a cookie, delete it, then confirm it fails to retrieve afterward.
pub fn cookie_delete_test() {
  let assert Ok(session) = make_test_session()
  let _ = webdriver.navigate(session, "https://example.com")

  let cookie_name = "delete-me-cookie"
  let cookie_to_delete =
    webdriver.Cookie(
      name: cookie_name,
      value: "vanish",
      path: None,
      domain: None,
      secure: None,
      http_only: None,
      expiry: None,
    )

  let assert Ok(_) = webdriver.cookie_set(session, cookie_to_delete)
  let assert Ok(_) = webdriver.cookie_delete(session, cookie_name)

  // Attempt to get cookie; we expect an error or not found
  let got_cookie = webdriver.cookie_get(session, cookie_name)

  case got_cookie {
    Ok(_cookie) -> {
      io.println("Expected cookie to be deleted, but still found it!")
      should.fail()
    }
    Error(_err) ->
      // This is success, as the cookie should not be found
      1 |> should.equal(1)
  }

  webdriver.close(session)
}
