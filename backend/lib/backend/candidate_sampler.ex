defmodule Backend.CandidateSampler do
  @moduledoc false

  def sample_positions(count, take, _shift) when count <= 0 or take <= 0, do: []

  def sample_positions(count, take, _shift) when take >= count do
    0..(count - 1)
    |> Enum.to_list()
  end

  def sample_positions(count, take, shift) do
    shift = rem(max(shift, 0), count)

    for i <- 0..(take - 1) do
      base = div(i * count, take)
      rem(base + shift, count)
    end
  end
end
