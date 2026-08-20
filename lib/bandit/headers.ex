defmodule Bandit.Headers do
  @moduledoc false
  # Conveniences for dealing with headers.

  @invalid_field_value_pattern_key {__MODULE__, :invalid_field_value_pattern}

  @spec is_port_number(integer()) :: Macro.t()
  defguardp is_port_number(port) when Bitwise.band(port, 0xFFFF) === port

  # RFC9110§5.5 / RFC9113§8.2.1: field values containing CR, LF, or NUL characters
  # are invalid and dangerous (a common request-smuggling / response-splitting /
  # log-injection vector). Shared by both HTTP/1 and HTTP/2 so that neither
  # transport can drift from the other's validation. The match pattern is
  # compiled once (lazily, on first use) and cached in :persistent_term, since
  # compiling it on every call is a measurable fraction of header parsing time.
  @spec field_value_valid?(binary()) :: boolean()
  def field_value_valid?(value) do
    :binary.match(value, invalid_field_value_pattern()) == :nomatch
  end

  defp invalid_field_value_pattern do
    case :persistent_term.get(@invalid_field_value_pattern_key, :undefined) do
      :undefined ->
        pattern = :binary.compile_pattern(["\r", "\n", "\0"])
        :persistent_term.put(@invalid_field_value_pattern_key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  @spec get_header(Plug.Conn.headers(), header :: binary()) :: binary() | nil
  def get_header(headers, header) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # A number of headers (Connection, Vary, Cache-Control, ...) are defined as a comma-separated
  # list of case-insensitive tokens (RFC9110§5.6.1), and field names are themselves
  # case-insensitive (RFC9110§5.1). These two helpers centralize that "is this token present"
  # check so each caller doesn't reimplement its own (subtly different) parsing.

  @doc """
  Returns whether `token` (expected to already be lowercase) appears as a comma-separated member
  of `header_value`, compared case-insensitively. `header_value` may be `nil`, in which case this
  always returns `false`.
  """
  @spec token_list_member?(header_value :: binary() | nil, token :: binary()) :: boolean()
  def token_list_member?(nil, _token), do: false

  def token_list_member?(header_value, token) do
    header_value
    |> Plug.Conn.Utils.list()
    |> Enum.any?(&(String.downcase(&1, :ascii) == token))
  end

  @doc """
  Returns whether any header named `header` (matched case-insensitively, and scanning every
  instance if the header appears more than once) contains `token` (expected to already be
  lowercase) as a comma-separated member of its value.
  """
  @spec header_contains_token?(Plug.Conn.headers(), header :: binary(), token :: binary()) ::
          boolean()
  def header_contains_token?(headers, header, token) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name, :ascii) == header end)
    |> Enum.any?(fn {_name, value} -> token_list_member?(value, token) end)
  end

  # Host is special-cased (rather than using get_header/2) because, per RFC9112§3.2 /
  # RFC9110§7.2, a request MUST be rejected if it contains more than one host header,
  # even if the values are identical (unlike content-length, which tolerates duplicates
  # if they agree).
  @spec get_host_header(Plug.Conn.headers()) :: {:ok, binary() | nil} | {:error, String.t()}
  def get_host_header(headers) do
    case Enum.filter(headers, &(elem(&1, 0) == "host")) do
      [] -> {:ok, nil}
      [{"host", value}] -> {:ok, value}
      _ -> {:error, "multiple host headers (RFC9112§3.2, RFC9110§7.2)"}
    end
  end

  # Transfer-encoding is special-cased for the same reason content-length is:
  # it determines message framing, so resolving it with get_header/2 (which
  # returns the first match and ignores the rest) lets a request whose framing
  # is ambiguous be read as though it were not. Per RFC9112§6.1 repeated
  # transfer-encoding headers combine into one comma-separated value, and
  # RFC9112§6.3 requires rejecting a request whose final encoding is not
  # chunked. Since the only encoding accepted here is a bare 'chunked', any
  # repetition is either unsupported or has chunked in a non-final position,
  # and can be rejected outright.
  @spec get_transfer_encoding(Plug.Conn.headers()) ::
          {:ok, binary() | nil} | {:error, String.t()}
  def get_transfer_encoding(headers) do
    case Enum.filter(headers, &(elem(&1, 0) == "transfer-encoding")) do
      [] -> {:ok, nil}
      [{"transfer-encoding", value}] -> {:ok, value}
      _ -> {:error, "multiple transfer-encoding headers (RFC9112§6.1, RFC9112§6.3)"}
    end
  end

  # Covers IPv6 addresses, like `[::1]:4000` as defined in RFC3986.
  @spec parse_hostlike_header!(host_header :: binary()) ::
          {Plug.Conn.host(), nil | Plug.Conn.port_number()}
  def parse_hostlike_header!("[" <> _ = host_header) do
    host_header
    |> :binary.split("]:")
    |> case do
      [host, port] ->
        case parse_integer(port) do
          {port, ""} when is_port_number(port) -> {host <> "]", port}
          _ -> raise Bandit.HTTPError, "Header contains invalid port"
        end

      [host] ->
        {host, nil}
    end
  end

  def parse_hostlike_header!(host_header) do
    host_header
    |> :binary.split(":")
    |> case do
      [host, port] ->
        case parse_integer(port) do
          {port, ""} when is_port_number(port) -> {host, port}
          _ -> raise Bandit.HTTPError, "Header contains invalid port"
        end

      [host] ->
        {host, nil}
    end
  end

  @spec get_content_length(Plug.Conn.headers()) ::
          {:ok, nil | non_neg_integer()} | {:error, String.t()}
  def get_content_length(headers) do
    # We need to special case this because we don't accept multiple content-length headers
    case Enum.filter(headers, &(elem(&1, 0) == "content-length")) do
      [] -> {:ok, nil}
      [{"content-length", value}] -> parse_content_length(value)
      _ -> {:error, "invalid content-length header (RFC9112§6.3)"}
    end
  end

  @spec parse_content_length(binary()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  defp parse_content_length(value) do
    case parse_integer(value) do
      {length, ""} ->
        {:ok, length}

      {length, _rest} ->
        if value |> Plug.Conn.Utils.list() |> Enum.all?(&(&1 == to_string(length))),
          do: {:ok, length},
          else: {:error, "invalid content-length header (RFC9112§6.3.5)"}

      :error ->
        {:error, "invalid content-length header (RFC9112§6.3.5)"}
    end
  end

  # Parses non-negative integers from strings. Return the valid portion of an
  # integer and the remaining string as a tuple like `{123, ""}` or `:error`.
  @spec parse_integer(String.t()) :: {non_neg_integer(), rest :: String.t()} | :error
  defp parse_integer(<<digit::8, rest::binary>>) when digit >= ?0 and digit <= ?9 do
    parse_integer(rest, digit - ?0)
  end

  defp parse_integer(_), do: :error

  @spec parse_integer(String.t(), non_neg_integer()) :: {non_neg_integer(), String.t()}
  defp parse_integer(<<digit::8, rest::binary>>, total) when digit >= ?0 and digit <= ?9 do
    parse_integer(rest, total * 10 + digit - ?0)
  end

  defp parse_integer(rest, total), do: {total, rest}

  @spec add_content_length(
          headers :: Plug.Conn.headers(),
          length :: non_neg_integer(),
          status :: Plug.Conn.int_status(),
          method :: Plug.Conn.method()
        ) ::
          Plug.Conn.headers()

  # Per RFC9110§8.6, we use the following logic:
  #
  # * If the response is 1xx or 204, content-length is NEVER sent
  # * If the response is 304 or the method is HEAD AND the body length is zero, respect any
  #   content-length header the plug may have set on the assumption that it knows what it would
  #   have sent
  # * For all other responses, use the length of the provided response body as the content-length,
  #   overwriting any content-length the plug may have set
  def add_content_length(headers, _length, status, _method)
      when status in 100..199 or status == 204 do
    drop_content_length(headers)
  end

  def add_content_length(headers, 0, status, method) when status == 304 or method == "HEAD" do
    headers
  end

  def add_content_length(headers, length, _status, _method) do
    [{"content-length", to_string(length)} | drop_content_length(headers)]
  end

  @spec drop_content_length(Plug.Conn.headers()) :: Plug.Conn.headers()
  defp drop_content_length(headers) do
    Enum.reject(headers, &(elem(&1, 0) == "content-length"))
  end
end
