defmodule InterviewWeb.RecruiterSettingsLiveTest do
  use InterviewWeb.ConnCase, async: false
  use Oban.Testing, repo: Interview.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks
  alias Interview.Webhooks.Delivery
  alias Interview.Workers.WebhookDelivery

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()

    {:ok, tenant} =
      tenant
      |> Tenant.changeset(%{
        webhook_url: "https://hooks.example.com/x",
        webhook_secret: "topsecret-32-bytes-or-so-padding"
      })
      |> Repo.update()

    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{conn: conn, tenant: tenant, recruiter: recruiter}
  end

  test "renders the current webhook URL and a masked secret", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, ~p"/recruiter/settings")

    assert html =~ tenant.webhook_url
    # masked: first 4 + bullets + last 4. Confirm the raw secret never leaks.
    refute html =~ tenant.webhook_secret
    assert html =~ "•"
  end

  test "saves a new webhook URL", %{conn: conn, tenant: tenant} do
    {:ok, view, _} = live(conn, ~p"/recruiter/settings")

    new_url = "https://other.example.com/hook"

    html =
      view
      |> form("#webhook-form", %{"tenant" => %{"webhook_url" => new_url}})
      |> render_submit()

    assert html =~ new_url

    reloaded = Repo.get!(Tenant, tenant.id)
    assert reloaded.webhook_url == new_url
  end

  test "rejects an invalid webhook URL via the changeset", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/recruiter/settings")

    html =
      view
      |> form("#webhook-form", %{"tenant" => %{"webhook_url" => "http://10.0.0.1/x"}})
      |> render_submit()

    assert html =~ "must use https"
  end

  test "rotate_secret regenerates the secret", %{conn: conn, tenant: tenant} do
    {:ok, view, _} = live(conn, ~p"/recruiter/settings")
    original = tenant.webhook_secret

    _html =
      view
      |> element("#rotate-secret-btn")
      |> render_click()

    reloaded = Repo.get!(Tenant, tenant.id)
    refute reloaded.webhook_secret == original
    assert is_binary(reloaded.webhook_secret)
    assert byte_size(reloaded.webhook_secret) >= 40
  end

  test "send_test_webhook posts synchronously and surfaces 2xx", %{conn: conn} do
    Interview.WebhookStub.program([{:ok, %{status: 204, body: "", headers: []}}])

    {:ok, view, _} = live(conn, ~p"/recruiter/settings")

    html =
      view
      |> element("#send-test-btn")
      |> render_click()

    assert html =~ "Receiver returned 204"

    # No webhook_deliveries row created.
    assert Repo.aggregate(Delivery, :count, :id) == 0
  end

  test "send_test_webhook surfaces a non-2xx as an error", %{conn: conn} do
    Interview.WebhookStub.program([{:ok, %{status: 500, body: "boom", headers: []}}])

    {:ok, view, _} = live(conn, ~p"/recruiter/settings")

    html =
      view
      |> element("#send-test-btn")
      |> render_click()

    assert html =~ "Receiver returned 500"
  end

  test "replay button re-enqueues a failed delivery", %{conn: conn, tenant: tenant} do
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    session = Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

    {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.failed", %{"reason" => "x"})

    Repo.update_all(
      from(d in Delivery, where: d.id == ^id),
      set: [state: "failed", last_error: "permanent 410"]
    )

    {:ok, view, _} = live(conn, ~p"/recruiter/settings")

    _ =
      view
      |> element("#delivery-#{id} button", "Replay")
      |> render_click()

    reloaded = Repo.get!(Delivery, id)
    assert reloaded.state == "pending"
    assert_enqueued(worker: WebhookDelivery, args: %{"delivery_id" => id})
  end
end
