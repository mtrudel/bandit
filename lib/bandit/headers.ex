defmodule Bandit.Headers do
  @moduledoc false
  # Conveniences for dealing with headers.

  @spec is_port_number(integer()) :: Macro.t()
  defguardp is_port_number(port) when Bitwise.band(port, 0xFFFF) === port

  # RFC9110§5.5 defines field values in terms of VCHAR (0x21-0x7e), obs-text
  # (0x80-0xff), and internal SP / HTAB. All other control bytes and DEL are
  # outside the field-value grammar. HTTP/2 applies the additional edge-whitespace
  # prohibition from RFC9113§8.2.1 in its field-section validator.
  @spec field_value_valid?(binary()) :: boolean()
  def field_value_valid?(<<>>), do: true

  def field_value_valid?(<<char, rest::binary>>)
      when char == 0x09 or char in 0x20..0x7E or char in 0x80..0xFF,
      do: field_value_valid?(rest)

  def field_value_valid?(_value), do: false

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

  # RFC9110§7.2 defines Host as uri-host [ ":" port ], importing uri-host from
  # RFC3986§3.2.2. Bracketed hosts therefore have to be IPv6 or IPvFuture literals, while
  # unbracketed hosts have to match reg-name (IPv4 addresses are also valid reg-names).
  @spec parse_hostlike_header!(host_header :: binary()) ::
          {Plug.Conn.host(), nil | Plug.Conn.port_number()}
  def parse_hostlike_header!("[" <> rest) do
    case :binary.split(rest, "]") do
      [literal, suffix] ->
        if valid_ip_literal?(literal) do
          {"[" <> literal <> "]", parse_port_suffix!(suffix)}
        else
          raise Bandit.HTTPError, "Header contains invalid host"
        end

      _ ->
        raise Bandit.HTTPError, "Header contains invalid host"
    end
  end

  def parse_hostlike_header!(host_header) do
    case :binary.split(host_header, ":", [:global]) do
      [host, port] ->
        validate_reg_name!(host)
        {host, parse_port!(port)}

      [host] ->
        validate_reg_name!(host)
        {host, nil}

      _ ->
        raise Bandit.HTTPError, "Header contains invalid host"
    end
  end

  defp parse_port_suffix!(""), do: nil
  defp parse_port_suffix!(":" <> port), do: parse_port!(port)
  defp parse_port_suffix!(_suffix), do: raise(Bandit.HTTPError, "Header contains invalid host")

  # RFC3986§3.2.3 permits an empty port. HTTP and HTTPS assign the scheme's default in that
  # case; callers that require an explicit port (such as CONNECT) enforce that separately.
  defp parse_port!(""), do: nil

  defp parse_port!(port) do
    case parse_integer(port) do
      {port, ""} when is_port_number(port) -> port
      _ -> raise Bandit.HTTPError, "Header contains invalid port"
    end
  end

  defp validate_reg_name!(host) do
    if valid_reg_name?(host),
      do: :ok,
      else: raise(Bandit.HTTPError, "Header contains invalid host")
  end

  defp valid_reg_name?(<<>>), do: true

  defp valid_reg_name?(<<"%", first, second, rest::binary>>)
       when first in ?0..?9 or first in ?a..?f or first in ?A..?F do
    if second in ?0..?9 or second in ?a..?f or second in ?A..?F,
      do: valid_reg_name?(rest),
      else: false
  end

  defp valid_reg_name?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in ~c"-._~!$&'()*+,;=",
       do: valid_reg_name?(rest)

  defp valid_reg_name?(_host), do: false

  defp valid_ip_literal?(literal) do
    case :inet.parse_ipv6_address(:binary.bin_to_list(literal)) do
      {:ok, _address} -> true
      {:error, _reason} -> valid_ipvfuture?(literal)
    end
  end

  defp valid_ipvfuture?(<<prefix, rest::binary>>) when prefix in [?v, ?V] do
    case :binary.split(rest, ".") do
      [version, address] when byte_size(version) > 0 and byte_size(address) > 0 ->
        all_hexdigits?(version) and valid_ipvfuture_address?(address)

      _ ->
        false
    end
  end

  defp valid_ipvfuture?(_literal), do: false

  defp all_hexdigits?(<<>>), do: true

  defp all_hexdigits?(<<char, rest::binary>>)
       when char in ?0..?9 or char in ?a..?f or char in ?A..?F,
       do: all_hexdigits?(rest)

  defp all_hexdigits?(_value), do: false

  defp valid_ipvfuture_address?(<<>>), do: true

  defp valid_ipvfuture_address?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in ~c"-._~!$&'()*+,;=:",
       do: valid_ipvfuture_address?(rest)

  defp valid_ipvfuture_address?(_address), do: false

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
