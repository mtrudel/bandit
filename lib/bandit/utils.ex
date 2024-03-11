defmodule Bandit.Utils do
  @doc ~S"""
  Checks whether `string` contains only valid characters.

  ## Examples

      iex> Bandit.Utils.valid?("a")
      true

      iex> Bandit.Utils.valid?("ø")
      true

      iex> Bandit.Utils.valid?(<<0xFFFF::16>>)
      false

      iex> Bandit.Utils.valid?(<<0xEF, 0xB7, 0x90>>)
      true

      iex> Bandit.Utils.valid?("asd" <> <<0xFFFF::16>>)
      false

      iex> Bandit.Utils.valid?(4)
      ** (FunctionClauseError) no function clause matching in Bandit.Utils.valid?/1

  """
  def valid?(<<a::8, rest::binary>>) do
    cond do
      a < 128 -> valid_one?(rest)
      a > 191 and a < 224 -> valid_two?(rest)
      a > 223 and a < 240 -> valid_three?(rest)
      a > 239 -> valid_four?(rest)
    end
  end

  def valid?(<<>>), do: true
  def valid?(str) when is_binary(str), do: false

  @compile {:inline, valid_one?: 1, valid_two?: 1, valid_three?: 1, valid_four?: 1}

  defp valid_two?(<<a::8, rest::binary>>)
       when a < 192,
       do: valid?(rest)

  defp valid_two?(_),
    do: false

  defp valid_three?(<<a::16, rest::binary>>)
       when Bitwise.band(a, 0x8080) == 0x8080 and
              Bitwise.bor(a, 0xBFBF) == 0xBFBF,
       do: valid?(rest)

  defp valid_three?(_),
    do: false

  defp valid_four?(<<a::24, rest::binary>>)
       when Bitwise.band(a, 0x808080) == 0x808080 and
              Bitwise.bor(a, 0xBFBFBF) == 0xBFBFBF,
       do: valid?(rest)

  defp valid_four?(_),
    do: false

  defp valid_one?(<<a::56, rest::binary>>)
       when Bitwise.band(a, 0x80808080808080) == 0,
       do: valid?(rest)

  defp valid_one?(rest),
    do: valid?(rest)
end
