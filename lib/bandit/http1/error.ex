defmodule Bandit.HTTP1.Error do
  # Represents an error suitable for return as an HTTP status
  defexception [:message, :status]
end
