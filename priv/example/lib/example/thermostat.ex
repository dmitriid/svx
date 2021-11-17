defmodule Example.Thermostat do
  def get_reading() do
    {:ok, :rand.uniform(100)}
  end
end