defmodule Bandit.IOTest do
  use ExUnit.Case, async: true

  @cases [
    #######################################################
    # SEE: https://github.com/ninenines/cowlib/blob/0f5c2f8922c89c58f51696cce690245cbdc5f327/src/cow_iolists.erl#L58L76
    {'Hello world!', 'Hello worl', 'd!'},
    {"Hello world!", 'Hello worl', 'd!'},
    {['He', ["llo"], ?\s, [['world'], "!"]], 'Hello worl', 'd!'},
    {['Hello '|"world!"], 'Hello worl', 'd!'},
    {'Hello!', 'Hello!', ''},
    {"Hello!", 'Hello!', ''},
    {['He', ["ll"], ?o, [['!']]], 'Hello!', ''},
    {['Hel'|"lo!"], 'Hello!', ''},
    {[[""|""], '', "Hello world!"], 'Hello worl', 'd!'},
    {[["He"|"llo"], [?\s], "world!"], 'Hello worl', 'd!'},
    {[[''|"He"], [''|"llo wor"]|"ld!"], 'Hello worl', 'd!'},
    #######################################################
    {["1234567890"], "1234567890", ""},
    {["Hello world!"], "Hello worl", "d!"},
    {["He", ["llo"], " ", [["world"], "!"]], "Hello worl", "d!"},
    {["He", ["llo"], "", [[" world"], "!"]], "Hello worl", "d!"},
    {["He", ["llo"], '', [[" world"], "!"]], "Hello worl", "d!"},
    {["Hello "|"world!"], "Hello worl", "d!"},
    {["Hello!"], "Hello!", ''},
    {["He", ["ll"], "o", [["!"]]], "Hello!", ''},
    {["Hel"|"lo!"], "Hello!", ''},
    {[[""|""], [], "Hello world!"], "Hello worl", "d!"},
    {[["He"|"llo"], [" "], "world!"], "Hello worl", "d!"},
    {[[[]|"He"], [[]|"llo wor"]|"ld!"], "Hello worl", "d!"}
  ]

  describe "split_iodata/4" do
    test "can pass cowlib split_test" do
      for {v, rb, ra} <- @cases do
        assert {b, a} = Bandit.IO.split_iodata(v, 10)
        assert IO.iodata_to_binary(rb) == IO.iodata_to_binary(b)
        assert IO.iodata_to_binary(ra) == IO.iodata_to_binary(a)
      end
    end

    test "iodata too short" do
      assert Bandit.IO.split_iodata([], 1) == {:error, :length_exceeded}
      assert Bandit.IO.split_iodata("", 1) == {:error, :length_exceeded}
    end

    test "single binary zero length" do
      {head, rest} = Bandit.IO.split_iodata("a", 0)
      assert IO.iodata_to_binary(head) == ""
      assert IO.iodata_to_binary(rest) == "a"
    end

    test "single binary full length" do
      {head, rest} = Bandit.IO.split_iodata("a", 1)
      assert IO.iodata_to_binary(head) == "a"
      assert IO.iodata_to_binary(rest) == ""
    end

    test "single binary shorter length" do
      {head, rest} = Bandit.IO.split_iodata("abc", 1)
      assert IO.iodata_to_binary(head) == "a"
      assert IO.iodata_to_binary(rest) == "bc"
    end

    test "multiple binary shorter length" do
      {head, rest} = Bandit.IO.split_iodata(["abc", "def"], 1)
      assert IO.iodata_to_binary(head) == "a"
      assert IO.iodata_to_binary(rest) == "bcdef"
    end

    test "multiple binary splitting length" do
      {head, rest} = Bandit.IO.split_iodata(["abc", "def"], 4)
      assert IO.iodata_to_binary(head) == "abcd"
      assert IO.iodata_to_binary(rest) == "ef"
    end
  end
end
