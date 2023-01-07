defmodule Bandit.IO do
  @moduledoc false

  @doc """
  Returns an iolist consisting of the first `length` bytes of the given list, along with the
  remainder of the iolist beyond it as a tuple. Returns `{:error, :length_exceeded}` if there are
  not `length` bytes remaining in the iolist.
  """
  @spec split_iodata(iodata(), pos_integer(), iodata(), iodata()) :: {iodata(), iodata()} | {:error, :length_exceeded}
  def split_iodata(iodata, length, head \\ [], acc \\ [])
  def split_iodata(iodata, 0, [] = head, []), do: {head, iodata}
  def split_iodata([], _length, [], []), do: {:error, :length_exceeded}
  def split_iodata("", _length, [], []), do: {:error, :length_exceeded}
  def split_iodata([byte | _] = iodata, 0, head, []) when is_integer(byte), do: {head, iodata}
  def split_iodata(_iodata, 0, head, [] = acc), do: {head, acc}
  def split_iodata(iodata, 0, head, acc), do: {head, [iodata | acc]}
  def split_iodata([], _length, head, acc), do: {head, acc}
  def split_iodata([[] | iodata], length, head, acc), do: split_iodata(iodata, length, head, acc)
  def split_iodata(["" | iodata], length, head, acc), do: split_iodata(iodata, length, head, acc)
  def split_iodata([byte | iodata], length, head, acc) when is_integer(byte), do: split_iodata(iodata, length - 1, head ++ [byte], acc)
  def split_iodata([h | iodata], length, head, [] = acc) when h != [] do
    head_length = IO.iodata_length(h)
    if head_length <= length do
      split_iodata(iodata, length - head_length, [head | h], acc)
    else
      split_iodata(h, length, head, iodata)
    end
  end
  def split_iodata([h | iodata], length, head, acc) when h != [] do
    head_length = IO.iodata_length(h)
    if head_length <= length do
      ## TBD
      ## I've not been able to cover this line with any tests
      ## so it could indicate that it's redudent.
      split_iodata(iodata, length - head_length, [head | h], acc)
    else
      split_iodata(h, length, head, [iodata | acc])
    end
  end
  def split_iodata(<<iodata::binary()>>, length, head, acc) do
    case iodata do
      <<h::binary-size(length), rest::binary>> ->
        {[head | h], [rest | acc]}

      iodata ->
        {[head | iodata], acc}
    end
  end
  ## TBD
  ## I've not been able to cover this line with any tests
  ## so it could indicate that it's redudent.
  def split_iodata(_iodata, _length, _head, _acc) do
    {:error, :length_exceeded}
  end
end
