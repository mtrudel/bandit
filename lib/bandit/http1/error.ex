defmodule Bandit.HTTP1.Error do
  # Represents an error suitable for return as an HTTP status
  defexception [:message, :method, :request_target, :status]
end
