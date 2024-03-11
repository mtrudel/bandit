defmodule Bandit.UtilsTest do
  use ExUnit.Case, async: true

  doctest Bandit.Utils

  test "valid?/1" do
    assert Bandit.Utils.valid?("afds")
    assert Bandit.Utils.valid?("øsdfh")
    assert Bandit.Utils.valid?("dskfjあska")
    assert Bandit.Utils.valid?(<<0xEF, 0xB7, 0x90>>)

    refute Bandit.Utils.valid?(<<0xFFFF::16>>)
    refute Bandit.Utils.valid?("asd" <> <<0xFFFF::16>>)

    assert Bandit.Utils.valid?("afdsafdsafds")
    assert Bandit.Utils.valid?("øsdfhøsdfh")
    assert Bandit.Utils.valid?("dskfjあskadskfjあska")
    assert Bandit.Utils.valid?(<<0xEF, 0xB7, 0x90, 0xEF, 0xB7, 0x90, 0xEF, 0xB7, 0x90>>)

    refute Bandit.Utils.valid?(<<0xFFFF::16>>)
    refute Bandit.Utils.valid?("asdasdasd" <> <<0xFFFF::16>>)
  end
end
