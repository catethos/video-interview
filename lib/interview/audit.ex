defmodule Interview.Audit do
  @moduledoc """
  Append-only audit log for security-relevant actions (PLAN §7 Phase 4).

  Designed to be cheap to call from anywhere — pass a map of fields, get
  back `{:ok, event}`. The schema is intentionally permissive about which
  fields are present (different actions surface different actor / subject
  shapes); the only required fields are `actor_kind`, `action`, and
  `occurred_at` (auto-stamped if missing).

  ### Volume

  v1 emits per-user-action, NOT per-byte-written. tus PATCH ACKs are
  explicitly excluded — at ~7.5 PATCHes/min/uploader (PLAN §12.5) that's a
  write storm with no security signal. Aggregation per
  `(session, capture_instance)` happens at `capture_complete` instead.
  """
  import Ecto.Query, warn: false

  alias Interview.Audit.Event
  alias Interview.Repo

  @doc """
  Append a single audit event. Intentionally tolerates missing fields so
  call sites don't need to construct elaborate payloads — a recruiter
  sign-out, for example, only knows the recruiter id and the action.

      Audit.log(%{
        tenant_id: tenant.id,
        actor_kind: "recruiter",
        actor_id: user.id,
        action: "recruiter.sign_in",
        subject_kind: "recruiter_user",
        subject_id: user.id,
        ip_address: ip,
        user_agent: ua,
        metadata: %{"source" => "magic_link"}
      })
  """
  def log(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :occurred_at, DateTime.utc_now())

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Same as `log/1` but logs and swallows insertion errors — for emit sites
  on a hot path where a bad audit insert must not break the user-facing
  request.
  """
  def log!(attrs) do
    case log(attrs) do
      {:ok, event} ->
        event

      {:error, changeset} ->
        require Logger
        Logger.warning("audit insert failed: #{inspect(changeset.errors)}")
        nil
    end
  end

  @doc "All events for a tenant in reverse chronological order."
  def list_for_tenant(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(e in Event,
      where: e.tenant_id == ^tenant_id,
      order_by: [desc: e.occurred_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "All events for a subject (e.g. a session, a template, a recruiter user)."
  def list_for_subject(subject_kind, subject_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(e in Event,
      where: e.subject_kind == ^subject_kind and e.subject_id == ^subject_id,
      order_by: [desc: e.occurred_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
