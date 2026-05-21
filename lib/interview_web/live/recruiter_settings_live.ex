defmodule InterviewWeb.RecruiterSettingsLive do
  @moduledoc """
  Recruiter-facing tenant settings (PLAN §7 Phase 4 — webhook hardening
  P2 items #9, #12, #13).

  Lets a recruiter:
    * Set / clear `webhook_url` (validated through `URLPolicy`).
    * View a masked `webhook_secret` and **rotate** it (regenerates).
    * Send a synchronous `webhook.test` POST so they can verify the
      receiver without waiting for a real session event.
    * Inspect the most recent `webhook_deliveries` rows and **replay**
      failed ones.

  All actions are tenant-scoped through `socket.assigns.tenant` — no
  client-supplied tenant id is trusted.
  """
  use InterviewWeb, :live_view

  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign_form() |> assign_deliveries() |> assign(:test_result, nil)}
  end

  @impl true
  def handle_event("save_webhook_url", %{"tenant" => params}, socket) do
    tenant = socket.assigns.tenant
    attrs = %{"webhook_url" => Map.get(params, "webhook_url", "")}

    case tenant |> Tenant.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        audit(updated, socket, "webhook.url_set", %{"webhook_url" => updated.webhook_url})

        {:noreply,
         socket
         |> assign(:tenant, updated)
         |> assign_form()
         |> put_flash(:info, "Webhook URL saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :webhook_form, to_form(cs))}
    end
  end

  def handle_event("rotate_secret", _params, socket) do
    tenant = socket.assigns.tenant
    new_secret = Tenant.generate_webhook_secret()

    {:ok, updated} =
      tenant
      |> Tenant.changeset(%{webhook_secret: new_secret})
      |> Repo.update()

    audit(updated, socket, "webhook.secret_rotated", %{})

    {:noreply,
     socket
     |> assign(:tenant, updated)
     |> assign_form()
     |> put_flash(
       :info,
       "Webhook secret rotated. Update your receiver before the next event fires."
     )}
  end

  def handle_event("send_test_webhook", _params, socket) do
    result =
      case Webhooks.send_test_event(socket.assigns.tenant) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, "Receiver returned #{status}."}

        {:ok, %{status: status}} ->
          {:error, "Receiver returned #{status} (expected 2xx)."}

        {:error, :not_configured} ->
          {:error, "Save a webhook URL first."}

        {:error, :missing_secret} ->
          {:error, "Rotate the secret first (none configured)."}

        {:error, reason} ->
          {:error, "Transport error: #{inspect(reason)}"}
      end

    {:noreply, assign(socket, :test_result, result)}
  end

  def handle_event("replay_delivery", %{"id" => id}, socket) do
    case Webhooks.replay(id) do
      {:ok, _} ->
        {:noreply, socket |> assign_deliveries() |> put_flash(:info, "Replay enqueued.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Replay failed: #{inspect(reason)}")}
    end
  end

  defp assign_form(socket) do
    cs = Tenant.changeset(socket.assigns.tenant, %{})
    assign(socket, :webhook_form, to_form(cs))
  end

  defp assign_deliveries(socket) do
    assign(socket, :deliveries, Webhooks.list_recent_deliveries(socket.assigns.tenant.id, 50))
  end

  defp audit(%Tenant{} = tenant, socket, action, metadata) do
    Interview.Audit.log!(%{
      tenant_id: tenant.id,
      actor_kind: "recruiter",
      actor_id: socket.assigns.current_scope.recruiter.id,
      action: action,
      subject_kind: "tenant",
      subject_id: tenant.id,
      metadata: metadata
    })
  end

  # ---- Render ----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-10" id="recruiter-settings">
        <header>
          <h1 class="text-2xl font-semibold">Settings</h1>
          <p class="text-sm opacity-70">Webhook delivery for {@tenant.name}</p>
        </header>

        <section id="webhook-config" class="space-y-5">
          <h2 class="text-lg font-medium">Webhook</h2>

          <.form
            :let={f}
            for={@webhook_form}
            phx-submit="save_webhook_url"
            class="space-y-3"
            id="webhook-form"
          >
            <label for={f[:webhook_url].id} class="block text-sm opacity-70">URL</label>
            <input
              type="url"
              name={f[:webhook_url].name}
              id={f[:webhook_url].id}
              value={Phoenix.HTML.Form.normalize_value("url", f[:webhook_url].value)}
              placeholder="https://hooks.example.com/interview"
              class="input input-bordered w-full max-w-xl font-mono text-sm"
            />
            <p
              :for={{msg, _} <- f[:webhook_url].errors}
              class="text-sm text-error"
            >
              {msg}
            </p>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </.form>

          <div class="space-y-2">
            <p class="text-sm opacity-70">Signing secret</p>
            <code id="webhook-secret-masked" class="font-mono text-sm">
              {mask_secret(@tenant.webhook_secret)}
            </code>
            <div class="flex gap-2">
              <button
                type="button"
                phx-click="rotate_secret"
                data-confirm="Rotate the webhook secret? Your receiver will reject signed events until you update it."
                class="btn btn-sm btn-outline"
                id="rotate-secret-btn"
              >
                Rotate secret
              </button>
              <button
                type="button"
                phx-click="send_test_webhook"
                class="btn btn-sm btn-outline"
                id="send-test-btn"
              >
                Send test webhook
              </button>
            </div>

            <p :if={@test_result} id="test-result" class="text-sm">
              <span :if={match?({:ok, _}, @test_result)} class="text-success">
                {elem(@test_result, 1)}
              </span>
              <span :if={match?({:error, _}, @test_result)} class="text-error">
                {elem(@test_result, 1)}
              </span>
            </p>
          </div>
        </section>

        <section id="recent-deliveries" class="space-y-3">
          <h2 class="text-lg font-medium">Recent deliveries</h2>
          <p :if={@deliveries == []} class="text-sm opacity-60" id="deliveries-empty">
            No webhook deliveries yet.
          </p>
          <table :if={@deliveries != []} class="table table-sm w-full">
            <thead>
              <tr>
                <th>Event</th>
                <th>State</th>
                <th>Attempts</th>
                <th>Last status</th>
                <th>Session</th>
                <th>Last error</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={d <- @deliveries} id={"delivery-#{d.id}"} data-state={d.state}>
                <td class="font-mono text-xs">{d.event_type}</td>
                <td>
                  <span class={["badge", state_badge_class(d.state)]}>{d.state}</span>
                </td>
                <td>{d.attempts}</td>
                <td>{d.last_status || "—"}</td>
                <td class="font-mono text-xs opacity-70">{short(d.session_id)}</td>
                <td class="text-xs opacity-70">{d.last_error || "—"}</td>
                <td>
                  <button
                    :if={d.state == "failed"}
                    type="button"
                    phx-click="replay_delivery"
                    phx-value-id={d.id}
                    class="btn btn-xs btn-outline"
                  >
                    Replay
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp mask_secret(nil), do: "—"
  defp mask_secret(""), do: "—"

  defp mask_secret(secret) when is_binary(secret) do
    size = byte_size(secret)

    if size <= 8 do
      String.duplicate("•", size)
    else
      first = binary_part(secret, 0, 4)
      last = binary_part(secret, size - 4, 4)
      first <> "•••••••••••" <> last
    end
  end

  defp short(nil), do: "—"

  defp short(uuid) when is_binary(uuid) and byte_size(uuid) >= 8,
    do: binary_part(uuid, 0, 8) <> "…"

  defp short(_), do: "—"

  defp state_badge_class("delivered"), do: "badge-success"
  defp state_badge_class("pending"), do: "badge-ghost"
  defp state_badge_class("in_flight"), do: "badge-info"
  defp state_badge_class("failed"), do: "badge-error"
  defp state_badge_class(_), do: "badge-ghost"
end
