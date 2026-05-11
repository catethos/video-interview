defmodule InterviewWeb.CaptureCompleteControllerTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Capture
  alias Interview.Workers.Finalizer

  use Oban.Testing, repo: Interview.Repo

  setup do
    %{session: session, question: question} = Interview.Fixtures.graph!()
    {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
    bearer = Interview.Fixtures.upload_bearer!(session)
    {:ok, session: session, response: response, bearer: bearer}
  end

  defp post_complete(conn, sid, rid, body, bearer) do
    conn
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> post(~p"/sessions/#{sid}/responses/#{rid}/capture_complete", body)
  end

  test "happy path enqueues a finalizer job", %{conn: conn, session: s, response: r, bearer: b} do
    res =
      post_complete(
        conn,
        s.id,
        r.id,
        %{"captureInstanceId" => "cap-A", "expectedTotalBytes" => 4096},
        b
      )

    assert %{"ok" => true, "state" => "capture_complete"} = json_response(res, 200)
    assert_enqueued(worker: Finalizer, args: %{"response_id" => r.id})
  end

  test "fenced writer returns 410", %{conn: conn, session: s, response: r, bearer: b} do
    {:ok, _, _} =
      Capture.claim_instance(
        Interview.Repo.get!(Interview.Capture.Session, r.session_id),
        Interview.Repo.get!(Interview.Templates.Question, r.template_question_id),
        1,
        "cap-B"
      )

    res =
      post_complete(
        conn,
        s.id,
        r.id,
        %{"captureInstanceId" => "cap-A", "expectedTotalBytes" => 4096},
        b
      )

    assert %{"ok" => false, "error" => "fenced", "current" => "cap-B"} = json_response(res, 410)
  end

  test "response from a different session returns 404", %{conn: conn, session: s, bearer: b} do
    other_session = Interview.Fixtures.session!(s.tenant_id, s.template_version_id)
    other_question = Interview.Fixtures.question!(s.template_version_id, 99)

    {:ok, other_response, _} =
      Capture.claim_instance(other_session, other_question, 1, "cap-X")

    res =
      post_complete(
        conn,
        s.id,
        other_response.id,
        %{"captureInstanceId" => "cap-X", "expectedTotalBytes" => 4096},
        b
      )

    assert %{"error" => "not_found"} = json_response(res, 404)
  end

  test "bearer for a different session → 401", %{conn: conn, session: s, response: r} do
    other_session = Interview.Fixtures.session!(s.tenant_id, s.template_version_id)
    wrong_bearer = Interview.Fixtures.upload_bearer!(other_session)

    res =
      post_complete(
        conn,
        s.id,
        r.id,
        %{"captureInstanceId" => "cap-A", "expectedTotalBytes" => 4096},
        wrong_bearer
      )

    assert json_response(res, 401)
  end

  test "missing captureInstanceId is 422", %{conn: conn, session: s, response: r, bearer: b} do
    res = post_complete(conn, s.id, r.id, %{"expectedTotalBytes" => 1}, b)
    assert %{"error" => "missing_captureInstanceId"} = json_response(res, 422)
  end

  test "401 without Authorization", %{conn: conn, session: s, response: r} do
    conn =
      post(conn, ~p"/sessions/#{s.id}/responses/#{r.id}/capture_complete", %{
        "captureInstanceId" => "cap-A",
        "expectedTotalBytes" => 4096
      })

    assert json_response(conn, 401) == %{"ok" => false, "error" => "unauthorized"}
  end
end
