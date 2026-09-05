# connect_client errors without credentials

    Code
      connect_client()
    Condition
      Error:
      ! Set the `CONNECT_SERVER` environment variable to your Posit Connect server URL.

---

    Code
      connect_client(server = "https://connect.example.com")
    Condition
      Error:
      ! Set the `CONNECT_API_KEY` environment variable to a Posit Connect API key.

# connect_vanity_guid explains an inaccessible URL

    Code
      connect_vanity_guid(list(server = "https://connect.example.com", api_key = "key"),
      "https://connect.example.com/content/missing", "missing")
    Condition
      Error:
      ! Can't find content for the Connect vanity URL <https://connect.example.com/content/missing>.
      i Check that the URL is correct and that your API key can access the content.

# connect_trace_lines explains auth failures on the traces endpoint

    Code
      connect_trace_lines(list(server = "s", api_key = "k"), "guid")
    Condition
      Error:
      ! Couldn't read this content's traces from Posit Connect.
      i Reading traces requires editor access: the `CONNECT_API_KEY` user must own the content or be a collaborator. See the `share_with` argument of `commons()`.
      Caused by error in `httr2::req_perform()`:
      ! HTTP 403 Forbidden.

# connect_user_guid errors when no user matches

    Code
      connect_user_guid(list(server = "s", api_key = "k"), "jdoe")
    Condition
      Error:
      ! No Connect user with username "jdoe".

