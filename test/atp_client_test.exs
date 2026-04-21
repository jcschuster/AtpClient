defmodule AtpClientTest do
  use ExUnit.Case
  doctest AtpClient

  test "greets the world" do
    assert AtpClient.hello() == :world
  end
end
