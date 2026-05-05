defmodule BackendTest do
  use ExUnit.Case, async: true

  test "reference k fixed at 5" do
    assert Backend.FraudScorer.reference_k() == 5
  end
end
