defmodule Bandit.HTTPError do
  # Represents an error suitable for return as an HTTP status. Note that these may be surfaced
  # from anywhere that such a message is well defined, including within HTTP/1 transport concerns
  # and also within shared HTTP semantics (ie: within Bandit.Adapter or Bandit.Pipeline)
  defexception message: nil, plug_status: :bad_request
end
