defmodule Bandit.BodyAlreadyReadError do
  @moduledoc """
  Raised by Bandit adapters if a body is attempted to be read more than once per request
  """

  defexception message: "Body has already been read"
end
