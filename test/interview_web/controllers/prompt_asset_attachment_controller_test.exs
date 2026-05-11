defmodule InterviewWeb.PromptAssetAttachmentControllerTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Templates
  alias Interview.Templates.Question

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    template = Fixtures.template!(tenant.id)
    {:ok, draft} = Templates.create_draft_version(Templates.get_template!(template.id))
    question = Fixtures.question!(draft.id, 1, %{prompt_text: "Q"})

    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    {:ok,
     conn: conn,
     tenant: tenant,
     recruiter: recruiter,
     template: template,
     question: question}
  end

  defp tmp_png! do
    path = Path.join(System.tmp_dir!(), "test-#{System.unique_integer([:positive])}.png")
    # Smallest valid PNG (1x1 red) - actually just the magic header is enough
    # for the content_type check, but we want a non-empty file.
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64))
    path
  end

  defp post_attachment(conn, template_id, question_id, upload) do
    post(conn, ~p"/recruiter/templates/#{template_id}/questions/#{question_id}/attachment", %{
      "attachment" => upload
    })
  end

  test "happy path uploads, creates a ready asset, and updates the question",
       %{conn: conn, template: tpl, question: q} do
    path = tmp_png!()

    upload = %Plug.Upload{
      path: path,
      filename: "x.png",
      content_type: "image/png"
    }

    res = post_attachment(conn, tpl.id, q.id, upload)
    assert %{"ok" => true, "kind" => "image"} = json_response(res, 200)

    refreshed = Repo.get!(Question, q.id)
    assert refreshed.attachment_asset_id

    File.rm(path)
  end

  test "rejects an unsupported mime type", %{conn: conn, template: tpl, question: q} do
    path = tmp_png!()

    upload = %Plug.Upload{
      path: path,
      filename: "x.exe",
      content_type: "application/x-msdownload"
    }

    res = post_attachment(conn, tpl.id, q.id, upload)
    assert %{"error" => "unsupported_type"} = json_response(res, 422)
    File.rm(path)
  end

  test "without recruiter session, redirects to sign-in", %{template: tpl, question: q} do
    path = tmp_png!()

    upload = %Plug.Upload{
      path: path,
      filename: "x.png",
      content_type: "image/png"
    }

    unauthed = build_conn() |> Plug.Test.init_test_session(%{})
    res = post_attachment(unauthed, tpl.id, q.id, upload)
    assert redirected_to(res) =~ "/auth/sign-in"
    File.rm(path)
  end
end
