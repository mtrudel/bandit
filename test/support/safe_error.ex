defmodule SafeError do
  defexception(message: nil)

  defimpl Plug.Exception do
    def status(_), do: :im_a_teapot
    def actions(_), do: []
  end
end
