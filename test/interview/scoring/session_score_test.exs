defmodule Interview.Scoring.SessionScoreTest do
  use Interview.DataCase, async: true

  alias Interview.Fixtures
  alias Interview.Scoring.SessionScore

  defp session!(attrs \\ %{}) do
    tenant = Fixtures.tenant!()
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    Fixtures.session!(tenant.id, version.id, attrs)
  end

  defp valid_attrs(session_id, overrides \\ %{}) do
    Map.merge(
      %{
        session_id: session_id,
        pipeline_version: "smoke_test_Pipeline_2_2026-05-25-0423",
        status: "ready",
        computed_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "accepts a ready score" do
      session = session!()

      assert {:ok, score} =
               %SessionScore{}
               |> SessionScore.changeset(valid_attrs(session.id))
               |> Repo.insert()

      assert score.status == "ready"
      assert is_nil(score.error_reason)
    end

    test "accepts a failed score with an error reason" do
      session = session!()

      attrs = valid_attrs(session.id, %{status: "failed", error_reason: "rate_limited"})

      assert {:ok, score} =
               %SessionScore{} |> SessionScore.changeset(attrs) |> Repo.insert()

      assert score.status == "failed"
      assert score.error_reason == "rate_limited"
    end

    test "requires session_id, pipeline_version, status, computed_at" do
      cs = SessionScore.changeset(%SessionScore{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert "can't be blank" in errors.session_id
      assert "can't be blank" in errors.pipeline_version
      assert "can't be blank" in errors.status
      assert "can't be blank" in errors.computed_at
    end

    test "rejects an unknown status" do
      session = session!()
      cs = SessionScore.changeset(%SessionScore{}, valid_attrs(session.id, %{status: "bogus"}))

      refute cs.valid?
      assert "is invalid" in errors_on(cs).status
    end

    test "is unique on (session_id, pipeline_version)" do
      session = session!()

      assert {:ok, _} =
               %SessionScore{} |> SessionScore.changeset(valid_attrs(session.id)) |> Repo.insert()

      assert {:error, cs} =
               %SessionScore{} |> SessionScore.changeset(valid_attrs(session.id)) |> Repo.insert()

      assert "has already been taken" in errors_on(cs).session_id
    end

    test "allows the same session under a different pipeline_version" do
      session = session!()

      assert {:ok, _} =
               %SessionScore{} |> SessionScore.changeset(valid_attrs(session.id)) |> Repo.insert()

      attrs =
        valid_attrs(session.id, %{pipeline_version: "smoke_test_Pipeline_3_2026-06-01-0900"})

      assert {:ok, _} =
               %SessionScore{} |> SessionScore.changeset(attrs) |> Repo.insert()
    end
  end

  describe "statuses/0" do
    test "lists the allowed statuses" do
      assert SessionScore.statuses() == ~w(ready failed)
    end
  end
end
