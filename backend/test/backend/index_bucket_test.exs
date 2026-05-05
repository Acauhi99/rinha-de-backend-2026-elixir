defmodule Backend.IndexBucketTest do
  use ExUnit.Case, async: true

  test "bucket candidates include primary bucket" do
    vector = [0.1, 0.2, 0.3, 0.4, 0.5, -1.0, -1.0, 0.2, 0.2, 1.0, 1.0, 0.0, 0.4, 0.2]

    primary = Backend.IndexBucket.bucket_id(vector)
    candidates = Backend.IndexBucket.candidate_buckets(vector)

    assert primary in candidates
  end
end
