defmodule Bandit.TransportError do
  # Represents an error coming from the underlying transport which cannot be signalled back to the
  # client by conventional means within the request. Examples include TCP socket closures and
  # errors in the case of HTTP/1, and stream resets in HTTP/2
  defexception message: nil, error: nil
end
