defmodule HTTP2StreamCollectionTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP2.StreamCollection

  describe "skipped?/2" do
    test "is true only for stream ids which the peer passed over" do
      collection =
        %StreamCollection{}
        |> StreamCollection.insert(3, self())
        |> StreamCollection.refuse(9)

      assert Enum.filter(1..11//2, &StreamCollection.skipped?(collection, &1)) == [1, 5, 7]
    end

    test "forgets the oldest ranges once a peer has skipped very many" do
      collection =
        Enum.reduce(1..101, %StreamCollection{}, &StreamCollection.refuse(&2, 4 * &1 - 1))

      refute StreamCollection.skipped?(collection, 1)
      assert StreamCollection.skipped?(collection, 5)
      assert StreamCollection.skipped?(collection, 401)
    end
  end
end
