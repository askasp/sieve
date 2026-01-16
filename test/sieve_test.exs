defmodule SieveTest do
  use ExUnit.Case
  doctest Sieve

  test "greets the world" do
    assert Sieve.hello() == :world
  end
end
