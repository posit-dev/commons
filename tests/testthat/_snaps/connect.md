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

