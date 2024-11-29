defmodule Bandit.SocketError do
  # Represents an error coming from the underlying socket which cannot be signalled back to the
  # client, such as :closed
  defexception message: nil, socket_error: nil
end
