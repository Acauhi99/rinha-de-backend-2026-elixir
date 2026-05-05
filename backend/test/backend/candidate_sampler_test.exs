defmodule Backend.CandidateSamplerTest do
  use ExUnit.Case, async: true

  test "returns all positions when take >= count" do
    assert Backend.CandidateSampler.sample_positions(5, 10, 0) == [0, 1, 2, 3, 4]
  end

  test "returns deterministic and unique sample when take < count" do
    s1 = Backend.CandidateSampler.sample_positions(100, 17, 23)
    s2 = Backend.CandidateSampler.sample_positions(100, 17, 23)

    assert s1 == s2
    assert length(s1) == 17
    assert length(Enum.uniq(s1)) == 17
    assert Enum.all?(s1, &(&1 >= 0 and &1 < 100))
  end
end
